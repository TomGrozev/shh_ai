defmodule ShhAiWeb.DashboardLive.ConversationsTest do
  use ShhAiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.ConversationStore
  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.EventBuffer

  # Helper to build a conversation
  defp build_conversation(attrs) do
    now = System.monotonic_time(:millisecond)

    %Conversation{
      conversation_id: Map.get(attrs, :conversation_id, "conv-#{System.unique_integer([:positive])}"),
      source_provider: Map.get(attrs, :source_provider, :openai),
      provider_conversation_id: Map.get(attrs, :provider_conversation_id, nil),
      mapping: %{},
      reverse_index: %{},
      created_at: Map.get(attrs, :created_at, now - 5000),
      last_active_at: Map.get(attrs, :last_active_at, now),
      fingerprint_hash: Map.get(attrs, :fingerprint_hash, nil),
      new?: true
    }
  end

  # Helper to build an event
  defp build_event(overrides) do
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

  defp cleanup_jsonl do
    path = Path.join([Application.app_dir(:shh_ai, "priv"), "metrics", "events.jsonl"])
    File.rm(path)
    File.rm(Path.dirname(path))
  end

  setup do
    cleanup_jsonl()

    # Load config with at least one provider so Metrics/Config work
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    Config.load()

    # Ensure ConversationStore is running
    case ConversationStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Ensure EventBuffer is running with a fresh ETS table
    case GenServer.whereis(EventBuffer) do
      nil ->
        start_supervised!(EventBuffer)

      _pid ->
        Supervisor.terminate_child(ShhAi.Supervisor, EventBuffer)
        Supervisor.restart_child(ShhAi.Supervisor, EventBuffer)
    end

    on_exit(fn ->
      cleanup_jsonl()

      try do
        :ets.delete(EventBuffer.Table)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # Use on_error: :warn to work around pre-existing duplicate element IDs
  # in the dashboard template (desktop + mobile chevron buttons share the same id).
  defp safe_live(conn, path) do
    live(conn, path, on_error: :warn)
  end

  describe "Conversations component" do
    test "renders conversation list with metadata", %{conn: conn} do
      # Create a conversation
      conv = build_conversation(%{
        conversation_id: "conv-1",
        source_provider: :openai,
        fingerprint_hash: nil
      })
      :ok = ConversationStore.create(conv)

      # Mount the LiveView first, then store events
      {:ok, lv, _html} = safe_live(conn, "/admin")

      # Store some events for this conversation
      event1 = build_event(conversation_id: "conv-1", pii_detected_count: 2)
      event2 = build_event(conversation_id: "conv-1", pii_detected_count: 3)
      EventBuffer.store(event1)
      EventBuffer.store(event2)
      Process.sleep(50)

      # Switch to conversations view
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Should show the conversation ID
      assert html =~ "conv-1"
      # Should show humanized source provider
      assert html =~ "OpenAI"
    end

    test "shows expandable rows with individual requests", %{conn: conn} do
      conv = build_conversation(%{conversation_id: "conv-expand"})
      :ok = ConversationStore.create(conv)

      {:ok, lv, _html} = safe_live(conn, "/admin")

      event = build_event(
        conversation_id: "conv-expand",
        id: "evt-expand-123",
        duration_ms: 250.0,
        pii_detected_count: 1
      )
      EventBuffer.store(event)
      Process.sleep(50)

      # Switch to conversations view
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Click to expand the conversation (target the row div with phx-target={@myself})
      html =
        lv
        |> element("div[phx-value-id='conv-expand']")
        |> render_click()

      # Should show the event details
      assert html =~ "evt-expand-123"
      assert html =~ "250"
    end

    test "toggling conversation collapses expanded row", %{conn: conn} do
      conv = build_conversation(%{conversation_id: "conv-toggle"})
      :ok = ConversationStore.create(conv)

      {:ok, lv, _html} = safe_live(conn, "/admin")

      event = build_event(conversation_id: "conv-toggle", id: "evt-toggle-1")
      EventBuffer.store(event)
      Process.sleep(50)

      render_click(lv, "set-view", %{"view" => "conversations"})

      # Expand
      html =
        lv
        |> element("div[phx-value-id='conv-toggle']")
        |> render_click()

      assert html =~ "evt-toggle-1"

      # Collapse
      html =
        lv
        |> element("div[phx-value-id='conv-toggle']")
        |> render_click()

      refute html =~ "evt-toggle-1"
    end

    test "conversations view tab is available and activatable", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # The conversations tab should be present
      assert html =~ "Conversations"
    end

    test "empty conversations list shows table headers", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Should show table headers even with no conversations
      assert html =~ "Conversation"
      assert html =~ "Turns"
      assert html =~ "PII"
    end

    test "receives real-time updates via PubSub", %{conn: conn} do
      conv = build_conversation(%{conversation_id: "conv-pubsub-test"})
      :ok = ConversationStore.create(conv)

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Initially no events
      refute html =~ "evt-pubsub"

      # Store a new event (this should trigger PubSub broadcast)
      event =
        build_event(
          conversation_id: "conv-pubsub-test",
          id: "evt-pubsub-123"
        )

      EventBuffer.store(event)

      # Broadcast to dashboard:conversations (simulating what Metrics.persist_handler does)
      Phoenix.PubSub.broadcast(
        ShhAi.PubSub,
        "dashboard:conversations",
        {:conversation_update, event}
      )

      # render flushes pending messages, triggering component reload
      _html = render(lv)

      # Expand the conversation to see events (target element with phx-target)
      html =
        lv
        |> element("div[phx-value-id='conv-pubsub-test']")
        |> render_click()

      assert html =~ "evt-pubsub-123"
    end
  end
end
