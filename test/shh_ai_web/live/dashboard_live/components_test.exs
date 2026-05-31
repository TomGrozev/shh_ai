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
end
