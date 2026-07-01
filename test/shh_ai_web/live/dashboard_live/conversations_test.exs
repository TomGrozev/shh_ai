defmodule ShhAiWeb.DashboardLive.ConversationsTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase
  import Phoenix.LiveViewTest

  alias ShhAi.Audit.ConversationMessage
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

  defp insert_event_with_pii(id, inserted_at, conversation_id, pii_detected_count, pii_types) do
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
      pii_detected_count: pii_detected_count,
      pii_sanitized_count: pii_detected_count,
      pii_preserved_count: 0,
      pii_types: Jason.encode!(pii_types),
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

  defp insert_message(conversation_id, role, sanitized_content, created_at) do
    %ConversationMessage{}
    |> ConversationMessage.changeset(%{
      conversation_id: conversation_id,
      role: role,
      sanitized_content: sanitized_content,
      created_at: created_at
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

    test "shows the audit-off indicator and stat cards", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Audit-off indicator text
      assert html =~ "Audit Mode OFF"

      # The 4 stat cards should render (conversations today, PII detected, total requests, avg latency)
      assert html =~ ~s(class="stat-card)
    end

    test "does not call audit-on-only Queries functions", %{conn: conn} do
      :meck.new(Queries, [:passthrough])

      # These functions should NOT be called when audit is OFF
      :meck.expect(Queries, :count_metadata_for_conversations, fn _ ->
        flunk("Queries.count_metadata_for_conversations/1 should not be called when audit is OFF")
      end)

      :meck.expect(Queries, :first_user_message_for_conversations, fn _ ->
        flunk(
          "Queries.first_user_message_for_conversations/1 should not be called when audit is OFF"
        )
      end)

      :meck.expect(Queries, :list_events, fn _ ->
        flunk("Queries.list_events/1 should not be called when audit is OFF")
      end)

      try do
        {:ok, lv, _html} = safe_live(conn, "/admin")
        _html = render_click(lv, "set-view", %{"view" => "conversations"})
      after
        :meck.unload(Queries)
      end
    end

    test "renders audit-off cards with request count and PII", %{conn: conn} do
      # Use meck to provide fake data since audit tables may not exist
      :meck.new(Queries, [:passthrough])

      :meck.expect(Queries, :audit_mode?, fn -> false end)

      :meck.expect(Queries, :list_conversations, fn _opts ->
        [
          %{conversation_id: "conv-audit-off-1", source_provider: "openai", last_active_at: nil}
        ]
      end)

      :meck.expect(Queries, :event_stats_for_conversations, fn _ids ->
        %{
          "conv-audit-off-1" => %{event_count: 3, total_pii: 1, avg_latency: 120.5}
        }
      end)

      :meck.expect(Queries, :pii_type_counts_for_conversations, fn _ids ->
        %{"conv-audit-off-1" => %{email: 2, phone: 1}}
      end)

      :meck.expect(Queries, :count_conversations_today, fn -> 1 end)
      :meck.expect(Queries, :count_pii_detected_today, fn -> 1 end)
      :meck.expect(Queries, :count_total_requests_today, fn -> 3 end)
      :meck.expect(Queries, :avg_latency_today, fn -> 120.5 end)

      try do
        {:ok, lv, _html} = safe_live(conn, "/admin")
        html = render_click(lv, "set-view", %{"view" => "conversations"})

        # Audit-off card renders with queue-card
        assert html =~ "queue-card"
        # Shows request count
        assert html =~ "3 requests"
        # Shows PII
        assert html =~ "1 PII"
        # Shows PII type chips
        assert html =~ "pii-type-chip"
        assert html =~ "Email"
        assert html =~ "Phone"
        # Does NOT show "Opted out" badge (audit-off, not tombstoned)
        refute html =~ "Opted out"
        # Does NOT have queue-card-preview (audit-off has no message preview)
        refute html =~ "queue-card-preview"
      after
        :meck.unload(Queries)
      end
    end

    test "the 'Conversations' tab is still activatable", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # The card title still renders.
      assert html =~ "Conversations"
      # And the OFF indicator renders.
      assert html =~ "Audit Mode OFF"
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

    test "renders conversation cards with provider tabs", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-card-1", now, last_active_at: now, source_provider: "openai")

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Truncated conversation ID (first 8 chars)
      assert html =~ "conv-card"

      # Provider badge
      assert html =~ "OpenAI"

      # Provider tab class
      assert html =~ "provider-tab openai"

      # Queue card wrapper
      assert html =~ "queue-card"
    end

    test "renders preview with placeholder chips when conversation has user message", %{
      conn: conn
    } do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-preview-1", now, last_active_at: now, source_provider: "openai")
      insert_message("conv-preview-1", "user", "Hi, I'm <NAME_1>", now)

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Preview area present
      assert html =~ "queue-card-preview"

      # Placeholder chip rendered
      assert html =~ "placeholder-chip"
      assert html =~ "NAME_1"

      # Truncated ID present
      assert html =~ "conv-preview"
    end

    test "renders tombstoned card with 'Opted out' badge", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      # Tombstone: opted_out=true and mapping=nil (default)
      insert_conversation("conv-tomb-1", now, opted_out: true, mapping: nil)

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Opted-out badge present
      assert html =~ "Opted out"
      assert html =~ "opted-out-badge"

      # No message preview for tombstoned cards
      refute html =~ "queue-card-preview"

      # Queue card still present
      assert html =~ "queue-card"
    end

    test "tombstoned card shows PII type chips", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-tomb-pii", now, opted_out: true, mapping: nil)
      insert_event_with_pii("evt-tomb-pii", now, "conv-tomb-pii", 3, ["email", "phone"])

      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # PII type chips rendered
      assert html =~ "pii-type-chip"
      assert html =~ "Email"
      assert html =~ "Phone"

      # Opted out badge
      assert html =~ "Opted out"
    end

    test "renders card click as LiveView event", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-click-1", now, last_active_at: now)

      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Click the card element — this should be a no-op (slice 3 will wire it).
      # Target the card via its phx-value-id attribute so the event goes to the
      # component (which has phx-target on the card).
      html =
        lv
        |> element("div[phx-value-id='conv-click-1']")
        |> render_click()

      # Should still render without error
      assert html =~ "queue-card"
      assert html =~ "conv-click"
    end

    test "stat card click activates filter", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-stat-1", now, last_active_at: now)
      insert_event_with_pii("evt-stat-pii", now, "conv-stat-1", 5, ["email"])

      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Click the PII stat card element (targets the component via phx-target)
      html =
        lv
        |> element("div[phx-value-filter='pii']")
        |> render_click()

      # At least one stat-card should have the "active" class
      assert html =~ ~s(class="stat-card active)
    end

    test "filter form renders with provider and filter selects", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Provider select present with options
      assert html =~ "OpenAI"
      assert html =~ "Anthropic"
      assert html =~ "Ollama"

      # Has PII select present
      assert html =~ "Has PII"

      # Opt-out select present
      assert html =~ "Opt-out"

      # Form has phx-change targeting the component
      assert html =~ "phx-change=\"filter\""
    end

    test "set-time-window event changes window", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Conversation from 2 days ago
      two_days_ago = NaiveDateTime.add(now, -2 * 86_400, :second)
      insert_conversation("conv-old-1", two_days_ago, last_active_at: two_days_ago)

      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Default window is :day — old conversation should NOT appear
      html = render(lv)
      refute html =~ "conv-old-1"

      # Switch to :week — old conversation SHOULD appear
      # Click the 7d radio button element (targets the component via phx-target)
      html =
        lv
        |> element("input[aria-label='7d']")
        |> render_click()

      assert html =~ "conv-old-1"

      # Switch to :minute — old conversation should NOT appear
      html =
        lv
        |> element("input[aria-label='1m']")
        |> render_click()

      refute html =~ "conv-old-1"
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

    test "empty SQLite renders no cards but stat cards still appear", %{conn: conn} do
      {:ok, lv, _html} = safe_live(conn, "/admin")
      html = render_click(lv, "set-view", %{"view" => "conversations"})

      # Stat cards still render
      assert html =~ "stat-card"

      # No queue-card elements (no conversations)
      refute html =~ "queue-card"
    end

    test "filter form with provider filters the list by provider", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-openai-1", now, source_provider: "openai")
      insert_conversation("conv-anthro-1", now, source_provider: "anthropic")

      {:ok, lv, _html} = safe_live(conn, "/admin")
      render_click(lv, "set-view", %{"view" => "conversations"})

      # Send the filter event with provider=openai, targeting the component form
      html =
        lv
        |> element("form[phx-change='filter']")
        |> render_change(%{"provider" => "openai", "has_pii" => "", "opted_out" => ""})

      assert html =~ "conv-openai-1"
      refute html =~ "conv-anthro-1"
    end
  end
end
