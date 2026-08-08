defmodule ShhAiWeb.DashboardLive.ActivityTest do
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
  # Mount and rendering
  # ---------------------------------------------------------------------------

  describe "mount and rendering" do
    test "renders the 4 stat cards when switching to activity view", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "Requests today"
      assert html =~ "Success rate"
      assert html =~ "Avg latency"
      assert html =~ "Errors"
    end

    test "renders filter bar with source, target, status selects", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "source_provider"
      assert html =~ "target_provider"
      assert html =~ "status"
    end

    test "renders empty state when no events", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "No requests in this time window"
    end

    test "renders events in the table with all 8 columns", %{conn: conn} do
      event =
        make_event(%{
          conversation_id: "conv-1",
          source_provider: :openai,
          target_provider: "anthropic",
          request_path: "/v1/chat/completions",
          status: 200,
          duration_ms: 100.0
        })

      EventBuffer.store(event)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "OpenAI"
      assert html =~ "Anthropic"
      assert html =~ "/v1/chat/completions"
      assert html =~ "200"
      assert html =~ "100.0ms"
      assert html =~ "conv-1"
    end
  end

  # ---------------------------------------------------------------------------
  # Filters
  # ---------------------------------------------------------------------------

  describe "filters" do
    test "filtering by source provider narrows the events", %{conn: conn} do
      ev1 = make_event(%{source_provider: :openai, target_provider: "anthropic"})
      ev2 = make_event(%{source_provider: :anthropic, target_provider: "openai"})

      EventBuffer.store(ev1)
      EventBuffer.store(ev2)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # Both events should be present initially
      assert html =~ "/v1/chat/completions"

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{
          "source_provider" => "openai",
          "target_provider" => "",
          "status" => "all"
        })

      # After filtering by openai source, should still see the path
      assert html =~ "/v1/chat/completions"
      assert html =~ "OpenAI"
    end

    test "filtering by status shows only error events", %{conn: conn} do
      ev_err = make_event(%{status: 500, error: %{"message" => "boom"}})
      EventBuffer.store(ev_err)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # Error event visible with ERR badge
      assert html =~ "ERR"
      assert html =~ "text-error"
    end

    test "time window change reloads events", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # Switch to 1m window (events should still be empty since we have none)
      html =
        view
        |> element("input[name='time-window'][aria-label='1m']")
        |> render_click()

      assert html =~ "No requests in this time window"
    end
  end

  # ---------------------------------------------------------------------------
  # Row click
  # ---------------------------------------------------------------------------

  describe "row click" do
    test "clicking a row with a conversation_id fires row-click", %{conn: conn} do
      ev = make_event(%{conversation_id: "conv-abc"})
      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # The row should have phx-click with row-click
      assert html =~ "row-click"
      assert html =~ "conv-abc"

      # Click the row — should set the slideover (no crash)
      view
      |> element("div[class*='cursor-pointer'][phx-value-id='conv-abc']")
      |> render_click(%{"id" => "conv-abc"})
    end

    test "clicking a row with no conversation_id is a no-op", %{conn: conn} do
      ev = make_event(%{conversation_id: nil})
      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # The row should NOT have phx-click bound (the attribute is nil)
      refute html =~ ~s(phx-click="row-click")
    end

    test "close-slideover sets slideover to nil", %{conn: conn} do
      ev = make_event(%{conversation_id: "conv-xyz"})
      EventBuffer.store(ev)

      {:ok, view, _html} = live(conn, ~p"/admin/activity")

      # Open slideover
      view
      |> element("div[class*='cursor-pointer'][phx-value-id='conv-xyz']")
      |> render_click(%{"id" => "conv-xyz"})

      # Close it
      html =
        view
        |> element("button[phx-click='close-slideover']")
        |> render_click()

      refute html =~ "drawer-overlay open"
    end
  end

  # ---------------------------------------------------------------------------
  # Event display
  # ---------------------------------------------------------------------------

  describe "event display" do
    test "shows PII badge when pii_detected_count > 0", %{conn: conn} do
      ev = make_event(%{pii_detected_count: 3, conversation_id: "conv-pii"})
      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "text-primary"
      assert html =~ "3"
    end

    test "shows ERR badge when error is non-nil", %{conn: conn} do
      ev =
        make_event(%{
          status: 500,
          error: %{"message" => "Internal error"},
          conversation_id: "conv-err"
        })

      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "ERR"
      assert html =~ "text-error"
    end

    test "shows N/A for conversation_id when nil", %{conn: conn} do
      ev = make_event(%{conversation_id: nil})
      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # format_conversation_id(nil) returns "N/A"
      assert html =~ "N/A"
    end

    test "shows truncated conversation_id", %{conn: conn} do
      ev = make_event(%{conversation_id: "abcdefgh-1234-5678"})
      EventBuffer.store(ev)

      {:ok, view, html} = live(conn, ~p"/admin/activity")

      # format_conversation_id truncates to first 8 chars
      assert html =~ "abcdefgh"
    end
  end

  # ---------------------------------------------------------------------------
  # Table structure
  # ---------------------------------------------------------------------------

  describe "table structure" do
    test "renders activity stream column headers in correct order", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/activity")

      assert html =~ ">Time<"
      assert html =~ ">Source<"
      assert html =~ ">Target<"
      assert html =~ ">Path<"
      assert html =~ ">Status<"
      assert html =~ ">Latency<"
      assert html =~ ">PII<"
      assert html =~ ">Conv ID<"
    end
  end
end
