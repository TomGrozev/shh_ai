defmodule ShhAiWeb.ProxyController do
  @moduledoc """
  Phoenix controller for the LLM Privacy Proxy.

  Handles all incoming requests and forwards to backends with automatic
  format conversion and PII sanitization.

  ## PII Sanitization Pipeline

  PII sanitization and restoration happen in the ProviderClient module,
  which ensures all operations are performed in OpenAI (canonical) format:

      Request (source format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  This ensures consistent PII handling regardless of source/target provider formats.
  """

  use ShhAiWeb, :controller

  require Logger

  alias ShhAi.{ApiConverter, Metrics, ModelCatalog}

  # Inbound header allowlist: the proxy forwards only content negotiation
  # headers and the opt-out header it consumes itself. `x-no-audit` is kept
  # because `ProviderClient.find_or_create_conversation/3` reads it for the
  # audit opt-out. Everything else — the client's `authorization` (the gate
  # token), `x-api-key`, cookies, hop-by-hop headers, `host`/`content-length`/
  # `transfer-encoding` — is dropped at this boundary and never reaches a
  # backend. 0.1 deliberately admits no provider passthrough headers
  # (e.g. `anthropic-beta`). See issue #55.
  @inbound_allowed_headers ~w(content-type accept x-no-audit)

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

  # Model-listing endpoints (`/v1/models`, `/api/tags`) are answered from the
  # cached `ShhAi.ModelCatalog` and never reach a provider instance (ADR-0013 §4).
  defp handle_request(%Plug.Conn{method: "GET", request_path: path} = conn, source_provider) do
    case ApiConverter.get_path_info(path, source_provider) do
      {:models, _path} -> serve_model_listing(conn, source_provider, path)
      _other -> forward_request(conn, source_provider)
    end
  end

  defp handle_request(conn, source_provider) do
    forward_request(conn, source_provider)
  end

  defp serve_model_listing(conn, source_provider, path) do
    converter = ApiConverter.get_converter(source_provider)
    listing = converter.from_openai_response(ModelCatalog.listing(), path)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(listing))
  end

  defp forward_request(conn, source_provider) do
    started = Metrics.capture_started()
    {method, path, body, headers, stream_requested?} = extract_request(conn)

    case stream_or_request(
           stream_requested?,
           conn,
           method,
           path,
           body,
           headers,
           source_provider,
           started
         ) do
      {:ok, conn} ->
        conn

      {:error, {:model_not_served, model} = reason} ->
        emit_request_error(started, source_provider, path, method, stream_requested?, reason)
        send_model_not_served_error(conn, model)

      {:error, reason} ->
        emit_request_error(started, source_provider, path, method, stream_requested?, reason)
        send_internal_error(conn)
    end
  end

  # Every request failure is recorded once, whatever response shape it gets.
  defp emit_request_error(started, source_provider, path, method, stream_requested?, reason) do
    Metrics.emit_error(started,
      source_provider: source_provider,
      target_provider: "none",
      request_path: path,
      method: method,
      streaming: stream_requested?,
      error_type: :request_error,
      error_message: inspect(reason)
    )
  end

  # A model no configured provider instance serves is a ShhAi-originated,
  # client-visible 4xx (ADR-0013 §3) — more debuggable than a passed-through
  # provider 404.
  defp send_model_not_served_error(conn, model) do
    send_error(conn, 404, ~s(model "#{model}" not served by any configured provider instance))
  end

  # Every other request failure stays a generic 500.
  defp send_internal_error(conn) do
    send_error(conn, 500, "Internal proxy error")
  end

  defp extract_request(conn) do
    headers =
      conn.req_headers
      |> Enum.filter(fn {name, _value} ->
        String.downcase(name) in @inbound_allowed_headers
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

    case ShhAi.ProviderClient.stream(
           conn,
           stream_fun,
           source_provider,
           path,
           method,
           body,
           headers,
           start_time: started
         ) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # non-streaming
  defp stream_or_request(false, conn, method, path, body, headers, source_provider, started) do
    case ShhAi.ProviderClient.request(
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
