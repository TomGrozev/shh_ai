defmodule ShhAiWeb.DashboardLive.SystemTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase
  import Phoenix.LiveViewTest

  alias ShhAi.Config
  alias ShhAi.Metrics.{Event, EventBuffer}

  @endpoint ShhAiWeb.Endpoint

  setup do
    setup_audit()

    # Default to audit-off mode for these tests
    snapshot_env(["AUDIT_MODE"])
    System.put_env("AUDIT_MODE", "false")
    Config.load()

    EventBuffer.clear()
    on_exit(fn -> EventBuffer.clear() end)
    :ok
  end

  defp make_event(overrides \\ %{}) do
    now = System.system_time(:microsecond)

    default = %Event{
      id: "ev-#{System.unique_integer([:positive])}",
      started_at: now - 100_000,
      ended_at: now,
      duration_ms: 100.0,
      source_provider: :openai,
      target_provider: "anthropic",
      request_path: "/v1/chat/completions",
      method: "POST",
      streaming: false,
      status: 200,
      conversation_id: nil,
      pii_detected_count: 0,
      pii_sanitized_count: 0,
      pii_preserved_count: 0,
      pii_types: [],
      timings: %{
        pii_ms: 5.0,
        backend_ms: 80.0,
        restore_ms: 2.0,
        source_conversion_ms: 1.0,
        target_conversion_ms: 1.0
      },
      error: nil,
      inserted_at: now
    }

    Map.merge(default, overrides)
  end

  defp switch_to_system(view) do
    render_click(view, "set-view", %{"view" => "system"})
  end

  # ---------------------------------------------------------------------------
  # Stat cards row 1
  # ---------------------------------------------------------------------------

  describe "stat cards row 1" do
    test "renders all 4 stat cards when switching to system view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Uptime (30d)"
      assert html =~ "Latency p50"
      assert html =~ "Requests (1h)"
      assert html =~ "Error rate"
    end

    test "renders uptime subtext", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Session uptime; 30d tracking not yet built"
    end

    test "renders latency p99 subtext with p99 value", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "p99: "
    end
  end

  # ---------------------------------------------------------------------------
  # Stat cards row 2
  # ---------------------------------------------------------------------------

  describe "provider breakdown" do
    test "renders top providers panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Top Providers"
    end

    test "shows provider breakdown when events exist", %{conn: conn} do
      EventBuffer.store(make_event(%{source_provider: :openai}))

      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "OpenAI"
    end
  end

  # ---------------------------------------------------------------------------
  # 24h chart
  # ---------------------------------------------------------------------------

  describe "24h request volume chart" do
    test "renders an SVG element", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "<svg"
      assert html =~ "viewBox=\"0 0 800 200\""
    end

    test "renders chart heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Request Rate (24h)"
    end

    test "renders path elements for the chart", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "<path"
    end
  end

  # ---------------------------------------------------------------------------
  # Recent errors
  # ---------------------------------------------------------------------------

  describe "recent errors" do
    test "shows empty state when no errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

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

      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Recent errors"
      assert html =~ "recent-error-row"
      assert html =~ "500"
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline stats
  # ---------------------------------------------------------------------------

  describe "pipeline stats" do
    test "renders all 3 pipeline stat cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Pipeline p50 latency"
      assert html =~ "PII detection recall"
      assert html =~ "Cold Store size"
    end

    test "PII detection recall shows 0.0% when no events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "0.0%"
    end

    test "Cold Store size shows a value", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = switch_to_system(view)

      assert html =~ "Cold Store size"
      assert html =~ "SQLite · encrypted at rest"
    end
  end

  # ---------------------------------------------------------------------------
  # Audit mode independence
  # ---------------------------------------------------------------------------

  describe "audit mode independence" do
    test "system view structure is identical regardless of audit mode", %{conn: conn} do
      # Audit OFF
      {:ok, view_off, _html} = live(conn, ~p"/admin")
      html_off = switch_to_system(view_off)

      # Audit ON
      :meck.new(ShhAi.Audit.Queries, [:passthrough])
      :meck.expect(ShhAi.Audit.Queries, :audit_mode?, fn -> true end)
      :meck.expect(ShhAi.Audit.Queries, :cold_store_size_bytes, fn -> 0 end)

      try do
        {:ok, view_on, _html} = live(conn, ~p"/admin")
        html_on = switch_to_system(view_on)

        # Core sections present in both
        for section <- [
              "Uptime (30d)",
              "Latency p50",
              "Requests (1h)",
              "Error rate",
              "Top Providers",
              "Request Rate (24h)",
              "Recent errors",
              "Pipeline p50 latency",
              "PII detection recall",
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
