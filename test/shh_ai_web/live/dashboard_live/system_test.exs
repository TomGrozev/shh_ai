defmodule ShhAiWeb.DashboardLive.SystemTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase
  import Phoenix.LiveViewTest

  alias ShhAi.Config
  alias ShhAi.Metrics.EventBuffer

  import ShhAiWeb.DashboardEventHelpers

  @endpoint ShhAiWeb.Endpoint

  setup do
    # These tests don't need the audit DB — they only test UI layout
    # with AUDIT_MODE=false. Just set up ETS and config.
    ShhAi.ConversationCase.setup_ets()

    # Default to audit-off mode for these tests
    snapshot_env(["AUDIT_MODE"])
    System.put_env("AUDIT_MODE", "false")
    Config.load()

    EventBuffer.clear()
    on_exit(fn -> EventBuffer.clear() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Stat cards row 1
  # ---------------------------------------------------------------------------

  describe "stat cards row 1" do
    test "renders all 4 stat cards when switching to system view", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "Uptime"
      assert html =~ "Latency p50"
      assert html =~ "Requests (1h)"
      assert html =~ "Error rate"
    end

    test "renders latency p99 subtext with p99 value", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "p99: "
    end
  end

  # ---------------------------------------------------------------------------
  # Stat cards row 2
  # ---------------------------------------------------------------------------

  describe "provider breakdown" do
    test "renders top providers panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "Top Providers"
    end

    test "shows provider breakdown when events exist", %{conn: conn} do
      EventBuffer.store(make_event(%{source_provider: :openai}))

      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "OpenAI"
    end
  end

  # ---------------------------------------------------------------------------
  # 24h chart
  # ---------------------------------------------------------------------------

  describe "24h request volume chart" do
    test "renders an SVG element", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "<svg"
      assert html =~ "viewBox=\"0 0 800 200\""
    end

    test "renders path elements for the chart", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "<path"
    end
  end

  # ---------------------------------------------------------------------------
  # Recent errors
  # ---------------------------------------------------------------------------

  describe "recent errors" do
    test "shows empty state when no errors", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "Recent errors"
      assert html =~ "No errors in the last 24 hours"
    end

    test "shows error rows when errors exist", %{conn: conn} do
      ev =
        make_event(%{
          status: 500,
          error: %{"reason" => "Internal server error"}
        })

      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "Recent errors"
      assert html =~ "grid-cols-[100px_1fr_60px_1fr]"
      assert html =~ "500"
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline stats
  # ---------------------------------------------------------------------------

  describe "pipeline stats" do
    test "renders all 3 pipeline stat cards", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "Pipeline p50 latency"
      assert html =~ "PII detection rate"
      assert html =~ "Cold Store size"
    end

    test "PII detection rate shows 0.0% when no events", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ "0.0%"
    end
  end

  # ---------------------------------------------------------------------------
  # Audit mode independence
  # ---------------------------------------------------------------------------

  describe "audit mode independence" do
    test "system view structure is identical regardless of audit mode", %{conn: conn} do
      # Audit OFF
      {:ok, view_off, html_off} = live(conn, ~p"/admin/system")

      # Audit ON
      :meck.new(ShhAi.Audit.Queries, [:passthrough])
      :meck.expect(ShhAi.Audit.Queries, :audit_mode?, fn -> true end)
      :meck.expect(ShhAi.Audit.Queries, :cold_store_size_bytes, fn -> 0 end)

      try do
        {:ok, view_on, html_on} = live(conn, ~p"/admin/system")

        # Core sections present in both
        for section <- [
              "Uptime",
              "Latency p50",
              "Requests (1h)",
              "Error rate",
              "Top Providers",
              "Request Rate (24h)",
              "Recent errors",
              "Pipeline p50 latency",
              "PII detection rate",
              "Cold Store size"
            ] do
          assert html_off =~ section, "Missing #{section} in audit-off"
          assert html_on =~ section, "Missing #{section} in audit-on"
        end
      after
        :meck.unload()
      end
    end
  end
end
