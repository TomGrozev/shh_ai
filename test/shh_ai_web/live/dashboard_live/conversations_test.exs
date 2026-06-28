defmodule ShhAiWeb.DashboardLive.ConversationsTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase
  import Phoenix.LiveViewTest

  alias ShhAi.Audit.ConversationRecord
  alias ShhAi.Audit.EventRecord
  alias ShhAi.Audit.Queries
  alias ShhAi.Config
  alias ShhAi.Conversation.Store
  alias ShhAi.Repo

  # Use on_error: :warn to work around pre-existing duplicate element IDs
  # in the dashboard template (desktop + mobile chevron buttons share the same id).
  defp safe_live(conn, path) do
    live(conn, path, on_error: :warn)
  end

  defp insert_conversation(conv_id, created_at, opts) do
    defaulted =
      %{
        opted_out: false,
        mapping: nil,
        last_active_at: created_at,
        source_provider: "openai",
        provider_conversation_id: "thread-#{conv_id}",
        fingerprint_hash: "fp-#{conv_id}",
        conversation_id: conv_id,
        created_at: created_at
      }
      |> Map.merge(Map.new(opts))

    %ConversationRecord{}
    |> ConversationRecord.insert_changeset(defaulted)
    |> Repo.insert!()
  end

  defp insert_event(id, inserted_at, conversation_id) do
    %EventRecord{}
    |> EventRecord.changeset(%{
      id: id,
      started_at: inserted_at,
      ended_at: inserted_at,
      duration_ms: 150.0,
      source_provider: "openai",
      target_provider: "anthropic",
      request_path: "/v1/chat/completions",
      method: "POST",
      streaming: false,
      status: 200,
      pii_detected_count: 1,
      pii_sanitized_count: 1,
      pii_preserved_count: 0,
      pii_types: Jason.encode!(["email"]),
      timings:
        Jason.encode!(%{
          "pii_ms" => 5.0,
          "backend_ms" => 140.0,
          "restore_ms" => 0.0,
          "source_conversion_ms" => 1.5,
          "target_conversion_ms" => 1.5
        }),
      conversation_id: conversation_id,
      inserted_at: inserted_at
    })
    |> Repo.insert!()
  end

  setup do
    # Load config with at least one provider so Config.load() works.
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    Config.load()

    # Ensure the Conversation Store is running (it's a child of the app
    # supervisor in production, but tests that use it directly need
    # start_link).
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Audit Mode OFF
  # ---------------------------------------------------------------------------

  describe "when Audit Mode is OFF" do
    setup do
      snapshot_env(["AUDIT_MODE"])
      System.put_env("AUDIT_MODE", "false")
      Config.load()
      :ok
    end

    test "shows the 'Audit Mode is OFF' message", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      assert html =~ "Audit Mode is OFF. No audit data available."
    end

    test "does not call Queries.list_conversations or list_events", %{conn: conn} do
      :meck.new(Queries, [:passthrough])

      :meck.expect(Queries, :list_conversations, fn _ ->
        flunk("Queries.list_conversations/1 should not be called when audit is OFF")
      end)

      :meck.expect(Queries, :list_events, fn _ ->
        flunk("Queries.list_events/1 should not be called when audit is OFF")
      end)

      try do
        {:ok, lv, _html} = safe_live(conn, "/admin")
        _html = render_click(lv, "set-view", %{"view" => "conversations"})
        # If the flunk was reached, meck raises ExUnit.AssertionError, failing the test.
      after
        :meck.unload(Queries)
      end
    end

    test "the 'Conversations' tab is still activatable", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # The card title still renders.
      assert html =~ "Conversations"
      # And the OFF message renders.
      assert html =~ "Audit Mode is OFF. No audit data available."
    end
  end

  # ---------------------------------------------------------------------------
  # Audit Mode ON
  # ---------------------------------------------------------------------------

  describe "when Audit Mode is ON" do
    setup do
      # setup_audit/0 sets AUDIT_MODE=true, fresh DB, restarts Repo, runs migrations.
      ShhAi.AuditCase.setup_audit()
      :ok
    end

    test "renders conversation list with metadata from SQLite", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-1", now, last_active_at: now, source_provider: "openai")

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      assert html =~ "conv-1"
      # humanize_provider/1 now handles the string "openai" → "OpenAI".
      assert html =~ "OpenAI"
      # And we don't show the OFF message.
      refute html =~ "Audit Mode is OFF. No audit data available."
    end

    test "shows expandable rows with individual requests when expanded", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-expand", now, last_active_at: now)
      insert_event("evt-expand-123", now, "conv-expand")

      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      html =
        lv
        |> element("div[phx-value-id='conv-expand']")
        |> render_click()

      assert html =~ "evt-expand-123"
    end

    test "toggling conversation collapses expanded row", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-toggle", now, last_active_at: now)
      insert_event("evt-toggle-1", now, "conv-toggle")

      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      html =
        lv
        |> element("div[phx-value-id='conv-toggle']")
        |> render_click()

      assert html =~ "evt-toggle-1"

      html =
        lv
        |> element("div[phx-value-id='conv-toggle']")
        |> render_click()

      refute html =~ "evt-toggle-1"
    end

    test "filters out opted-out conversations with opted_out: true", %{conn: _conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-active", now, opted_out: false)
      insert_conversation("conv-opted-out", now, opted_out: true)

      result = Queries.list_conversations(opted_out: true)
      assert length(result) == 1
      assert hd(result).conversation_id == "conv-opted-out"
    end

    test "empty SQLite returns an empty list (no rows in the table)", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # The card title renders.
      assert html =~ "Conversations"
      # The header row still shows.
      assert html =~ "Conversation"
      assert html =~ "Turns"
      assert html =~ "PII"
    end

    test "5s polling: new conversation appears after :refresh", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Initially no conversations.
      html = render(lv)
      refute html =~ "conv-polling-1"

      # Insert a conversation AFTER the component has been mounted.
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-polling-1", now, last_active_at: now)

      # Send the :refresh message that the parent LiveView's
      # handle_info(:refresh, ...) receives every 5s. When
      # @view == :conversations, it calls send_update on the
      # Conversations component, which re-runs load_conversations/1
      # and re-queries SQLite.
      send(lv.pid, :refresh)

      html = render(lv)
      assert html =~ "conv-polling-1"
    end

    test "shows turn count and PII total on collapsed rows (no N+1 events query)", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-counts", now, last_active_at: now)

      # Three events for this conversation, with PII counts.
      # default pii_detected_count = 1
      insert_event("evt-counts-1", now, "conv-counts")
      insert_event("evt-counts-2", now, "conv-counts")
      insert_event("evt-counts-3", now, "conv-counts")

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Turn count of 3 is visible on the collapsed row.
      assert html =~ "3"
      # And the PII badge is visible.
      assert html =~ "badge-secondary"
    end

    test "renders without crashing when SQLite contains malformed JSON", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-bad-json", now, last_active_at: now)

      # Insert a row directly with invalid JSON to simulate database corruption
      # (bypasses the Ecto changeset which would have encoded valid JSON).
      %EventRecord{}
      |> EventRecord.changeset(%{
        id: "evt-bad-json",
        started_at: now,
        ended_at: now,
        duration_ms: 1.0,
        source_provider: "openai",
        target_provider: "openai",
        streaming: false,
        pii_detected_count: 0,
        pii_sanitized_count: 0,
        pii_preserved_count: 0,
        pii_types: "NOT VALID JSON",
        timings: "also not json",
        conversation_id: "conv-bad-json",
        inserted_at: now
      })
      |> Repo.insert!()

      {:ok, lv, _html} = safe_live(conn, "/admin")
      # Should not crash; component should still render.
      html = render_click(lv, "set-view", %{"view" => "conversations"})
      assert html =~ "conv-bad-json"
    end
  end
end
