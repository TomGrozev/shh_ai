defmodule ShhAiWeb.ProxyController do
  @moduledoc """
  Phoenix controller for the LLM Privacy Proxy.

  Handles all incoming requests and forwards to backends with automatic
  format conversion and PII sanitization.

  ## PII Sanitization Pipeline

  PII sanitization and restoration happen in the BackendClient module,
  which ensures all operations are performed in OpenAI (canonical) format:

      Request (source format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  This ensures consistent PII handling regardless of source/target provider formats.
  """

  use ShhAiWeb, :controller

  require Logger

  alias ShhAi.Metrics

  @doc """
  Handles OpenAI-compatible API requests.
  Routes to the appropriate backend based on the path.
  """
  def handle_openai(conn, _params) do
    handle_request(conn, :openai)
  end

  @doc """
  Handles Anthropic API requests.
  """
  def handle_anthropic(conn, _params) do
    handle_request(conn, :anthropic)
  end

  @doc """
  Handles Ollama API requests.
  """
  def handle_ollama(conn, _params) do
    handle_request(conn, :ollama)
  end

  # Private functions

  defp handle_request(conn, source_provider) do
    started = Metrics.now()
    {method, path, body, headers, stream_requested?} = extract_request(conn)

    with {:ok, conn} <-
           stream_or_request(
             stream_requested?,
             conn,
             method,
             path,
             body,
             headers,
             source_provider,
             started
           ) do
      conn
    else
      {:error, reason} ->
        Metrics.emit_error(started,
          source_provider: source_provider,
          target_provider: "none",
          request_path: path,
          method: method,
          streaming: stream_requested?,
          error_type: :request_error,
          error_message: inspect(reason)
        )

        send_error(conn, 500, "Internal proxy error")
    end
  end

  defp extract_request(conn) do
    headers =
      conn.req_headers
      |> Enum.filter(fn
        {"host", _} -> false
        {"content-length", _} -> false
        {"transfer-encoding", _} -> false
        _ -> true
      end)

    body = get_body(conn)

    method = conn.method |> String.downcase() |> String.to_existing_atom()
    path = conn.request_path

    stream_requested? = streaming_request?(body)

    {method, path, body, headers, stream_requested?}
  end

  defp get_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{aspect: :body_params} ->
        # Body was not parsed, read from request body
        case conn.assigns[:raw_body] do
          nil -> %{}
          body when is_binary(body) -> Jason.decode!(body)
          body -> body
        end

      body when is_map(body) and map_size(body) > 0 ->
        body

      _ ->
        %{}
    end
  end

  # streaming
  defp stream_or_request(true, conn, method, path, body, headers, source_provider, started) do
    stream_fun = fn chunk, acc ->
      case chunk(acc, chunk) do
        {:ok, new_conn} ->
          {:cont, new_conn}

        {:error, reason} ->
          Logger.error("Failed to chunk response: #{inspect(reason)}")
          :halt
      end
    end

    case ShhAi.BackendClient.stream(
           conn,
           stream_fun,
           source_provider,
           path,
           method,
           body,
           headers,
           start_time: started
         ) do
      {:ok, response} ->
        {:ok, Req.Response.get_private(response, :req_conn)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # non-streaming
  defp stream_or_request(false, conn, method, path, body, headers, source_provider, started) do
    case ShhAi.BackendClient.request(
           source_provider,
           path,
           method,
           body,
           headers,
           start_time: started
         ) do
      {:ok, response} ->
        encoded_body = encode_body(response.body)
        {:ok, send_resp(conn, response.status, encoded_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp streaming_request?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"stream" => stream?}} when stream? in [true, "true"] -> true
      _ -> false
    end
  end

  defp streaming_request?(%{"stream" => true}), do: true
  defp streaming_request?(%{"stream" => "true"}), do: true
  defp streaming_request?(_), do: false

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body), do: inspect(body)

  defp send_error(conn, status, message) do
    error_response = %{
      error: %{
        message: message,
        type: "proxy_error"
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(error_response))
  end
end
