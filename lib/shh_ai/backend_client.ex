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
    - opts - Options including :session_id for PII mapping storage

  ## Returns
    - {:ok, response, target_provider} where response is converted back to source format
  """
  @spec request(
          source_provider :: provider(),
          source_path :: String.t(),
          method :: atom(),
          body :: map() | String.t(),
          headers :: [{String.t(), String.t()}],
          opts :: keyword()
        ) :: {:ok, response(), provider()} | {:error, term()}
  def request(source_provider, source_path, method, body, headers, opts \\ []) do
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
    {openai_headers, openai_body} =
      source_converter.to_openai_request(headers, parsed_body, source_path)

    # Step 2: Sanitize PII in OpenAI format
    {:ok, sanitized_body, _mapping} =
      PIIPipeline.sanitize_openai_request(openai_body, session_id: session_id)

    # Step 3: Convert OpenAI format → target format
    {target_headers, target_body} =
      target_converter.from_openai_request(openai_headers, sanitized_body, target_path)

    case do_request_with_provider(
           target_provider,
           config,
           method,
           target_path,
           target_body,
           target_headers
         ) do
      {:ok, response} ->
        # Step 4: Convert target format → OpenAI format
        openai_response = target_converter.to_openai_response(response.body, target_path)

        # Step 5: Restore PII in OpenAI format
        {:ok, restored_openai} =
          PIIPipeline.restore_openai_response(openai_response, session_id: session_id)

        # Step 6: Convert OpenAI format → source format
        source_response = source_converter.from_openai_response(restored_openai, source_path)

        {:ok, %{response | body: source_response}, target_provider}

      {:error, reason} ->
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
        ) :: {:ok, Plug.Conn.t(), provider()} | {:error, term()}
  def stream(conn, stream_fun, source_provider, source_path, method, body, headers, opts \\ []) do
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
    {openai_headers, openai_body} =
      source_converter.to_openai_request(headers, parsed_body, source_path)

    # Step 2: Sanitize PII in OpenAI format
    {:ok, sanitized_body, _mapping} =
      PIIPipeline.sanitize_openai_request(openai_body, session_id: session_id)

    # Step 3: Convert OpenAI format → target format
    {target_headers, target_body} =
      target_converter.from_openai_request(openai_headers, sanitized_body, target_path)

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
      session_id
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
         session_id
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
        session_id
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
         session_id
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
            a_conn =
              Req.Response.get_private(resp, :req_conn, conn)
              |> maybe_send_chunked(resp)

            if resp.status >= 400 do
              Logger.debug("Bad response from backend: #{inspect(chunk)}")
            end

            # Convert chunk from target format to OpenAI format, restore PII, then convert to source format
            converted_chunks =
              convert_and_restore_stream_chunk(
                chunk,
                target_converter,
                source_converter,
                source_path,
                mapping
              )

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
                n_resp = Req.Response.put_private(resp, :req_conn, new_conn)

                {:cont, {req, n_resp}}
            end
        end
      )

    case Req.request(request) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("Backend stream request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_send_chunked(%{state: :chunked} = conn, _resp), do: conn

  defp maybe_send_chunked(conn, resp) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(resp.status)
  end

  defp convert_and_restore_stream_chunk(
         chunk,
         target_converter,
         source_converter,
         source_path,
         mapping
       ) do
    # Step 1: Convert from target format to OpenAI format
    case target_converter.to_openai_stream_chunk(chunk, source_path) do
      {:done, chunks} ->
        # Stream is done, convert and restore each chunk
        process_chunks(chunks, mapping, source_converter, source_path)

      :done ->
        []

      {:error, _reason} ->
        # On error, pass through unchanged
        [chunk]

      openai_chunks when is_list(openai_chunks) ->
        # Step 2: Restore PII in OpenAI format
        # Step 3: Convert from OpenAI format to source format
        process_chunks(openai_chunks, mapping, source_converter, source_path)
    end
  end

  defp process_chunks(chunks, mapping, source_converter, source_path) do
    Enum.flat_map(chunks, fn openai_chunk ->
      restored = PIIPipeline.restore_openai_stream_chunk(openai_chunk, mapping)

      case source_converter.from_openai_stream_chunk(restored, source_path) do
        {:done, new_chunks} -> new_chunks
        new_chunks when is_list(new_chunks) -> new_chunks
        _ -> []
      end
    end)
  end

  defp get_session_mapping(nil), do: %{}

  defp get_session_mapping(session_id) do
    case ShhAi.SessionStore.get(session_id) do
      {:ok, mapping} -> mapping
      {:error, _} -> %{}
    end
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
