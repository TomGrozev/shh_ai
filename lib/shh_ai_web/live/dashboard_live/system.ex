defmodule ShhAiWeb.DashboardLive.System do
  @moduledoc """
  LiveComponent for displaying system-level stats, request volume chart,
  recent errors, and pipeline stats for the admin dashboard.
  """

  use ShhAiWeb, :live_component

  alias ShhAi.Audit.Queries
  alias ShhAi.Metrics.{EventBuffer, Stats}
  alias ShhAiWeb.DashboardLive.Components

  @impl true
  def mount(socket) do
    socket =
      socket
      |> assign(:stat_cards_row1, %{
        uptime: "—",
        latency_p50: "—",
        latency_p99: "—",
        error_rate: "—"
      })
      |> assign(:stat_cards_row2, %{top_source: "—", top_target: "—", pipeline_p50: "—"})
      |> assign(:chart_data, [])
      |> assign(:chart_now_us, System.system_time(:microsecond))
      |> assign(:recent_errors, [])
      |> assign(:pipeline_stats, %{pii_rate: "—", cold_store_size: "—", audit_mode: false})
      |> assign(:error_count, 0)

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)
    {:ok, load(socket)}
  end

  # No-op — parent sends via send_update
  def handle_info(_, socket), do: {:noreply, socket}

  # ── Data loading ──────────────────────────────────────────────────

  defp load(socket) do
    events = EventBuffer.list_recent(limit: 1000)

    # Row 1
    uptime_us = Stats.app_uptime_us()
    latency_p50 = Stats.latency_percentile(events, 50.0)
    latency_p99 = Stats.latency_percentile(events, 99.0)
    err_count = Stats.error_count(events)
    error_rate_pct = Stats.error_rate(events) * 100

    # Row 2
    top_source =
      case Stats.top_source_providers(events, 1) do
        [{provider, count} | _] -> {provider, count}
        _ -> {:none, 0}
      end

    top_target =
      case Stats.top_target_providers(events, 1) do
        [{provider, count} | _] -> {provider, count}
        _ -> {:none, 0}
      end

    pipeline_p50 = Stats.avg_pipeline_ms(events)

    # Chart
    chart_data = Stats.hourly_counts(events, 24)

    # Errors
    recent_errors = Stats.recent_errors(events, 10)

    # Pipeline stats
    total = length(events)
    pii_events = Enum.count(events, &(&1.pii_detected_count > 0))
    pii_rate = if total == 0, do: 0.0, else: pii_events / total * 100
    cold_store_bytes = Queries.cold_store_size_bytes()
    cold_store_mb = cold_store_bytes / (1024 * 1024)
    audit_mode = Queries.audit_mode?()

    stat_cards_row1 = %{
      uptime: format_uptime(uptime_us),
      latency_p50: Components.format_latency(latency_p50),
      latency_p99: Components.format_latency(latency_p99),
      error_rate: "#{Float.round(error_rate_pct, 1)}%"
    }

    stat_cards_row2 = %{
      top_source: format_provider_with_count(top_source),
      top_target: format_provider_with_count(top_target),
      pipeline_p50: Components.format_latency(pipeline_p50)
    }

    pipeline_stats = %{
      pii_rate: "#{Float.round(pii_rate, 1)}%",
      cold_store_size: format_cold_store_size(cold_store_mb),
      audit_mode: audit_mode
    }

    socket
    |> assign(stat_cards_row1: stat_cards_row1)
    |> assign(stat_cards_row2: stat_cards_row2)
    |> assign(chart_data: chart_data)
    |> assign(chart_now_us: System.system_time(:microsecond))
    |> assign(recent_errors: recent_errors)
    |> assign(pipeline_stats: pipeline_stats)
    |> assign(error_count: err_count)
  end

  # ── Formatting helpers ────────────────────────────────────────────

  defp format_uptime(0), do: "0m"

  defp format_uptime(us) do
    total_seconds = div(us, 1_000_000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "#{div(total_seconds, 1_000_000)}s"
    end
  end

  defp format_provider_with_count({:none, _}), do: "—"

  defp format_provider_with_count({provider, count}) do
    name = Components.humanize_provider(provider)
    "#{name} (#{count})"
  end

  defp format_cold_store_size(mb) when mb < 1.0, do: "<1 MB"

  defp format_cold_store_size(mb) do
    "#{Float.round(mb, 0)} MB"
  end

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="system-view" class="p-6">
      <%!-- Row 1: 4 stat cards --%>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
        <Components.stats_card
          title="Uptime"
          value={@stat_cards_row1.uptime}
          icon="hero-clock"
          subtext="Session uptime; 30d tracking not yet built"
        />
        <Components.stats_card
          title="Latency p50"
          value={@stat_cards_row1.latency_p50}
          icon="hero-bolt"
          subtext={"p99: " <> @stat_cards_row1.latency_p99}
        />
        <Components.stats_card
          title="Latency p99"
          value={@stat_cards_row1.latency_p99}
          icon="hero-bolt"
          subtext="from last 1000 events"
        />
        <Components.stats_card
          title="Error rate"
          value={@stat_cards_row1.error_rate}
          icon="hero-exclamation-circle"
          subtext={"#{@error_count} errors in last 1000 events"}
        />
      </div>

      <%!-- Row 2: 3 stat cards --%>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
        <Components.stats_card
          title="Top Source Provider"
          value={@stat_cards_row2.top_source}
          icon="hero-server"
          subtext="of last 1000 events"
        />
        <Components.stats_card
          title="Top Target Provider"
          value={@stat_cards_row2.top_target}
          icon="hero-arrow-right-circle"
          subtext="of last 1000 events"
        />
        <Components.stats_card
          title="Pipeline p50 latency"
          value={@stat_cards_row2.pipeline_p50}
          icon="hero-cog-6-tooth"
          subtext="regex + NER + cross-validation"
        />
      </div>

      <%!-- 24h chart --%>
      <div class="bg-base-200 border border-base-300 rounded-lg p-6 mb-6">
        <h3 class="text-sm font-semibold mb-4">Request volume (24h)</h3>
        <Components.request_volume_chart data={@chart_data} now_us={@chart_now_us} />
        <p class="text-xs text-base-content/60 mt-2">Last 24 hours · Y axis: requests per hour</p>
      </div>

      <%!-- Recent errors --%>
      <div class="bg-base-200 border border-base-300 rounded-lg p-6 mb-6">
        <h3 class="text-sm font-semibold mb-4">Recent errors</h3>
        <%= if @recent_errors == [] do %>
          <p class="text-sm text-base-content/60">No errors in the last 24 hours</p>
        <% else %>
          <div class="recent-errors">
            <%= for err <- @recent_errors do %>
              <div class="recent-error-row">
                <span class="err-time">{Components.format_relative_time(err.ended_at)}</span>
                <span>
                  <span class={"provider-badge #{err.source_provider}"}>
                    {Components.humanize_provider(err.source_provider)}
                  </span>
                  →
                  <span class={"provider-badge #{err.target_provider}"}>
                    {Components.humanize_provider(err.target_provider)}
                  </span>
                </span>
                <span class="err-status">{err.status || "ERR"}</span>
                <span class="err-message">{error_reason(err.error)}</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Pipeline stats --%>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Components.stats_card
          title="PII detection rate"
          value={@pipeline_stats.pii_rate}
          icon="hero-shield-check"
          subtext="of last 1000 events with PII input"
        />
        <Components.stats_card
          title="Cold Store size"
          value={@pipeline_stats.cold_store_size}
          icon="hero-circle-stack"
          subtext="SQLite · encrypted at rest"
        />
        <Components.stats_card
          title="Audit Mode"
          value={if @pipeline_stats.audit_mode, do: "ON", else: "OFF"}
          icon="hero-eye"
          subtext={
            if @pipeline_stats.audit_mode, do: "Recording sanitized content", else: "No PII retained"
          }
        />
      </div>
    </div>
    """
  end

  defp error_reason(nil), do: "Error"

  defp error_reason(error) when is_map(error) do
    cond do
      Map.has_key?(error, :reason) -> error.reason
      Map.has_key?(error, "reason") -> error["reason"]
      Map.has_key?(error, :type) -> error.type
      Map.has_key?(error, "type") -> error["type"]
      true -> "Error"
    end
    |> to_string()
    |> String.slice(0, 30)
  end

  defp error_reason(error) do
    to_string(error)
    |> String.slice(0, 30)
  end
end
