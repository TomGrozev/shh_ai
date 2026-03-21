defmodule ShhAiWeb.ProxyController do
  @moduledoc """
  Phoenix controller for the LLM Privacy Proxy.
  Handles all incoming requests, sanitizes PII, forwards to backends,
  and restores PII in responses.
  """

  use ShhAiWeb, :controller

  require Logger

  alias ShhAi.SessionStore

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

  defp handle_request(conn, _provider_hint) do
    # Provider hint is no longer used - provider is selected randomly from pool
    # This allows for load balancing across multiple backends
    with {:ok, session_id} <- create_session(),
         {:ok, body, headers} <- extract_request(conn),
         {:ok, sanitized_body, mapping} <- sanitize_request(body, conn),
         stream_requested = is_streaming_request?(body),
         :ok <- store_mapping(session_id, mapping),
         {:ok, conn} <-
           stream_or_request(stream_requested, conn, sanitized_body, headers, session_id) do
      conn
    else
      {:error, :not_found} ->
        send_error(conn, 404, "Provider not found")

      {:error, reason} ->
        Logger.error("Proxy error: #{inspect(reason)}")
        send_error(conn, 500, "Internal proxy error")
    end
  end

  defp create_session do
    SessionStore.create()
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
    {:ok, body, headers}
  end

  defp get_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{aspect: :body_params} ->
        # Body was not parsed, read from request body
        case conn.assigns[:raw_body] do
          nil -> "{}"
          body when is_binary(body) -> body
          body -> Jason.encode!(body)
        end

      body when is_map(body) and map_size(body) > 0 ->
        Jason.encode!(body)

      _ ->
        "{}"
    end
  end

  defp sanitize_request(body, _conn) do
    # Phase 1: Pass-through (no PII sanitization yet)
    # Phase 2 will add actual PII detection and sanitization
    {:ok, body, %{}}
  end

  defp store_mapping(session_id, mapping) do
    SessionStore.put(session_id, mapping)
  end

  defp stream_or_request(true, conn, body, headers, session_id) do
    method = conn.method |> String.downcase() |> String.to_existing_atom()
    path = conn.request_path

    stream_fun = fn chunk, acc ->
      restore_response(chunk, session_id)

      case chunk(acc, chunk) do
        {:ok, new_conn} ->
          {:cont, new_conn}

        {:error, _reason} ->
          :halt
      end
    end

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, _response} = ShhAi.BackendClient.stream(conn, stream_fun, method, path, body, headers)

    if session_id, do: ShhAi.SessionStore.delete(session_id)

    {:ok, conn}
    # |> put_resp_headers(response.headers)
  end

  defp stream_or_request(false, conn, body, headers, session_id) do
    method = conn.method |> String.downcase() |> String.to_existing_atom()
    path = conn.request_path

    with {:ok, response} <- ShhAi.BackendClient.request(method, path, body, headers),
         {:ok, restored} <- restore_response(response.body, session_id) do
      conn =
        conn
        |> put_resp_headers(response.headers)
        |> send_resp(response.status, encode_body(restored))

      if session_id, do: ShhAi.SessionStore.delete(session_id)

      {:ok, conn}
    end
  end

  defp is_streaming_request?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"stream" => true}} -> true
      {:ok, %{"stream" => "true"}} -> true
      _ -> false
    end
  end

  defp is_streaming_request?(%{"stream" => true}), do: true
  defp is_streaming_request?(%{"stream" => "true"}), do: true
  defp is_streaming_request?(_), do: false

  defp restore_response(response, session_id) do
    # Get the mapping for this session
    case ShhAi.SessionStore.get(session_id) do
      {:ok, _mapping} ->
        # Phase 1: Pass-through (no restoration needed)
        # Phase 2 will add actual PII restoration
        {:ok, response}

      {:error, _} ->
        {:ok, response}
    end
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, [value]}, conn ->
      put_resp_header(conn, String.downcase(key), value)
    end)
  end

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
