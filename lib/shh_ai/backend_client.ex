defmodule ShhAi.BackendClient do
  @moduledoc """
  HTTP client for LLM backend providers.
  Uses Req with Finch connection pooling for high performance.
  Supports OpenAI, Anthropic, and Ollama APIs.
  """

  require Logger

  alias ShhAi.Config

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t() | map()
        }

  @doc """
  Makes a request to a randomly selected LLM provider.
  Returns the full response.
  """
  @spec request(
          method :: atom(),
          path :: String.t(),
          body :: map() | String.t(),
          headers :: [{String.t(), String.t()}]
        ) :: {:ok, response()} | {:error, term()}
  def request(method, path, body, headers) do
    {_idx, provider, config} = Config.select_provider()
    do_request_with_provider(provider, config, method, path, body, headers)
  end

  @doc """
  Makes a streaming request to a randomly selected LLM provider and chunks the response
  to the given Plug.Conn.

  The conn should already be set up with send_chunked/2 before calling this function.
  Returns {:ok, conn} on success or {:error, reason} on failure.
  """
  @spec stream(
          conn :: Plug.Conn.t(),
          stream_fun :: function(),
          method :: atom(),
          path :: String.t(),
          body :: map(),
          headers :: [{String.t(), String.t()}]
        ) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def stream(conn, stream_fun, method, path, body, headers) do
    {_idx, provider, config} = Config.select_provider()
    do_stream_with_provider(conn, stream_fun, provider, config, method, path, body, headers)
  end

  # Private helper functions

  defp do_request_with_provider(provider, config, method, path, body, headers) do
    with {:ok, url} <- build_url(config.base_url, path),
         auth_headers <- build_auth_headers(provider, config),
         request_headers <- merge_headers(auth_headers, headers),
         {:ok, response} <- do_request(method, url, body, request_headers, config.timeout) do
      {:ok, response}
    end
  end

  defp do_stream_with_provider(conn, stream_fun, provider, config, method, path, body, headers) do
    with {:ok, url} <- build_url(config.base_url, path),
         auth_headers <- build_auth_headers(provider, config),
         request_headers <- merge_headers(auth_headers, headers) do
      do_stream(conn, stream_fun, method, url, body, request_headers, config.timeout)
    end
  end

  # Private functions

  defp build_url(base_url, path) do
    url = String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/v1/")

    {:ok, url}
  end

  defp build_auth_headers(provider, config) do
    case provider do
      :openai ->
        case config.api_key do
          nil -> []
          key -> [{"Authorization", "Bearer #{key}"}]
        end

      :anthropic ->
        case config.api_key do
          nil -> []
          key -> [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}]
        end

      :ollama ->
        # Ollama typically doesn't require authentication
        []
    end
  end

  defp merge_headers(auth_headers, request_headers) do
    default_headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    default_headers ++ auth_headers ++ request_headers
  end

  defp do_request(method, url, body, headers, timeout) do
    body = encode_body(body)

    request =
      Req.new(
        url: url,
        method: method,
        headers: headers,
        body: body,
        receive_timeout: timeout,
        pool_timeout: 5_000,
        connect_options: [
          protocols: [:http2, :http1]
        ]
      )

    case Req.request(request) do
      {:ok, response} ->
        {:ok,
         %{
           status: response.status,
           headers: response.headers,
           body: response.body
         }}

      {:error, reason} ->
        Logger.error("Backend request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_stream(conn, stream_fun, method, url, body, headers, timeout) do
    body = encode_body(body)

    # Add streaming header
    headers = headers ++ [{"accept", "text/event-stream"}]

    request =
      Req.new(
        url: url,
        method: method,
        headers: headers,
        body: body,
        receive_timeout: timeout,
        pool_timeout: 5_000,
        connect_options: [
          protocols: [:http2, :http1]
        ],
        into: fn
          {:data, ""}, {req, resp, _} ->
            {:cont, {req, resp}}

          {:data, chunk}, acc ->
            {req, resp, a_conn} =
              case acc do
                {req, resp} -> {req, resp, conn}
                {req, resp, a_conn} -> {req, resp, a_conn}
              end

            case stream_fun.(chunk, a_conn) do
              {:cont, new_conn} ->
                {:cont, {req, resp, new_conn}}

              :halt ->
                {:halt, {req, resp}}
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

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
end
