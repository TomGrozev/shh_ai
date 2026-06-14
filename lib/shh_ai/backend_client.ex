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
  alias ShhAi.Conversation

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
  3. Extract conversation ID from body (OpenAI format) and find/create Conversation
  4. Sanitize PII in OpenAI format (using Conversation mapping)
  5. Convert OpenAI format → target format
  6. Send request to backend
  7. Receive response (target format)
  8. Convert target format → OpenAI format
  9. Restore PII in OpenAI format (using Conversation mapping)
  10. Convert OpenAI format → source format
  11. Touch Conversation to reset sliding TTL
  12. Return response

  ## Parameters

    - source_provider - The provider format the request came in as
    - source_path - The original request path
    - method - HTTP method
    - body - Request body (in source provider format)
    - headers - Request headers
    - opts - Options including:
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
        ) :: {:ok, response(), metrics :: map()} | {:error, term()}
  def request(source_provider, source_path, method, body, headers, opts \\ []) do
    start_time = Keyword.get(opts, :start_time, System.monotonic_time(:microsecond))
    request_path = Keyword.get(opts, :request_path, source_path)
    request_method = Keyword.get(opts, :method, "POST")
    streaming = Keyword.get(opts, :streaming, false)

    {_idx, target_provider, config} = Config.select_provider()

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

    # Find or create a Conversation based on the OpenAI-format body
    with {:ok, conversation} <- find_or_create_conversation(openai_body, source_provider),
         {:ok, sanitized_body, _mapping, _reverse_index, pii_info} <-
           PIIPipeline.sanitize_openai_request(openai_body, conversation) do
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
            PIIPipeline.restore_openai_response(openai_response, conversation)

          # Step 6: Convert OpenAI format → source format
          source_response = source_converter.from_openai_response(restored_openai, source_path)

          restore_end = System.monotonic_time(:microsecond)

          # Update fingerprint (may migrate conversation ID for Turn 1)
          conversation_id =
            update_conversation_fingerprint(conversation, openai_body, openai_response)

          # Touch conversation to reset sliding TTL
          Conversation.touch(conversation_id)

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
            started_at:
              System.system_time(:microsecond) -
                (System.monotonic_time(:microsecond) - start_time),
            status: response.status,
            conversation_id: conversation_id
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

          # Touch conversation even on error to keep it alive
          Conversation.touch(conversation.conversation_id)

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
            started_at:
              System.system_time(:microsecond) -
                (System.monotonic_time(:microsecond) - start_time),
            status: 0,
            error: %{type: :request_error, message: inspect(reason)},
            conversation_id: conversation.conversation_id
          }

          Metrics.emit_stop!(measurements, metadata)

          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("BackendClient request failed early: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Makes a streaming request to a randomly selected LLM provider and chunks the response
  to the given Plug.Conn with automatic format conversion and PII sanitization.

  ## Pipeline

  1. Parse request body (source format)
  2. Convert source format → OpenAI format
  3. Extract conversation ID from body (OpenAI format) and find/create Conversation
  4. Sanitize PII in OpenAI format (using Conversation mapping)
  5. Convert OpenAI format → target format
  6. Stream request to backend
  7. For each chunk:
     - Convert target format → OpenAI format
     - Restore PII in OpenAI format (using Conversation mapping)
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

    # Find or create a Conversation based on the OpenAI-format body
    with {:ok, conversation} <- find_or_create_conversation(openai_body, source_provider),
         {:ok, sanitized_body, _mapping, _reverse_index, pii_info} <-
           PIIPipeline.sanitize_openai_request(openai_body, conversation) do
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
        conversation,
        start_time,
        metrics_opts,
        pii_info,
        pre_stream_timings,
        openai_body
      )
    else
      {:error, reason} ->
        Logger.error("BackendClient stream failed early: #{inspect(reason)}")
        {:error, reason}
    end
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
         conversation,
         start_time,
         metrics_opts,
         pii_info,
         pre_stream_timings,
         openai_body
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
        conversation,
        start_time,
        metrics_opts,
        pii_info,
        pre_stream_timings,
        openai_body
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
         conversation,
         start_time,
         metrics_opts,
         pii_info,
         pre_stream_timings,
         openai_body
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

    # Get PII mapping from conversation for restoration
    mapping = get_conversation_mapping(conversation)

    # Initialize metrics context
    metrics_context = %{
      start_time: start_time,
      metrics_opts: metrics_opts,
      pii_info: pii_info,
      restore_duration: 0,
      backend_start: System.monotonic_time(:microsecond),
      method: method,
      source_path: source_path,
      assistant_content: "",
      openai_body: openai_body,
      conversation_id: conversation.conversation_id
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
            {converted_chunks, new_pii_state, done?, openai_chunks} =
              convert_and_restore_stream_chunk(
                chunk,
                target_converter,
                source_converter,
                source_path,
                mapping,
                current_pii_state
              )

            # Extract assistant content from OpenAI-format chunks
            chunk_content = extract_content_from_openai_chunks(openai_chunks)

            restore_end = System.monotonic_time(:microsecond)

            # Accumulate restore timing and assistant content
            metrics_context =
              metrics_context
              |> Map.update!(:restore_duration, fn acc ->
                acc + (restore_end - restore_start)
              end)
              |> Map.update!(:assistant_content, fn acc ->
                acc <> chunk_content
              end)

            if done? do
              # Build full assistant message from buffered content (pre-restored)
              assistant_message = %{
                "role" => "assistant",
                "content" => metrics_context.assistant_content
              }

              full_messages =
                (metrics_context.openai_body["messages"] || []) ++ [assistant_message]

              full_fingerprint =
                ShhAi.ConversationFingerprinter.fingerprint_messages(full_messages)

              # Determine the final conversation ID (after possible migration)
              final_conversation_id =
                if conversation.new? do
                  new_id =
                    ShhAi.ConversationFingerprinter.derive_conversation_id(full_fingerprint)

                  case Conversation.migrate_id(conversation.conversation_id, new_id) do
                    :ok ->
                      Conversation.update_fingerprint(new_id, full_fingerprint)
                      Conversation.touch(new_id)
                      new_id

                    {:error, reason} ->
                      Logger.warning("Failed to migrate conversation: #{inspect(reason)}")
                      Conversation.touch(conversation.conversation_id)
                      conversation.conversation_id
                  end
                else
                  case Conversation.update_fingerprint(
                         conversation.conversation_id,
                         full_fingerprint
                       ) do
                    :ok ->
                      Conversation.touch(conversation.conversation_id)
                      conversation.conversation_id

                    {:error, reason} ->
                      Logger.warning("Failed to update fingerprint: #{inspect(reason)}")
                      Conversation.touch(conversation.conversation_id)
                      conversation.conversation_id
                  end
                end

              # Cache the assistant response for future message cache hits
              cache_assistant_response(final_conversation_id, metrics_context.assistant_content, mapping)

              # Update metrics context with the final (possibly migrated) conversation ID
              metrics_context = %{metrics_context | conversation_id: final_conversation_id}

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
        # Fingerprint update and touch already handled in done? callback above
        {:ok, response}

      {:error, reason} ->
        Logger.error("Backend stream request failed: #{inspect(reason)}")
        Conversation.touch(conversation.conversation_id)

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
          started_at:
            System.system_time(:microsecond) -
              (System.monotonic_time(:microsecond) - metrics_context.start_time),
          status: 0,
          error: %{type: :stream_error, message: inspect(reason)},
          conversation_id: conversation.conversation_id
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
      started_at:
        System.system_time(:microsecond) -
          (System.monotonic_time(:microsecond) - metrics_context.start_time),
      status: status,
      conversation_id: metrics_context.conversation_id
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

        {converted_chunks, final_state, true, chunks}

      :done ->
        {[], pii_state, true, []}

      {:error, _reason} ->
        # On error, pass through unchanged
        {[chunk], pii_state, false, []}

      openai_chunks when is_list(openai_chunks) ->
        {converted_chunks, final_state} =
          process_chunks(openai_chunks, mapping, source_converter, source_path, pii_state)

        {converted_chunks, final_state, false, openai_chunks}
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

  defp extract_conversation_id(body, _provider) when not is_map(body), do: :stateless

  defp extract_conversation_id(%{"thread_id" => id}, _provider) when is_binary(id),
    do: {:stateful, id}

  defp extract_conversation_id(%{"conversation" => id}, _provider) when is_binary(id),
    do: {:stateful, id}

  defp extract_conversation_id(_, _provider), do: :stateless

  defp find_or_create_conversation(parsed_body, source_provider) do
    messages = if is_map(parsed_body), do: parsed_body["messages"] || [], else: []

    fingerprint =
      if length(messages) > 1 do
        ShhAi.ConversationFingerprinter.fingerprint_for_lookup(messages)
      else
        nil
      end

    provider_conversation_id =
      case extract_conversation_id(parsed_body, source_provider) do
        {:stateful, id} -> id
        :stateless -> nil
      end

    Conversation.find_or_create(fingerprint, %{
      provider_conversation_id: provider_conversation_id,
      source_provider: source_provider
    })
  end

  defp get_conversation_mapping(%Conversation{} = conversation) do
    case Conversation.get_mapping(conversation.conversation_id) do
      {:ok, mapping} -> mapping
      {:error, _} -> %{}
    end
  end

  defp extract_assistant_message(%{"choices" => [%{"message" => message} | _]}), do: message
  defp extract_assistant_message(%{"choices" => [%{"delta" => delta} | _]}), do: delta
  defp extract_assistant_message(_), do: %{"role" => "assistant", "content" => ""}

  # Only extracts text content (delta.content / message.content). Tool calls,
  # function calls, and other non-text content are silently ignored.
  defp extract_content_from_openai_chunks(chunks) when is_list(chunks) do
    chunks
    |> Enum.map(fn chunk ->
      case parse_sse_chunk_to_map(chunk) do
        %{"choices" => _} = map ->
          get_in(map, ["choices", Access.at(0), "delta", "content"]) ||
            get_in(map, ["choices", Access.at(0), "message", "content"]) || ""

        _ ->
          ""
      end
    end)
    |> Enum.join()
  end

  defp extract_content_from_openai_chunks(_), do: ""

  defp parse_sse_chunk_to_map(chunk) when is_map(chunk), do: chunk

  defp parse_sse_chunk_to_map(chunk) when is_binary(chunk) do
    if String.starts_with?(chunk, "data:") do
      json = chunk |> String.replace_prefix("data:", "") |> String.trim()

      if json == "[DONE]" do
        %{}
      else
        case Jason.decode(json) do
          {:ok, map} -> map
          {:error, _} -> %{}
        end
      end
    else
      %{}
    end
  end

  defp update_conversation_fingerprint(conversation, openai_body, openai_response) do
    messages = if is_map(openai_body), do: openai_body["messages"] || [], else: []
    assistant_message = extract_assistant_message(openai_response)
    full_messages = messages ++ [assistant_message]

    full_fingerprint = ShhAi.ConversationFingerprinter.fingerprint_messages(full_messages)

    # fingerprint_messages/1 returns nil when there are 0 or 1 messages —
    # nothing to fingerprint, so just return the existing conversation ID.
    if is_nil(full_fingerprint) do
      conversation.conversation_id
    else
      update_conversation_fingerprint_with_hash(conversation, full_fingerprint)
    end
  end

  defp update_conversation_fingerprint_with_hash(conversation, full_fingerprint) do
    if conversation.new? do
      # Turn 1: migrate from temporary UUID v4 to deterministic UUID v5
      new_id = ShhAi.ConversationFingerprinter.derive_conversation_id(full_fingerprint)

      with :ok <- Conversation.migrate_id(conversation.conversation_id, new_id),
           :ok <- Conversation.update_fingerprint(new_id, full_fingerprint) do
        new_id
      else
        {:error, reason} ->
          Logger.warning("Failed to migrate conversation: #{inspect(reason)}")
          conversation.conversation_id
      end
    else
      # Turn 2+: update stored fingerprint
      case Conversation.update_fingerprint(conversation.conversation_id, full_fingerprint) do
        :ok ->
          conversation.conversation_id

        {:error, reason} ->
          Logger.warning("Failed to update fingerprint: #{inspect(reason)}")
          conversation.conversation_id
      end
    end
  end

  # Cache the assistant response for future turns.
  # The hash covers the RESTORED content (what the client sees),
  # and the cached value is the PRE-RESTORED content (with placeholders).
  defp cache_assistant_response(conversation_id, pre_restored_content, mapping) do
    if map_size(mapping) > 0 and pre_restored_content != "" do
      # Restore the pre-restored content to get the actual PII values
      {:ok, restored_content} = ShhAi.PII.Sanitizer.restore(pre_restored_content, mapping)

      # Hash the restored content — this is what the client sees
      hash = ShhAi.Conversation.hash_message(%{role: "assistant", content: restored_content})

      # Cache the pre-restored content (with placeholders) as the "sanitized" version
      ShhAi.Conversation.cache_message(conversation_id, hash, {:assistant_message, pre_restored_content})
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
