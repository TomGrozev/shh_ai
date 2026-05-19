defmodule ShhAi.BackendClient do
  @moduledoc """
  HTTP client for LLM backend providers.
  Uses Req with Finch connection pooling for high performance.
  Supports OpenAI, Anthropic, and Ollama APIs with automatic format conversion.

  ## PII Sanitization Pipeline

  All PII operations happen in OpenAI (canonical) format:

      Request (source format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  This ensures consistent PII handling regardless of source/target provider formats.
  """

  require Logger

  alias ShhAi.Config
  alias ShhAi.ApiConverter
  alias ShhAi.PIIPipeline
  alias ShhAi.Metrics

  @type provider :: :openai | :anthropic | :ollama

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t() | map()
        }

  @doc """
  Makes a request to a randomly selected LLM provider with automatic format conversion
  and PII sanitization.

  ## Pipeline

  1. Parse request body (source format)
  2. Convert source format → OpenAI format
  3. Sanitize PII in OpenAI format
  4. Convert OpenAI format → target format
  5. Send request to backend
  6. Receive response (target format)
  7. Convert target format → OpenAI format
  8. Restore PII in OpenAI format
  9. Convert OpenAI format → source format
  10. Return response

  ## Parameters

    - source_provider - The provider format the request came in as
    - source_path - The original request path
    - method - HTTP method
    - body - Request body (in source provider format)
    - headers - Request headers
    - opts - Options including:
      - :session_id - Session ID for PII mapping storage
      - :start_time - Monotonic start time for metrics
      - :request_path - Original request path for metrics
      - :method - HTTP method for metrics
      - :streaming - Whether this is a streaming request

  ## Returns

    - {:ok, response, metrics} where metrics contains timing and PII info
  """
  @spec request(
          source_provider :: provider(),
          source_path :: String.t(),
          method :: atom(),
          body :: map() | String.t(),
          headers :: [{String.t(), String.t()}],
          opts :: keyword()
        ) :: {:ok, response(), provider :: provider(), metrics :: map()} | {:error, term()}
  def request(source_provider, source_path, method, body, headers, opts \\ []) do
    start_time = Keyword.get(opts, :start_time, System.monotonic_time(:microsecond))
    request_path = Keyword.get(opts, :request_path, source_path)
    request_method = Keyword.get(opts, :method, "POST")
    streaming = Keyword.get(opts, :streaming, false)

    {_idx, target_provider, config} = Config.select_provider()
    session_id = Keyword.get(opts, :session_id)

    # Parse body if it's a string
    parsed_body = parse_body(body)

    # Get converters
    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)

    # Get target path for the selected provider
    target_path =
      ApiConverter.get_target_path(source_path, source_provider, target_provider)

    # Step 1: Convert source format → OpenAI format (canonical)
    conversion_start = System.monotonic_time(:microsecond)

    {openai_headers, openai_body} =
      source_converter.to_openai_request(headers, parsed_body, source_path)

    conversion_end = System.monotonic_time(:microsecond)

    # Step 2: Sanitize PII in OpenAI format
    pii_start = System.monotonic_time(:microsecond)

    {:ok, sanitized_body, _mapping, pii_info} =
      PIIPipeline.sanitize_openai_request(openai_body, session_id: session_id)

    pii_end = System.monotonic_time(:microsecond)

    # Step 3: Convert OpenAI format → target format
    conversion_target_start = System.monotonic_time(:microsecond)

    {target_headers, target_body} =
      target_converter.from_openai_request(openai_headers, sanitized_body, target_path)

    conversion_target_end = System.monotonic_time(:microsecond)

    backend_start = System.monotonic_time(:microsecond)

    case do_request_with_provider(
           target_provider,
           config,
           method,
           target_path,
           target_body,
           target_headers
         ) do
      {:ok, response} ->
        backend_end = System.monotonic_time(:microsecond)

        # Step 4: Convert target format → OpenAI format
        restore_start = System.monotonic_time(:microsecond)
        openai_response = target_converter.to_openai_response(response.body, target_path)

        # Step 5: Restore PII in OpenAI format
        {:ok, restored_openai} =
          PIIPipeline.restore_openai_response(openai_response, session_id: session_id)

        # Step 6: Convert OpenAI format → source format
        source_response = source_converter.from_openai_response(restored_openai, source_path)

        restore_end = System.monotonic_time(:microsecond)

        measurements = %{
          duration: restore_end - start_time,
          pii_duration: pii_end - pii_start,
          source_conversion_duration: conversion_end - conversion_start,
          target_conversion_duration: conversion_target_end - conversion_target_start,
          backend_duration: backend_end - backend_start,
          restore_duration: restore_end - restore_start,
          pii_detected_count: pii_info.detected_count,
          pii_sanitized_count: pii_info.sanitized_count,
          pii_preserved_count: pii_info.preserved_count,
          pii_types: pii_info.types
        }

        metadata = %{
          source_provider: source_provider,
          target_provider: config.name,
          request_path: request_path,
          method: request_method,
          streaming: streaming,
          started_at: System.system_time(:microsecond) - (System.monotonic_time(:microsecond) - start_time),
          status: response.status
        }

        Metrics.emit_stop!(measurements, metadata)

        log_request_complete(
          config.name,
          source_path,
          method,
          response.status,
          measurements
        )

        {:ok, %{response | body: source_response}, measurements}

      {:error, reason} ->
        backend_end = System.monotonic_time(:microsecond)

        measurements = %{
          duration: backend_end - start_time,
          pii_duration: pii_end - pii_start,
          source_conversion_duration: conversion_end - conversion_start,
          target_conversion_duration: conversion_target_end - conversion_target_start,
          backend_duration: backend_end - backend_start,
          restore_duration: 0,
          pii_detected_count: pii_info.detected_count,
          pii_sanitized_count: pii_info.sanitized_count,
          pii_preserved_count: pii_info.preserved_count,
          pii_types: pii_info.types
        }

        metadata = %{
          source_provider: source_provider,
          target_provider: config.name,
          request_path: request_path,
          method: request_method,
          streaming: streaming,
          started_at: System.system_time(:microsecond) - (System.monotonic_time(:microsecond) - start_time),
          status: 0,
          error: %{type: :request_error, message: inspect(reason)}
        }

        Metrics.emit_stop!(measurements, metadata)

        {:error, reason}
    end
  end

  @doc """
  Makes a streaming request to a randomly selected LLM provider and chunks the response
  to the given Plug.Conn with automatic format conversion and PII sanitization.

  ## Pipeline

  1. Parse request body (source format)
  2. Convert source format → OpenAI format
  3. Sanitize PII in OpenAI format
  4. Convert OpenAI format → target format
  5. Stream request to backend
  6. For each chunk:
     - Convert target format → OpenAI format
     - Restore PII in OpenAI format
     - Convert OpenAI format → source format
     - Send chunk to client

  The conn should already be set up with send_chunked/2 before calling this function.
  Returns {:ok, conn} on success or {:error, reason} on failure.
  """
  @spec stream(
          conn :: Plug.Conn.t(),
          stream_fun :: function(),
          source_provider :: provider(),
          source_path :: String.t(),
          method :: atom(),
          body :: map(),
          headers :: [{String.t(), String.t()}],
          opts :: keyword()
        ) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def stream(conn, stream_fun, source_provider, source_path, method, body, headers, opts \\ []) do
    start_time = Keyword.get(opts, :start_time, System.monotonic_time(:microsecond))
    request_path = Keyword.get(opts, :request_path, source_path)
    request_method = Keyword.get(opts, :method, "POST")
    streaming = Keyword.get(opts, :streaming, true)

    {_idx, target_provider, config} = Config.select_provider()
    session_id = Keyword.get(opts, :session_id)

    # Parse body if it's a string
    parsed_body = parse_body(body)

    # Get converters
    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)

    # Get target path for the selected provider
    target_path =
      ApiConverter.get_target_path(source_path, source_provider, target_provider)

    # Step 1: Convert source format → OpenAI format (canonical)
    conversion_start = System.monotonic_time(:microsecond)

    {openai_headers, openai_body} =
      source_converter.to_openai_request(headers, parsed_body, source_path)

    conversion_end = System.monotonic_time(:microsecond)

    # Step 2: Sanitize PII in OpenAI format
    pii_start = System.monotonic_time(:microsecond)

    {:ok, sanitized_body, _mapping, pii_info} =
      PIIPipeline.sanitize_openai_request(openai_body, session_id: session_id)

    pii_end = System.monotonic_time(:microsecond)

    # Step 3: Convert OpenAI format → target format
    conversion_target_start = System.monotonic_time(:microsecond)

    {target_headers, target_body} =
      target_converter.from_openai_request(openai_headers, sanitized_body, target_path)

    conversion_target_end = System.monotonic_time(:microsecond)

    pre_stream_timings = %{
      pii_duration: pii_end - pii_start,
      source_conversion_duration: conversion_end - conversion_start,
      target_conversion_duration: conversion_target_end - conversion_target_start
    }

    metrics_opts = %{
      source_provider: source_provider,
      target_provider: config.name,
      request_path: request_path,
      method: request_method,
      streaming: streaming
    }

    do_stream_with_provider(
      conn,
      stream_fun,
      source_provider,
      source_path,
      target_provider,
      config,
      method,
      target_path,
      target_body,
      target_headers,
      session_id,
      start_time,
      metrics_opts,
      pii_info,
      pre_stream_timings
    )
  end

  # Private helper functions

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_body(body), do: body

  defp do_request_with_provider(provider, config, method, path, body, headers) do
    with {:ok, url} <- build_url(config.base_url, path),
         processed_headers <- build_headers(provider, headers, config),
         {:ok, response} <- do_request(method, url, body, processed_headers, config.timeout) do
      {:ok, response}
    end
  end

  defp do_stream_with_provider(
         conn,
         stream_fun,
         source_provider,
         source_path,
         target_provider,
         config,
         method,
         path,
         body,
         headers,
         session_id,
         start_time,
         metrics_opts,
         pii_info,
         pre_stream_timings
       ) do
    with {:ok, url} <- build_url(config.base_url, path),
         processed_headers <- build_headers(target_provider, headers, config) do
      do_stream(
        conn,
        stream_fun,
        source_provider,
        source_path,
        target_provider,
        method,
        url,
        body,
        processed_headers,
        config.timeout,
        session_id,
        start_time,
        metrics_opts,
        pii_info,
        pre_stream_timings
      )
    end
  end

  defp build_url(base_url, path) do
    url = String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/v1/")

    {:ok, url}
  end

  defp build_headers(provider, headers, config) do
    default_headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    maybe_add_auth_header(provider, config, default_headers ++ headers)
    |> Enum.uniq_by(fn {k, _} -> k end)
  end

  defp maybe_add_auth_header(_, %{api_key: nil}, headers), do: headers

  defp maybe_add_auth_header(:anthropic, %{api_key: key}, headers) do
    [{"x-api-key", key}, {"anthropic-version", "2023-06-01"} | headers]
  end

  defp maybe_add_auth_header(provider, %{api_key: key}, headers)
       when provider in [:openai, :ollama] do
    [{"authorization", "Bearer #{key}"} | headers]
  end

  defp do_request(method, url, body, headers, timeout) do
    body = encode_body(body)

    headers = Enum.reject(headers, fn {k, _v} -> k in ["connection"] end)

    request =
      Req.new(
        url: url,
        method: method,
        headers: headers,
        body: body,
        receive_timeout: timeout,
        pool_timeout: 5_000,
        connect_options: [
          protocols: [:http1]
        ]
      )

    # TODO this isn't converting

    case Req.request(request) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("Backend request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_stream(
         conn,
         stream_fun,
         source_provider,
         source_path,
         target_provider,
         method,
         url,
         body,
         headers,
         timeout,
         session_id,
         start_time,
         metrics_opts,
         pii_info,
         pre_stream_timings
       ) do
    # Stream the request body to the backend
    stream_body = stream_encode_body(body)

    # Add streaming header
    headers =
      Enum.reject(headers, fn {k, _v} -> k in ["connection"] end) ++
        [{"accept", "text/event-stream"}]

    # Get converters for stream chunk conversion
    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)

    # Get PII mapping for restoration
    mapping = get_session_mapping(session_id)

    # Initialize metrics context
    metrics_context = %{
      start_time: start_time,
      metrics_opts: metrics_opts,
      pii_info: pii_info,
      restore_duration: 0,
      backend_start: System.monotonic_time(:microsecond),
      method: method,
      source_path: source_path
    }

    request =
      Req.new(
        url: url,
        method: method,
        headers: headers,
        body: stream_body,
        receive_timeout: timeout,
        pool_timeout: 5_000,
        connect_options: [
          protocols: [:http1]
        ],
        into: fn
          {:data, ""}, {req, resp} ->
            {:cont, {req, resp}}

          {:data, chunk}, {req, resp} ->
            # Get current PII state and metrics context from response private
            current_pii_state = Req.Response.get_private(resp, :pii_state, %{})
            metrics_context = Req.Response.get_private(resp, :metrics_context, metrics_context)

            a_conn =
              Req.Response.get_private(resp, :req_conn, conn)
              |> init_stream(resp)

            if resp.status >= 400 do
              Logger.debug("Bad response from backend: #{inspect(chunk)}")
            end

            # Time the restore operation
            restore_start = System.monotonic_time(:microsecond)

            # Convert chunk from target format to OpenAI format, restore PII, then convert to source format
            {converted_chunks, new_pii_state, done?} =
              convert_and_restore_stream_chunk(
                chunk,
                target_converter,
                source_converter,
                source_path,
                mapping,
                current_pii_state
              )

            restore_end = System.monotonic_time(:microsecond)

            # Accumulate restore timing
            metrics_context =
              Map.update!(metrics_context, :restore_duration, fn acc ->
                acc + (restore_end - restore_start)
              end)

            if done? do
              emit_stop(resp.status, metrics_context, pre_stream_timings)
            end

            # Send each converted chunk
            Enum.reduce_while(converted_chunks, a_conn, fn
              converted_chunk, conn_inner ->
                case stream_fun.(converted_chunk, conn_inner) do
                  {:cont, new_conn} ->
                    {:cont, new_conn}

                  :halt ->
                    {:halt, :halt}
                end
            end)
            |> case do
              :halt ->
                {:halt, {req, resp}}

              new_conn ->
                n_resp =
                  resp
                  |> Req.Response.put_private(:req_conn, new_conn)
                  |> Req.Response.put_private(:pii_state, new_pii_state)
                  |> Req.Response.put_private(:metrics_context, metrics_context)

                {:cont, {req, n_resp}}
            end
        end
      )

    case Req.request(request) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("Backend stream request failed: #{inspect(reason)}")

        measurements = %{
          duration: System.monotonic_time(:microsecond) - metrics_context.start_time,
          pii_duration: pre_stream_timings.pii_duration,
          source_conversion_duration: pre_stream_timings.source_conversion_duration,
          target_conversion_duration: pre_stream_timings.target_conversion_duration,
          backend_duration: 0,
          restore_duration: metrics_context.restore_duration,
          pii_detected_count: metrics_context.pii_info.detected_count,
          pii_sanitized_count: metrics_context.pii_info.sanitized_count,
          pii_preserved_count: metrics_context.pii_info.preserved_count,
          pii_types: metrics_context.pii_info.types
        }

        metadata = %{
          source_provider: metrics_context.metrics_opts[:source_provider],
          target_provider: metrics_context.metrics_opts[:target_provider],
          request_path: metrics_context.metrics_opts[:request_path],
          method: metrics_context.metrics_opts[:method],
          streaming: metrics_context.metrics_opts[:streaming],
          started_at: System.system_time(:microsecond) - (System.monotonic_time(:microsecond) - metrics_context.start_time),
          status: 0,
          error: %{type: :stream_error, message: inspect(reason)}
        }

        Metrics.emit_stop!(measurements, metadata)

        {:error, reason}
    end
  end

  defp emit_stop(status, metrics_context, pre_stream_timings) do
    backend_end = System.monotonic_time(:microsecond)
    backend_start = metrics_context.backend_start || backend_end
    backend_duration = backend_end - backend_start

    measurements = %{
      duration: backend_end - metrics_context.start_time,
      pii_duration: pre_stream_timings.pii_duration,
      source_conversion_duration: pre_stream_timings.source_conversion_duration,
      target_conversion_duration: pre_stream_timings.target_conversion_duration,
      backend_duration: backend_duration,
      restore_duration: metrics_context.restore_duration,
      pii_detected_count: metrics_context.pii_info.detected_count,
      pii_sanitized_count: metrics_context.pii_info.sanitized_count,
      pii_preserved_count: metrics_context.pii_info.preserved_count,
      pii_types: metrics_context.pii_info.types
    }

    metadata = %{
      source_provider: metrics_context.metrics_opts[:source_provider],
      target_provider: metrics_context.metrics_opts[:target_provider],
      request_path: metrics_context.metrics_opts[:request_path],
      method: metrics_context.metrics_opts[:method],
      streaming: metrics_context.metrics_opts[:streaming],
      started_at: System.system_time(:microsecond) - (System.monotonic_time(:microsecond) - metrics_context.start_time),
      status: status
    }

    log_request_complete(
      metadata.target_provider,
      metrics_context.source_path,
      metrics_context.method,
      status,
      measurements
    )

    Metrics.emit_stop!(measurements, metadata)
  end

  defp init_stream(%{state: :chunked} = conn, _resp), do: conn

  defp init_stream(conn, resp) do
    a_conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(resp.status)

    a_conn
  end

  defp convert_and_restore_stream_chunk(
         chunk,
         target_converter,
         source_converter,
         source_path,
         mapping,
         pii_state
       ) do
    # Step 1: Convert from target format to OpenAI format
    case target_converter.to_openai_stream_chunk(chunk, source_path) do
      {:done, chunks} ->
        {converted_chunks, final_state} =
          process_chunks(chunks, mapping, source_converter, source_path, pii_state)

        {converted_chunks, final_state, true}

      :done ->
        {[], pii_state, true}

      {:error, _reason} ->
        # On error, pass through unchanged
        {[chunk], pii_state, false}

      openai_chunks when is_list(openai_chunks) ->
        {converted_chunks, final_state} =
          process_chunks(openai_chunks, mapping, source_converter, source_path, pii_state)

        {converted_chunks, final_state, false}
    end
  end

  defp process_chunks(chunks, mapping, source_converter, source_path, pii_state) do
    {converted_chunks, final_state} =
      Enum.reduce(chunks, {[], pii_state}, fn openai_chunk, {acc, state} ->
        {restored_chunks, new_state} =
          PIIPipeline.restore_stream_chunk(openai_chunk, state, mapping)

        # restored_chunks is a list of SSE chunks
        source_chunks =
          Enum.flat_map(restored_chunks, fn restored_chunk ->
            case source_converter.from_openai_stream_chunk(restored_chunk, source_path) do
              {:done, new_chunks} -> new_chunks
              new_chunks when is_list(new_chunks) -> new_chunks
              _ -> []
            end
          end)

        {acc ++ source_chunks, new_state}
      end)

    {converted_chunks, final_state}
  end

  defp get_session_mapping(nil), do: %{}

  defp get_session_mapping(session_id) do
    case ShhAi.SessionStore.get(session_id) do
      {:ok, mapping} -> mapping
      {:error, _} -> %{}
    end
  end

  defp log_request_complete(target_provider, path, method, status, measurements) do
    duration = format_duration(measurements.duration)
    backend = format_duration(measurements.backend_duration)
    pii_count = measurements.pii_sanitized_count

    Logger.info(
      "✅ Request complete | #{method |> to_string() |> String.upcase()} #{path} → #{target_provider} | #{duration} (backend: #{backend}) | Status: #{status}#{if pii_count > 0, do: " | 🔒 PII: #{pii_count}", else: ""}"
    )
  end

  defp format_duration(microseconds) when microseconds < 1_000 do
    "#{microseconds}μs"
  end

  defp format_duration(microseconds) when microseconds < 1_000_000 do
    "#{div(microseconds, 1000)}ms"
  end

  defp format_duration(microseconds) do
    "#{Float.round(microseconds / 1_000_000, 2)}s"
  end

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)

  # Encodes the body as a stream for efficient transmission to the backend.
  # Returns an enumerable that yields chunks of the encoded body.
  defp stream_encode_body(body) when is_binary(body) do
    # Stream the binary in chunks of 8KB
    ShhAi.Utils.Stream.stream_binary(body, 8192)
  end

  defp stream_encode_body(body) when is_map(body) do
    # Encode to JSON first, then stream in chunks
    encoded = Jason.encode!(body)
    ShhAi.Utils.Stream.stream_binary(encoded, 8192)
  end
end
