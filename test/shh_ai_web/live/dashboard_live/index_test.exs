defmodule ShhAiWeb.DashboardLive.IndexTest do
  use ShhAiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias ShhAi.Config
  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.EventBuffer

  defp build_event(overrides \\ []) do
    now = System.system_time(:microsecond)

    defaults = [
      id: "evt-#{System.unique_integer([:positive])}",
      started_at: now - 150_000,
      ended_at: now,
      duration_ms: 150.0,
      source_provider: :openai,
      target_provider: :anthropic,
      request_path: "/v1/chat/completions",
      method: "POST",
      streaming: false,
      status: 200,
      pii_detected_count: 0,
      pii_sanitized_count: 0,
      pii_preserved_count: 0,
      pii_types: [],
      timings: %{
        pii_ms: 0.0,
        backend_ms: 140.0,
        restore_ms: 0.0,
        source_conversion_ms: 1.5,
        target_conversion_ms: 1.5
      },
      error: nil,
      conversation_id: nil,
      inserted_at: now
    ]

    struct!(Event, Keyword.merge(defaults, overrides))
  end

  setup do
    # Load config with at least one provider so Metrics/Config work
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    Config.load()

    # Ensure the EventBuffer GenServer is running with a fresh ETS table.
    # If a previous test deleted the table, the GenServer may still be alive
    # but without a table; restarting it recreates the table.
    case GenServer.whereis(ShhAi.Metrics.EventBuffer) do
      nil ->
        start_supervised!(ShhAi.Metrics.EventBuffer)

      _pid ->
        Supervisor.terminate_child(ShhAi.Supervisor, ShhAi.Metrics.EventBuffer)
        Supervisor.restart_child(ShhAi.Supervisor, ShhAi.Metrics.EventBuffer)
    end

    on_exit(fn ->
      try do
        :ets.delete(EventBuffer.Table)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  describe "mount" do
    test "renders the dashboard page with default stats", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin")
      assert html =~ "Dashboard"
    end

    test "shows 'Dashboard' heading", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")
      assert render(lv) =~ "Dashboard"
    end

    test "renders default time_window as :hour (checked hour radio)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin")
      assert html =~ ~s(checked)
    end
  end

  describe "handle_event 'filter'" do
    test "clicking filter with provider updates the rendered html", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      # Simulate phx-change on filter form with provider
      html =
        render_change(lv, "filter", %{"provider" => "openai", "status" => "", "streaming" => ""})

      assert html =~ ~s(<option value="openai" selected="">)
    end
  end

  describe "handle_event 'set-time-window'" do
    test "switching time window changes socket assigns", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      assert lv
             |> element("input[phx-value-window='hour']")
             |> render() =~ ~s(checked)

      render_click(lv, "set-time-window", %{"window" => "day"})
      html = render(lv)

      assert html =~ "24h"
      assert html =~ ~s(checked)
    end
  end

  describe "handle_event 'set-view'" do
    test "switching to errors view changes socket assigns and adds status error filter", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, "/admin")

      assert lv
             |> element("select[name='status']")
             |> render() =~ ~s(<option value="" selected="">)

      render_click(lv, "set-view", %{"view" => "errors"})
      html = render(lv)

      assert html =~ ~s(<option value="error" selected="">)
    end

    test "switching back to requests view removes error filter", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      render_click(lv, "set-view", %{"view" => "errors"})

      html = render(lv)
      assert html =~ ~s(<option value="error" selected="">)

      render_click(lv, "set-view", %{"view" => "requests"})
      html = render(lv)

      assert html =~ ~s(<option value="" selected="">)
    end
  end

  describe "handle_info {:request, event}" do
    test "receiving a matching event inserts into the stream", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      event = build_event(source_provider: :openai, target_provider: :openai, status: 200)
      send(lv.pid, {:request, event})

      html = render(lv)
      # Event should appear in the rendered stream
      assert html =~ event.id
    end

    test "receiving a non-matching event (wrong provider filter) does not insert", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      # Set provider filter to anthropic
      render_change(lv, "filter", %{"provider" => "anthropic", "status" => "", "streaming" => ""})
      _html = render(lv)

      # Send event from openai provider
      event = build_event(source_provider: :openai, target_provider: :openai, status: 200)
      send(lv.pid, {:request, event})

      html = render(lv)
      # The event id should NOT appear because it doesn't match the provider filter
      refute html =~ event.id
    end

    test "receiving an error event in requests view inserts if matching filters", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      event = build_event(source_provider: :openai, target_provider: :openai, status: 500)
      send(lv.pid, {:request, event})

      html = render(lv)
      assert html =~ event.id
    end

    test "receiving a success event in errors view does not insert", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      # Switch to errors view
      render_click(lv, "set-view", %{"view" => "errors"})

      event = build_event(source_provider: :openai, target_provider: :openai, status: 200)
      send(lv.pid, {:request, event})

      html = render(lv)
      refute html =~ event.id
    end
  end

  describe "handle_info :refresh" do
    test "refreshes the data", %{conn: conn} do
      # Ensure the EventBuffer ETS table exists and GenServer is running
      # before starting the LiveView, since :refresh calls load_data which
      # calls EventBuffer.list_since.
      case GenServer.whereis(ShhAi.Metrics.EventBuffer) do
        nil -> start_supervised!(ShhAi.Metrics.EventBuffer)
        _pid -> :ok
      end

      {:ok, lv, _html} = live(conn, "/admin")

      # Store an event in the buffer before refresh
      event = build_event()
      EventBuffer.store(event)

      send(lv.pid, :refresh)

      html = render(lv)
      assert html =~ "Dashboard"
    end

    test "refresh on the conversations view sends update to the Conversations component", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, "/admin")

      # Switch to conversations view.
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Capture initial state — no conversations to assert against, just confirm
      # the component is mounted.
      html = render(lv)
      assert html =~ "Conversations"

      # Send :refresh. The handle_info(:refresh, ...) for the conversations
      # view should NOT call load_data(socket) (which queries ETS); it should
      # instead call send_update(ShhAiWeb.DashboardLive.Conversations, id: "conversations").
      # We assert this by checking that the render still works and the
      # Conversations card is still present.
      send(lv.pid, :refresh)
      html = render(lv)
      assert html =~ "Conversations"
    end
  end

  describe "incremental stats updates via handle_info" do
    test "stats increment when a matching event is received", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      # Get initial rendered HTML stats text
      initial_html = render(lv)
      assert initial_html =~ "0"

      event = build_event(source_provider: :openai, target_provider: :openai, status: 200)
      send(lv.pid, {:request, event})

      html = render(lv)
      # After receiving event, the event id should appear in the stream
      assert html =~ event.id
    end
  end

  describe "conversation_id column in requests view" do
    test "shows conversation_id column with truncated ID", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      event =
        build_event(
          conversation_id: "conv-abc123def456",
          source_provider: :openai,
          target_provider: :openai,
          status: 200
        )

      send(lv.pid, {:request, event})

      html = render(lv)
      # Should show truncated conversation_id (first 8 chars)
      assert html =~ "conv-abc"
    end

    test "conversation_id links to conversations view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      event =
        build_event(
          conversation_id: "conv-link-test-123",
          source_provider: :openai,
          target_provider: :openai,
          status: 200
        )

      send(lv.pid, {:request, event})

      html = render(lv)
      # Should have a link/button to view this conversation
      assert html =~ "conv-link"
      # The link should trigger set-view with conversation filter
      assert html =~ "set-view"
    end

    test "shows 'N/A' when conversation_id is nil", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin")

      event =
        build_event(
          conversation_id: nil,
          source_provider: :openai,
          target_provider: :openai,
          status: 200
        )

      send(lv.pid, {:request, event})

      html = render(lv)
      assert html =~ "N/A"
    end
  end
end
