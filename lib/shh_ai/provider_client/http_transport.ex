defmodule ShhAi.ProviderClient.HTTPTransport do
  @moduledoc false

  require Logger

  @doc """
  Returns the base Req options shared by all HTTP requests (sync and streaming).

  Centralises connection-pool config so `do_request/5` and
  `StreamTransport.build_stream_request/2` stay in sync.
  """
  @spec base_request_opts() :: keyword()
  def base_request_opts do
    [
      pool_timeout: 5_000,
      connect_options: [
        protocols: [:http1]
      ]
    ]
  end

  @doc """
  Builds the full request URL from a base URL and a target path.

  Strips trailing `/` from `base_url` and leading `/v1/` from `path`,
  then joins them.
  """
  @spec build_url(String.t(), String.t()) :: String.t()
  def build_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.replace_prefix(path, "/v1/", "")
  end

  @doc """
  Builds the final header list for a request, including auth headers
  for the given provider.

  Deduplicates by header name (first occurrence wins).
  """
  @spec build_headers(atom(), [{String.t(), String.t()}], map()) :: [{String.t(), String.t()}]
  def build_headers(provider, headers, config) do
    default_headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    maybe_add_auth_header(provider, config, default_headers ++ headers)
    |> Enum.uniq_by(fn {k, _} -> k end)
  end

  @doc """
  Executes a non-streaming HTTP request via `Req`.
  """
  @spec do_request(atom(), String.t(), iodata(), [{String.t(), String.t()}], integer()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def do_request(method, url, body, headers, timeout) do
    body = encode_body(body)
    headers = Enum.reject(headers, fn {k, _v} -> k in ["connection"] end)

    request =
      Req.new(
        base_request_opts() ++
          [
            url: url,
            method: method,
            headers: headers,
            body: body,
            receive_timeout: timeout
          ]
      )

    case Req.request(request) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("Backend request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Encodes a body to iodata for a non-streaming request.
  """
  @spec encode_body(binary() | map()) :: iodata()
  def encode_body(body) when is_binary(body), do: body
  def encode_body(body) when is_map(body), do: Jason.encode!(body)

  @doc """
  Encodes a body as a stream for efficient transmission to the backend.
  Returns an enumerable that yields 8 KB chunks.
  """
  @spec stream_encode_body(binary() | map()) :: Enumerable.t()
  def stream_encode_body(body) when is_binary(body) do
    ShhAi.Utils.Stream.stream_binary(body, 8192)
  end

  def stream_encode_body(body) when is_map(body) do
    encoded = Jason.encode!(body)
    ShhAi.Utils.Stream.stream_binary(encoded, 8192)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_add_auth_header(_, %{api_key: nil}, headers), do: headers

  defp maybe_add_auth_header(:anthropic, %{api_key: key}, headers) do
    [{"x-api-key", key}, {"anthropic-version", "2023-06-01"} | headers]
  end

  defp maybe_add_auth_header(provider, %{api_key: key}, headers)
       when provider in [:openai, :ollama] do
    [{"authorization", "Bearer #{key}"} | headers]
  end
end
