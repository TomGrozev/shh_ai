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

  defp handle_request(conn, source_provider) do
    # source_provider determines the format of the incoming request
    # Target provider is selected randomly from pool for load balancing
    with {:ok, session_id} <- create_session(),
         {:ok, body, headers} <- extract_request(conn),
         stream_requested = is_streaming_request?(body),
         {:ok, conn} <-
           stream_or_request(
             stream_requested,
             conn,
             body,
             headers,
             session_id,
             source_provider
           ) do
      conn
    else
      {:error, :not_found} ->
        Logger.error("No session found")
        send_error(conn, 404, "Provider not found")

      {:error, reason} ->
        Logger.error("Proxy error: #{inspect(reason, pretty: true, limit: :infinity)}")
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

  defp stream_or_request(true, conn, body, headers, session_id, source_provider) do
    method = conn.method |> String.downcase() |> String.to_existing_atom()
    path = conn.request_path

    stream_fun = fn chunk, acc ->
      case chunk(acc, chunk) do
        {:ok, new_conn} ->
          {:cont, new_conn}

        {:error, reason} ->
          Logger.error("Failed to chunk response: #{inspect(reason)}")
          :halt
      end
    end

    # Parse body to map if it's a binary
    parsed_body = parse_body(body)

    case ShhAi.BackendClient.stream(
           conn,
           stream_fun,
           source_provider,
           path,
           method,
           parsed_body,
           headers,
           session_id: session_id
         ) do
      {:ok, response} ->
        if session_id, do: SessionStore.delete(session_id)

        {:ok, Req.Response.get_private(response, :req_conn)}

      {:error, reason} ->
        if session_id, do: SessionStore.delete(session_id)
        {:error, reason}
    end
  end

  defp stream_or_request(false, conn, body, headers, session_id, source_provider) do
    method = conn.method |> String.downcase() |> String.to_existing_atom()
    path = conn.request_path

    # Parse body to map if it's a binary
    parsed_body = parse_body(body)

    case ShhAi.BackendClient.request(
           source_provider,
           path,
           method,
           parsed_body,
           headers,
           session_id: session_id
         ) do
      {:ok, response, _target_provider} ->
        if session_id, do: SessionStore.delete(session_id)

        encoded_body = encode_body(response.body)

        {:ok, send_resp(conn, response.status, encoded_body)}

      {:error, reason} ->
        if session_id, do: SessionStore.delete(session_id)
        {:error, reason}
    end
  end

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp parse_body(body) when is_map(body), do: body
  defp parse_body(_), do: %{}

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
