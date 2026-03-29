defmodule ShhAi.BackendClient do
  @moduledoc """
  HTTP client for LLM backend providers.
  Uses Req with Finch connection pooling for high performance.
  Supports OpenAI, Anthropic, and Ollama APIs with automatic format conversion.
  """

  require Logger

  alias ShhAi.Config
  alias ShhAi.ApiConverter

  @type provider :: :openai | :anthropic | :ollama

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t() | map()
        }

  @doc """
  Makes a request to a randomly selected LLM provider with automatic format conversion.
  Converts requests and responses between the source provider format and target provider format.

  ## Parameters
    - source_provider - The provider format the request came in as
    - source_path - The original request path
    - method - HTTP method
    - body - Request body (in source provider format)
    - headers - Request headers

  ## Returns
    - {:ok, response, target_provider} where response is converted back to source format
  """
  @spec request(
          source_provider :: provider(),
          source_path :: String.t(),
          method :: atom(),
          body :: map() | String.t(),
          headers :: [{String.t(), String.t()}]
        ) :: {:ok, response(), provider()} | {:error, term()}
  def request(source_provider, source_path, method, body, headers) do
    {_idx, target_provider, config} = Config.select_provider()

    # Parse body if it's a string
    parsed_body = parse_body(body)

    # Get target path for the selected provider
    target_path =
      ApiConverter.get_target_path(source_path, source_provider, target_provider)

    # Convert request from source format to target format
    {:ok, {converted_headers, converted_body}, _} =
      ApiConverter.convert_request(
        headers,
        parsed_body,
        source_provider,
        source_path,
        target_provider,
        target_path
      )

    case do_request_with_provider(
           target_provider,
           config,
           method,
           target_path,
           converted_body,
           converted_headers
         ) do
      {:ok, response} ->
        # Convert response from target format back to source format
        {:ok, restored} =
          ApiConverter.convert_response(
            response.body,
            source_provider,
            source_path,
            target_provider,
            target_path
          )

        {:ok, %{response | body: restored}, target_provider}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes a streaming request to a randomly selected LLM provider and chunks the response
  to the given Plug.Conn with automatic format conversion.

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
          headers :: [{String.t(), String.t()}]
        ) :: {:ok, Plug.Conn.t(), provider()} | {:error, term()}
  def stream(conn, stream_fun, source_provider, source_path, method, body, headers) do
    {_idx, target_provider, config} = Config.select_provider()

    # Parse body if it's a string
    parsed_body = parse_body(body)

    # Get target path for the selected provider
    target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

    # Convert request from source format to target format
    {:ok, {converted_headers, converted_body}, _} =
      ApiConverter.convert_request(
        headers,
        parsed_body,
        source_provider,
        source_path,
        target_provider,
        target_path
      )

    do_stream_with_provider(
      conn,
      stream_fun,
      source_provider,
      source_path,
      target_provider,
      config,
      method,
      target_path,
      converted_body,
      converted_headers
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
         headers
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
        config.timeout
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
         timeout
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

            # Convert chunk from target format to OpenAI format, then to source format
            converted_chunks =
              convert_stream_chunk(
                chunk,
                target_converter,
                source_converter,
                source_path
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

  defp convert_stream_chunk(chunk, target_converter, source_converter, source_path) do
    # First convert from target format to OpenAI format
    case target_converter.to_openai_stream_chunk(chunk, source_path) do
      {:done, chunks} ->
        chunks

      :done ->
        []

      {:error, _reason} ->
        # On error, pass through unchanged
        [chunk]

      openai_chunks ->
        # Then convert from OpenAI format to source format
        Enum.reduce(openai_chunks, [], fn openai_chunk, chunks ->
          case source_converter.from_openai_stream_chunk(openai_chunk, source_path) do
            {:done, new_chunks} -> new_chunks
            :done -> chunks
            {:error, _} -> chunks
            new_chunks -> chunks ++ new_chunks
          end
        end)
    end
  end

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)

  # Encodes the body as a stream for efficient transmission to the backend.
  # Returns an enumerable that yields chunks of the encoded body.
  defp stream_encode_body(body) when is_binary(body) do
    # Stream the binary in chunks of 8KB
    stream_binary(body, 8192)
  end

  defp stream_encode_body(body) when is_map(body) do
    # Encode to JSON first, then stream in chunks
    encoded = Jason.encode!(body)
    stream_binary(encoded, 8192)
  end

  defp stream_binary(binary, chunk_size) do
    Stream.unfold(0, fn skip ->
      case binary do
        <<_skipped::binary-size(skip), chunk::binary-size(chunk_size), _rest::binary>> ->
          {chunk, skip + chunk_size}

        <<_skipped::binary-size(skip)>> ->
          nil

        <<_skipped::binary-size(skip), chunk::binary>> ->
          {chunk, skip + byte_size(chunk)}
      end
    end)
  end
end
