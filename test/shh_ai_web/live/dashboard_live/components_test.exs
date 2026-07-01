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

  describe "chart/1" do
    test "renders chart container with id and data-key" do
      html =
        render_component(&chart/1,
          id: "request-volume-chart",
          title: "Request Volume",
          key: "request_volume"
        )

      assert html =~ "Request Volume"
      assert html =~ ~s(id="request-volume-chart")
      assert html =~ ~s(data-key="request_volume")
    end

    test "renders 'No Data' placeholder" do
      html =
        render_component(&chart/1,
          id: "latency-chart",
          title: "Latency",
          key: "latency"
        )

      assert html =~ "No Data"
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
end
