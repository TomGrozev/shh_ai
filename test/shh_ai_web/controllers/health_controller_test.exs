defmodule ShhAiWeb.HealthControllerTest do
  @moduledoc """
  Route tests for the unauthenticated orchestration probes, `/health` and
  `/ready`. These sit on a bare pipeline: no API-key gate, no `force_ssl`
  redirect, no session. See issue #65.
  """

  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase

  alias ShhAi.Config

  describe "GET /health" do
    test "returns 200 with no admin auth configured (no auth gate)", %{conn: conn} do
      snapshot_env(["ADMIN_USER", "ADMIN_PASSWORD"])
      System.delete_env("ADMIN_USER")
      System.delete_env("ADMIN_PASSWORD")
      Config.load()

      conn = get(conn, ~p"/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end

  describe "GET /ready" do
    test "returns 200 when NER is disabled (test default)", %{conn: conn} do
      conn = get(conn, ~p"/ready")
      body = json_response(conn, 200)

      assert body == %{
               "status" => "ok",
               "checks" => %{"ner" => "disabled", "audit_db" => "disabled"}
             }
    end

    test "returns 503 when NER is enabled and not initialized", %{conn: conn} do
      snapshot_env(["PII_NER_ENABLED"])
      System.put_env("PII_NER_ENABLED", "true")

      :meck.new(ShhAi.PII.NER, [:passthrough])
      on_exit(fn -> :meck.unload() end)
      :meck.expect(ShhAi.PII.NER, :init, fn -> :ok end)
      Config.load()
      :meck.expect(ShhAi.PII.NER, :initialized?, fn -> false end)

      conn = get(conn, ~p"/ready")
      body = json_response(conn, 503)

      assert body["status"] == "not_ready"
      assert body["checks"]["ner"] == "error"
    end

    test "reports the audit sub-check but stays 200 when the DB is unwritable", %{conn: conn} do
      snapshot_env(["AUDIT_MODE", "AUDIT_ENCRYPTION_KEY"])
      System.put_env("AUDIT_MODE", "true")
      System.put_env("AUDIT_ENCRYPTION_KEY", Base.encode32(:crypto.strong_rand_bytes(32)))
      Config.load()

      :meck.new(ShhAi.Audit.Writer, [:passthrough])
      on_exit(fn -> :meck.unload() end)
      :meck.expect(ShhAi.Audit.Writer, :writable?, fn -> false end)

      conn = get(conn, ~p"/ready")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["checks"]["audit_db"] == "error"
    end
  end
end
