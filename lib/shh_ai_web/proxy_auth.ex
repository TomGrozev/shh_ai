defmodule ShhAiWeb.ProxyAuth do
  @moduledoc """
  Inbound API-key gate for the proxy scopes (`/v1` and `/api`).

  The proxy is an authenticated service: every request must carry
  `authorization: Bearer <key>` where `<key>` matches one of the operator's
  `PROXY_API_KEYS`. This plug is the boundary that keeps an open, unauthenticated
  proxy from being abused as an anonymous upstream.

  Fail-closed: when `PROXY_API_KEYS` is unconfigured the gate refuses every
  request with `503`, so a misconfigured deployment serves nothing rather than
  an unauthenticated proxy.

  The orchestration probes (`/health`, `/ready`) live in a separate scope and
  are intentionally **not** gated (issue #65).
  """

  @behaviour Plug

  import Plug.Conn

  alias ShhAi.Config

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Config.proxy_api_keys() do
      [] ->
        # The loud warning lives at boot (`ShhAi.Application.start/2`); logging
        # here would repeat once per refused request.
        respond(conn, 503, "Proxy is not configured: PROXY_API_KEYS is not set.")

      keys ->
        if authorized?(conn, keys) do
          conn
        else
          respond(conn, 401, "Invalid or missing proxy API key.")
        end
    end
  end

  # Whether the conn carries a valid `Bearer` gate token. The token is compared
  # against every configured key in constant time.
  defp authorized?(conn, keys) do
    case bearer_token(conn) do
      nil -> false
      token -> Enum.any?(keys, &secure_match?(&1, token))
    end
  end

  # Extracts the token from `authorization: Bearer <token>`. The scheme is
  # case-insensitive; a missing header, a non-Bearer scheme, or an empty token
  # all yield `nil` (unauthorized).
  defp bearer_token(conn) do
    with [value] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(value, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         token = String.trim(token),
         true <- token != "" do
      token
    else
      _ -> nil
    end
  end

  # Hashing both sides first makes them fixed-length, so `secure_compare/2`
  # never leaks a configured key's length (or any prefix-match timing).
  defp secure_match?(key, token) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, key), :crypto.hash(:sha256, token))
  end

  defp respond(conn, status, message) do
    body = %{error: %{message: message, type: "proxy_error"}}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
