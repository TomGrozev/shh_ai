defmodule ShhAiWeb.DashboardLive.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import ShhAiWeb.DashboardLive.Components

  describe "stats_card/1" do
    test "renders with title, value, and icon" do
      html =
        render_component(&stats_card/1,
          title: "Total Requests",
          value: 42,
          icon: "hero-cube"
        )

      assert html =~ "Total Requests"
      assert html =~ "42"
      assert html =~ "hero-cube"
    end

    test "renders subtext when provided" do
      html =
        render_component(&stats_card/1,
          title: "Errors",
          value: 3,
          icon: "hero-exclamation-triangle",
          subtext: "2 client errors"
        )

      assert html =~ "Errors"
      assert html =~ "3"
      assert html =~ "2 client errors"
    end

    test "does not render subtext paragraph when nil" do
      html =
        render_component(&stats_card/1,
          title: "Success",
          value: 39,
          icon: "hero-check-circle",
          subtext: nil
        )

      assert html =~ "Success"
      assert html =~ "39"
      refute html =~ "text-xs text-base-content/50"
    end
  end

  describe "filter_bar/1" do
    test "renders with default filters" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      assert html =~ "Provider"
      assert html =~ "Status"
      assert html =~ "Type"
      assert html =~ "Window"
    end

    test "renders provider select with options" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      assert html =~ "All"
      assert html =~ "OpenAI"
      assert html =~ "Anthropic"
      assert html =~ "Ollama"
    end

    test "renders status select with options" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      assert html =~ "Success"
      assert html =~ "Error"
    end

    test "renders streaming select with options" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      assert html =~ "Streaming"
      assert html =~ "Non-Streaming"
    end

    test "renders time window radio buttons" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      assert html =~ "1m"
      assert html =~ "1h"
      assert html =~ "24h"
      assert html =~ "7d"
    end

    test "marks correct time window radio as checked" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, status: nil, streaming: nil},
          time_window: :day
        )

      # The radio for day should have checked attribute
      assert html =~ ~s(checked)
    end

    test "renders has_pii and opted_out selects" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, has_pii: nil, opted_out: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      assert html =~ "Has PII"
      assert html =~ "Opt-out"
      # Yes/No options present
      assert html =~ ~s(>Yes<)
      assert html =~ ~s(>No<)
    end

    test "marks has_pii Yes when filter is true" do
      html =
        render_component(&filter_bar/1,
          filters: %{provider: nil, has_pii: true, opted_out: nil, status: nil, streaming: nil},
          time_window: :hour
        )

      # The "Yes" option for has_pii should be selected
      assert html =~ ~s(selected value="true") or html =~ ~s(value="true" selected)
    end
  end

  # ---------------------------------------------------------------------------
  # provider_tab_class/1
  # ---------------------------------------------------------------------------

  describe "provider_tab_class/1" do
    test "returns the openai tab class" do
      assert provider_tab_class(:openai) == "provider-tab openai"
    end

    test "returns the anthropic tab class" do
      assert provider_tab_class(:anthropic) == "provider-tab anthropic"
    end

    test "returns the ollama tab class" do
      assert provider_tab_class(:ollama) == "provider-tab ollama"
    end

    test "accepts strings as input" do
      assert provider_tab_class("openai") == "provider-tab openai"
    end

    test "defaults to openai for unknown input" do
      assert provider_tab_class(:unknown) == "provider-tab openai"
    end
  end

  # ---------------------------------------------------------------------------
  # split_with_placeholders/1
  # ---------------------------------------------------------------------------

  describe "split_with_placeholders/1" do
    test "returns text only when no placeholders" do
      assert split_with_placeholders("Hello world") == [{:text, "Hello world"}]
    end

    test "splits on a single placeholder" do
      assert split_with_placeholders("Hi <NAME_1>") == [
               {:text, "Hi "},
               {:placeholder, "<NAME_1>"}
             ]
    end

    test "splits on multiple placeholders" do
      result = split_with_placeholders("<EMAIL_1> and <PHONE_1>")

      assert result == [
               {:placeholder, "<EMAIL_1>"},
               {:text, " and "},
               {:placeholder, "<PHONE_1>"}
             ]
    end

    test "handles non-binary input" do
      assert split_with_placeholders(nil) == []
    end
  end

  # ---------------------------------------------------------------------------
  # stat_card_clickable/1
  # ---------------------------------------------------------------------------

  describe "stat_card_clickable/1" do
    test "renders with title, value, and icon" do
      html =
        render_component(&stat_card_clickable/1,
          title: "Total Requests",
          value: 42,
          icon: "hero-cube"
        )

      assert html =~ "Total Requests"
      assert html =~ "42"
      assert html =~ "hero-cube"
    end

    test "includes active class when active=true" do
      html =
        render_component(&stat_card_clickable/1,
          title: "PII",
          value: 5,
          icon: "hero-shield-check",
          active: true
        )

      assert html =~ ~s(class="stat-card active")
    end

    test "includes phx-click with on_click event" do
      html =
        render_component(&stat_card_clickable/1,
          title: "Test",
          value: 1,
          icon: "hero-cube",
          on_click: "my-event"
        )

      assert html =~ ~s(phx-click="my-event")
    end

    test "includes phx-value-filter when filter is set" do
      html =
        render_component(&stat_card_clickable/1,
          title: "PII",
          value: 0,
          icon: "hero-shield-check",
          filter: "pii"
        )

      assert html =~ ~s(phx-value-filter="pii")
    end
  end

  # ---------------------------------------------------------------------------
  # opted_out_badge/1
  # ---------------------------------------------------------------------------

  describe "opted_out_badge/1" do
    test "renders Opted out text" do
      html = render_component(&opted_out_badge/1)
      assert html =~ "Opted out"
    end

    test "includes opted-out-badge class" do
      html = render_component(&opted_out_badge/1)
      assert html =~ "opted-out-badge"
    end
  end

  # ---------------------------------------------------------------------------
  # conversation_card/1
  # ---------------------------------------------------------------------------

  describe "conversation_card/1" do
    setup do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      [now_us: now_us]
    end

    test "renders provider tab", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hello",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ "provider-tab openai"
    end

    test "renders provider badge", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hello",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ "OpenAI"
      assert html =~ "provider-badge"
    end

    test "renders preview text", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hello world",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ "Hello world"
    end

    test "renders placeholder chips", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hi <NAME_1>",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ "placeholder-chip"
      assert html =~ "NAME_1"
    end

    test "renders truncated conversation ID with tooltip", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "abcdefgh-1234-5678",
          preview: "Hi",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      # First 8 chars displayed
      assert html =~ "abcdefgh"
      # Full ID in tooltip
      assert html =~ ~s(data-tip="abcdefgh-1234-5678")
    end

    test "renders PII count when greater than 0", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hi",
          source_provider: :openai,
          total_pii: 5,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ "5 PII"
    end

    test "renders zero PII count", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hi",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ "0 PII"
    end

    test "renders turn count", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-1",
          preview: "Hi",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 3,
          last_active_at_us: now_us
        )

      assert html =~ "3 turns"
    end

    test "includes phx-click and phx-value-id", %{now_us: now_us} do
      html =
        render_component(&conversation_card/1,
          id: "conv-test-id",
          preview: "Hi",
          source_provider: :openai,
          total_pii: 0,
          turn_count: 1,
          last_active_at_us: now_us
        )

      assert html =~ ~s(phx-click="card-click")
      assert html =~ ~s(phx-value-id="conv-test-id")
    end
  end

  # ---------------------------------------------------------------------------
  # conversation_card_tombstoned/1
  # ---------------------------------------------------------------------------

  describe "conversation_card_tombstoned/1" do
    setup do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      [now_us: now_us]
    end

    test "renders provider tab", %{now_us: now_us} do
      html =
        render_component(&conversation_card_tombstoned/1,
          id: "conv-tomb-1",
          source_provider: :anthropic,
          request_count: 3,
          pii_type_count: 2,
          pii_types: [:email, :phone],
          total_pii: 5,
          last_active_at_us: now_us
        )

      assert html =~ "provider-tab anthropic"
    end

    test "renders Opted out badge", %{now_us: now_us} do
      html =
        render_component(&conversation_card_tombstoned/1,
          id: "conv-tomb-1",
          source_provider: :anthropic,
          request_count: 3,
          pii_type_count: 2,
          pii_types: [:email, :phone],
          total_pii: 5,
          last_active_at_us: now_us
        )

      assert html =~ "Opted out"
    end

    test "renders request count", %{now_us: now_us} do
      html =
        render_component(&conversation_card_tombstoned/1,
          id: "conv-tomb-1",
          source_provider: :anthropic,
          request_count: 3,
          pii_type_count: 2,
          pii_types: [:email, :phone],
          total_pii: 5,
          last_active_at_us: now_us
        )

      assert html =~ "3 requests"
    end

    test "renders PII type chips", %{now_us: now_us} do
      html =
        render_component(&conversation_card_tombstoned/1,
          id: "conv-tomb-1",
          source_provider: :anthropic,
          request_count: 3,
          pii_type_count: 2,
          pii_types: [:email, :phone],
          total_pii: 5,
          last_active_at_us: now_us
        )

      assert html =~ "pii-type-chip"
      assert html =~ "Email"
      assert html =~ "Phone"
    end

    test "does not render preview area", %{now_us: now_us} do
      html =
        render_component(&conversation_card_tombstoned/1,
          id: "conv-tomb-1",
          source_provider: :anthropic,
          request_count: 3,
          pii_type_count: 2,
          pii_types: [:email, :phone],
          total_pii: 5,
          last_active_at_us: now_us
        )

      refute html =~ "queue-card-preview"
    end
  end

  # ---------------------------------------------------------------------------
  # conversation_card_audit_off/1
  # ---------------------------------------------------------------------------

  describe "conversation_card_audit_off/1" do
    setup do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      [now_us: now_us]
    end

    test "renders provider tab", %{now_us: now_us} do
      html =
        render_component(&conversation_card_audit_off/1,
          id: "conv-audit-off-1",
          source_provider: :openai,
          request_count: 1,
          pii_types: [],
          total_pii: 0,
          last_active_at_us: now_us
        )

      assert html =~ "provider-tab openai"
    end

    test "does not render Opted out badge", %{now_us: now_us} do
      html =
        render_component(&conversation_card_audit_off/1,
          id: "conv-audit-off-1",
          source_provider: :openai,
          request_count: 1,
          pii_types: [],
          total_pii: 0,
          last_active_at_us: now_us
        )

      refute html =~ "Opted out"
    end

    test "renders request count and PII", %{now_us: now_us} do
      html =
        render_component(&conversation_card_audit_off/1,
          id: "conv-audit-off-1",
          source_provider: :openai,
          request_count: 1,
          pii_types: [],
          total_pii: 0,
          last_active_at_us: now_us
        )

      assert html =~ "1 request"
      assert html =~ "0 PII"
    end

    test "renders PII type chips", %{now_us: now_us} do
      html =
        render_component(&conversation_card_audit_off/1,
          id: "conv-audit-off-1",
          source_provider: :openai,
          request_count: 2,
          pii_types: [:email, :phone],
          total_pii: 3,
          last_active_at_us: now_us
        )

      assert html =~ "pii-type-chip"
      assert html =~ "Email"
      assert html =~ "Phone"
    end

    test "does not render preview area", %{now_us: now_us} do
      html =
        render_component(&conversation_card_audit_off/1,
          id: "conv-audit-off-1",
          source_provider: :openai,
          request_count: 1,
          pii_types: [],
          total_pii: 0,
          last_active_at_us: now_us
        )

      refute html =~ "queue-card-preview"
    end
  end

  # ---------------------------------------------------------------------------
  # slideover/1
  # ---------------------------------------------------------------------------

  describe "slideover/1" do
    test "renders nothing when slideover is nil" do
      html = render_component(&slideover/1, slideover: nil, phx_target: "comp-1")
      refute html =~ "drawer-overlay"
    end

    test "renders slideover panel when slideover data is provided" do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

      slideover = %{
        id: "conv-test",
        view: :chat,
        source_provider: :openai,
        target_provider: :anthropic,
        last_active_at_us: now_us,
        turn_count: 5,
        badge: nil,
        pii_types: %{email: 2},
        messages: [],
        events: [],
        mapping: %{},
        expanded_event_id: nil
      }

      html = render_component(&slideover/1, slideover: slideover, phx_target: "comp-1")
      assert html =~ "drawer-overlay open"
      assert html =~ "Conversation Review"
      assert html =~ "Source Provider"
      assert html =~ "Target Provider"
      assert html =~ "OpenAI"
      assert html =~ "Anthropic"
    end

    test "renders audit_off badge in footer" do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

      slideover = %{
        id: "conv-test",
        view: :stats,
        source_provider: :openai,
        target_provider: nil,
        last_active_at_us: now_us,
        turn_count: 0,
        badge: :audit_off,
        pii_types: %{},
        messages: [],
        events: [],
        mapping: %{},
        expanded_event_id: nil
      }

      html = render_component(&slideover/1, slideover: slideover, phx_target: "comp-1")
      assert html =~ "Audit Mode OFF"
    end

    test "renders opted_out badge in footer" do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

      slideover = %{
        id: "conv-test",
        view: :stats,
        source_provider: :openai,
        target_provider: nil,
        last_active_at_us: now_us,
        turn_count: 0,
        badge: :opted_out,
        pii_types: %{},
        messages: [],
        events: [],
        mapping: %{},
        expanded_event_id: nil
      }

      html = render_component(&slideover/1, slideover: slideover, phx_target: "comp-1")
      assert html =~ "Conversation opted out"
    end

    test "PII tags in slideover header have filter attributes" do
      now_us = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

      slideover = %{
        id: "conv-test",
        view: :chat,
        source_provider: :openai,
        target_provider: :anthropic,
        last_active_at_us: now_us,
        turn_count: 5,
        badge: nil,
        pii_types: %{email: 2, name: 1},
        messages: [],
        events: [],
        mapping: %{},
        expanded_event_id: nil
      }

      html = render_component(&slideover/1, slideover: slideover, phx_target: "comp-1")
      assert html =~ ~s(data-pii-filter="EMAIL")
      assert html =~ ~s(data-pii-filter="NAME")
      assert html =~ "Email"
      assert html =~ "×2"
      assert html =~ "Name"
      assert html =~ "×1"
    end
  end

  # ---------------------------------------------------------------------------
  # pii_tag/1
  # ---------------------------------------------------------------------------

  describe "pii_tag/1" do
    test "renders PII type and count" do
      html = render_component(&pii_tag/1, type: :email, count: 3)
      assert html =~ "pii-tag"
      assert html =~ "Email"
      assert html =~ "×3"
    end

    test "renders clickable attributes for PII filter" do
      html = render_component(&pii_tag/1, type: :email, count: 3)
      assert html =~ ~s(data-pii-filter="EMAIL")
      assert html =~ "Email"
      assert html =~ "×3"
    end
  end

  # ---------------------------------------------------------------------------
  # chat_message/1
  # ---------------------------------------------------------------------------

  describe "chat_message/1" do
    test "renders user message with role label" do
      msg = %{
        id: "msg-1",
        role: "user",
        sanitized_content: "Hello world",
        created_at: ~N[2025-01-15 10:30:00]
      }

      html = render_component(&chat_message/1, message: msg, index: 0, mapping: %{})
      assert html =~ "chat-msg"
      assert html =~ "User"
      assert html =~ "Hello world"
      assert html =~ "chat-role user"
    end

    test "renders assistant message with role label" do
      msg = %{
        id: "msg-2",
        role: "assistant",
        sanitized_content: "Hi there!",
        created_at: ~N[2025-01-15 10:30:05]
      }

      html = render_component(&chat_message/1, message: msg, index: 1, mapping: %{})
      assert html =~ "Assistant"
      assert html =~ "Hi there!"
      assert html =~ "chat-role assistant"
    end

    test "renders placeholder chips in message content" do
      msg = %{
        id: "msg-3",
        role: "user",
        sanitized_content: "Hi <NAME_1>, your email is <EMAIL_1>",
        created_at: ~N[2025-01-15 10:30:00]
      }

      mapping = %{"<NAME_1>" => "Alex", "<EMAIL_1>" => "alex@test.com"}

      html = render_component(&chat_message/1, message: msg, index: 0, mapping: mapping)
      assert html =~ "placeholder-chip"
      assert html =~ "NAME_1"
      assert html =~ "EMAIL_1"
    end

    test "placeholder chip has phx-click and tooltip data for popover" do
      msg = %{
        id: "msg-pop",
        role: "user",
        sanitized_content: "Hi <NAME_1>",
        created_at: ~N[2025-01-15 10:30:00]
      }

      mapping = %{"<NAME_1>" => "Alex Chen"}

      html = render_component(&chat_message/1, message: msg, index: 0, mapping: mapping)

      # Click handler for opening the popover
      assert html =~ ~s(phx-click="open-placeholder-popover")
      assert html =~ ~s(phx-value-placeholder="&lt;NAME_1&gt;")
      assert html =~ ~s(phx-value-original="Alex Chen")
      assert html =~ ~s(phx-value-pii-type="NAME")

      # Hover tooltip with the original value
      assert html =~ ~s(data-tooltip="Alex Chen")
    end

    test "renders flagged text with flagged-fn class when text is in flagged_false_negatives" do
      msg = %{
        id: "msg-fn-1",
        role: "user",
        sanitized_content: "Please call me at 555-1234 tomorrow",
        created_at: ~N[2025-01-15 10:30:00]
      }

      mapping = %{}
      flagged = ["555-1234"]

      html =
        render_component(&chat_message/1,
          message: msg,
          index: 0,
          mapping: mapping,
          flagged_false_negatives: flagged
        )

      assert html =~ ~s(class="flagged-fn")
      assert html =~ "555-1234"
    end

    test "does not render flagged-fn class when no texts are flagged" do
      msg = %{
        id: "msg-fn-2",
        role: "user",
        sanitized_content: "Just a normal message with no PII",
        created_at: ~N[2025-01-15 10:30:00]
      }

      mapping = %{}

      html =
        render_component(&chat_message/1,
          message: msg,
          index: 0,
          mapping: mapping,
          flagged_false_negatives: []
        )

      refute html =~ "flagged-fn"
    end

    test "chat_message renders msg-highlight class when active is true" do
      msg = %{
        id: "msg-hl-1",
        role: "user",
        sanitized_content: "Hello world",
        created_at: ~N[2025-01-15 10:30:00]
      }

      mapping = %{}

      html =
        render_component(&chat_message/1,
          message: msg,
          index: 0,
          mapping: mapping,
          active: true
        )

      assert html =~ "msg-highlight"
    end

    test "chat_message does not render msg-highlight class when active is false" do
      msg = %{
        id: "msg-hl-2",
        role: "assistant",
        sanitized_content: "Hi back",
        created_at: ~N[2025-01-15 10:30:00]
      }

      mapping = %{}

      html =
        render_component(&chat_message/1,
          message: msg,
          index: 1,
          mapping: mapping,
          active: false
        )

      refute html =~ "msg-highlight"
    end

    test "renders tool_call message with tool card" do
      msg = %{
        id: "msg-4",
        role: "tool_call",
        sanitized_content: '{"name": "search"}',
        created_at: ~N[2025-01-15 10:30:01]
      }

      html = render_component(&chat_message/1, message: msg, index: 1, mapping: %{})
      assert html =~ "tool-card"
      assert html =~ "Tool call"
    end

    test "renders tool_result message with tool card" do
      msg = %{
        id: "msg-5",
        role: "tool_result",
        sanitized_content: '{"results": []}',
        created_at: ~N[2025-01-15 10:30:02]
      }

      html = render_component(&chat_message/1, message: msg, index: 2, mapping: %{})
      assert html =~ "tool-card"
      assert html =~ "Tool result"
    end

    test "renders timestamp" do
      msg = %{
        id: "msg-6",
        role: "user",
        sanitized_content: "Test",
        created_at: ~N[2025-01-15 14:30:45]
      }

      html = render_component(&chat_message/1, message: msg, index: 0, mapping: %{})
      assert html =~ "14:30:45"
    end
  end

  # ---------------------------------------------------------------------------
  # message_nav_rail/1
  # ---------------------------------------------------------------------------

  describe "message_nav_rail/1" do
    test "renders a nav rail with id msg-nav-rail" do
      messages = [
        %{id: "m1", role: "user", sanitized_content: "Hi", created_at: ~N[2025-01-15 10:30:00]},
        %{
          id: "m2",
          role: "assistant",
          sanitized_content: "Hello",
          created_at: ~N[2025-01-15 10:31:00]
        }
      ]

      html =
        render_component(
          fn assigns ->
            apply(ShhAiWeb.DashboardLive.Components, :message_nav_rail, [assigns])
          end,
          messages: messages,
          active_index: 0,
          phx_target: nil
        )

      assert html =~ ~s(id="msg-nav-rail")
      assert html =~ "msg-nav-dot"
    end

    test "renders one dot per message with correct data-msg-index" do
      messages = [
        %{id: "m1", role: "user", sanitized_content: "Hi", created_at: ~N[2025-01-15 10:30:00]},
        %{
          id: "m2",
          role: "assistant",
          sanitized_content: "Hello",
          created_at: ~N[2025-01-15 10:31:00]
        },
        %{
          id: "m3",
          role: "tool_call",
          sanitized_content: "{}",
          created_at: ~N[2025-01-15 10:32:00]
        },
        %{
          id: "m4",
          role: "tool_result",
          sanitized_content: "result",
          created_at: ~N[2025-01-15 10:33:00]
        }
      ]

      html =
        render_component(
          fn assigns ->
            apply(ShhAiWeb.DashboardLive.Components, :message_nav_rail, [assigns])
          end,
          messages: messages,
          active_index: 0,
          phx_target: nil
        )

      assert html =~ ~s(data-msg-index="0")
      assert html =~ ~s(data-msg-index="1")
      assert html =~ ~s(data-msg-index="2")
      assert html =~ ~s(data-msg-index="3")
    end

    test "first dot is active when active_index is 0" do
      messages = [
        %{id: "m1", role: "user", sanitized_content: "Hi", created_at: ~N[2025-01-15 10:30:00]},
        %{
          id: "m2",
          role: "assistant",
          sanitized_content: "Hello",
          created_at: ~N[2025-01-15 10:31:00]
        }
      ]

      html =
        render_component(
          fn assigns ->
            apply(ShhAiWeb.DashboardLive.Components, :message_nav_rail, [assigns])
          end,
          messages: messages,
          active_index: 0,
          phx_target: nil
        )

      # The first dot should have the active class
      # Count "msg-nav-dot ... active" vs "msg-nav-dot " (without active)
      first_dot =
        Regex.run(~r/class="[^"]*msg-nav-dot[^"]*"[^>]*data-msg-index="0"[^>]*/, html)
        |> List.first()

      refute is_nil(first_dot)
      assert first_dot =~ "active"
    end

    test "dots are styled by message type" do
      messages = [
        %{id: "m1", role: "user", sanitized_content: "Hi", created_at: ~N[2025-01-15 10:30:00]},
        %{
          id: "m2",
          role: "assistant",
          sanitized_content: "Hello",
          created_at: ~N[2025-01-15 10:31:00]
        },
        %{
          id: "m3",
          role: "tool_call",
          sanitized_content: "{}",
          created_at: ~N[2025-01-15 10:32:00]
        },
        %{
          id: "m4",
          role: "tool_result",
          sanitized_content: "result",
          created_at: ~N[2025-01-15 10:33:00]
        }
      ]

      html =
        render_component(
          fn assigns ->
            apply(ShhAiWeb.DashboardLive.Components, :message_nav_rail, [assigns])
          end,
          messages: messages,
          active_index: 0,
          phx_target: nil
        )

      assert html =~ ~r(class="[^"]*user[^"]*"[^>]*data-msg-index="0")
      assert html =~ ~r(class="[^"]*assistant[^"]*"[^>]*data-msg-index="1")
      assert html =~ ~r(class="[^"]*tool[^"]*"[^>]*data-msg-index="2")
      assert html =~ ~r(class="[^"]*result[^"]*"[^>]*data-msg-index="3")
    end
  end

  # ---------------------------------------------------------------------------
  # request_log_row/1
  # ---------------------------------------------------------------------------

  describe "request_log_row/1" do
    test "renders request row with time, path, status, latency" do
      event = %{
        id: "evt-1",
        ended_at: ~N[2025-01-15 10:30:00],
        inserted_at: ~N[2025-01-15 10:30:00],
        method: "POST",
        request_path: "/v1/chat/completions",
        status: 200,
        duration_ms: 150.5,
        pii_detected_count: 0,
        pii_types: "[]",
        conversation_id: "conv-1"
      }

      html =
        render_component(&request_log_row/1, event: event, expanded: false, phx_target: "comp-1")

      assert html =~ "request-log-row"
      assert html =~ "POST /v1/chat/completions"
      assert html =~ "200"
      assert html =~ "150.5ms"
      assert html =~ "rl-time"
    end

    test "renders expanded details when expanded is true" do
      event = %{
        id: "evt-2",
        ended_at: ~N[2025-01-15 10:30:00],
        inserted_at: ~N[2025-01-15 10:30:00],
        method: "POST",
        request_path: "/v1/chat/completions",
        status: 200,
        duration_ms: 100.0,
        pii_detected_count: 2,
        pii_types: Jason.encode!([:email, :phone]),
        conversation_id: "conv-1"
      }

      html =
        render_component(&request_log_row/1, event: event, expanded: true, phx_target: "comp-1")

      assert html =~ "request-expand visible"
      assert html =~ "Method + Path"
      assert html =~ "Status"
      assert html =~ "Latency"
      assert html =~ "PII count"
      assert html =~ "View in Activity"
      assert html =~ "view-activity-btn"
    end

    test "does not render View in Activity button when conversation_id is nil" do
      event = %{
        id: "evt-nil",
        ended_at: ~N[2025-01-15 10:30:00],
        inserted_at: ~N[2025-01-15 10:30:00],
        method: "POST",
        request_path: "/v1/chat/completions",
        status: 200,
        duration_ms: 50.0,
        pii_detected_count: 0,
        pii_types: "[]",
        conversation_id: nil
      }

      html =
        render_component(&request_log_row/1, event: event, expanded: true, phx_target: "comp-1")

      assert html =~ "request-expand visible"
      refute html =~ "View in Activity"
      refute html =~ "view-activity-btn"
    end

    test "renders View in Activity button with phx-click" do
      event = %{
        id: "evt-3",
        ended_at: ~N[2025-01-15 10:30:00],
        inserted_at: ~N[2025-01-15 10:30:00],
        method: "GET",
        request_path: "/health",
        status: 200,
        duration_ms: 10.0,
        pii_detected_count: 0,
        pii_types: "[]",
        conversation_id: "conv-1"
      }

      html =
        render_component(&request_log_row/1, event: event, expanded: true, phx_target: "comp-1")

      assert html =~ "view-activity-btn"
      assert html =~ "View in Activity"
    end
  end

  # ---------------------------------------------------------------------------
  # request_volume_chart/1
  # ---------------------------------------------------------------------------

  describe "request_volume_chart/1" do
    test "renders an SVG element" do
      now_us = System.system_time(:microsecond)
      data = for i <- 0..23, do: {now_us - (23 - i) * 3_600_000_000, rem(i, 10)}

      html = render_component(&request_volume_chart/1, data: data, now_us: now_us)
      assert html =~ "<svg"
      assert html =~ "viewBox=\"0 0 800 200\""
    end

    test "renders path elements for the chart line and area" do
      now_us = System.system_time(:microsecond)
      data = for i <- 0..23, do: {now_us - (23 - i) * 3_600_000_000, rem(i, 10)}

      html = render_component(&request_volume_chart/1, data: data, now_us: now_us)
      assert html =~ "<path"
      assert html =~ "fill=\"url(#chart-gradient)\""
    end

    test "renders Y-axis labels (0, 10, 20, 30, 40)" do
      now_us = System.system_time(:microsecond)
      data = for i <- 0..23, do: {now_us - (23 - i) * 3_600_000_000, 0}

      html = render_component(&request_volume_chart/1, data: data, now_us: now_us)
      assert html =~ "40"
      assert html =~ "30"
      assert html =~ "20"
      assert html =~ "10"
      assert html =~ "0"
    end

    test "renders current-value dot" do
      now_us = System.system_time(:microsecond)
      data = for i <- 0..23, do: {now_us - (23 - i) * 3_600_000_000, 5}

      html = render_component(&request_volume_chart/1, data: data, now_us: now_us)
      assert html =~ "<circle"
    end

    test "handles empty data (24 zero-bucket points) without crashing" do
      now_us = System.system_time(:microsecond)
      data = for _i <- 0..23, do: {0, 0}

      html = render_component(&request_volume_chart/1, data: data, now_us: now_us)
      assert html =~ "<svg"
    end

    test "renders gradient definition" do
      now_us = System.system_time(:microsecond)
      data = for i <- 0..23, do: {now_us - (23 - i) * 3_600_000_000, rem(i, 10)}

      html = render_component(&request_volume_chart/1, data: data, now_us: now_us)
      assert html =~ "<linearGradient"
      assert html =~ "chart-gradient"
    end
  end
end
