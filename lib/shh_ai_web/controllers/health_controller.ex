defmodule ShhAiWeb.HealthController do
  @moduledoc """
  Unauthenticated orchestration probes, `/health` and `/ready`.

  Both sit on a bare pipeline outside the proxy scopes: no inbound API-key
  plug, no `force_ssl` redirect (see `config/prod.exs`), and no body
  parsing. `/health` is liveness — 200 while the endpoint is up. `/ready`
  renders `ShhAi.Health.readiness/0` as 200 when serving is safe, 503
  otherwise. See issue #65.
  """

  use ShhAiWeb, :controller

  alias ShhAi.Health

  @doc "Liveness probe: 200 while the endpoint is up."
  @spec liveness(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def liveness(conn, _params) do
    :ok = Health.liveness()
    json(conn, %{"status" => "ok"})
  end

  @doc "Readiness probe: 200 when serving is safe, 503 otherwise."
  @spec readiness(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def readiness(conn, _params) do
    report = Health.readiness()
    {status, label} = readiness_response(report.ready)

    conn
    |> put_status(status)
    |> json(%{"status" => label, "checks" => report.checks})
  end

  defp readiness_response(true), do: {200, "ok"}
  defp readiness_response(false), do: {503, "not_ready"}
end
