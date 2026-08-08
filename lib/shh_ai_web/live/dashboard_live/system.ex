defmodule ShhAiWeb.DashboardLive.System do
  @moduledoc """
  LiveView for displaying system-level stats, request volume chart,
  recent errors, and pipeline stats for the admin dashboard.
  """

  use ShhAiWeb, :live_view

  alias ShhAi.Audit.Queries
  alias ShhAi.Metrics.{EventBuffer, Stats}
  alias ShhAiWeb.DashboardLive.Components

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:audit_mode, ShhAi.Audit.Queries.audit_mode?())
     |> assign(:stat_cards_row1, %{
       uptime: "—",
       latency_p50: "—",
       latency_p99: "—",
       requests_1h: 0,
       error_rate: "—"
     })
     |> assign(:provider_breakdown, %{source: [], target: [], total: 0})
     |> assign(:chart_data, [])
     |> assign(:chart_now_us, System.system_time(:microsecond))
     |> assign(:recent_errors, [])
     |> assign(:pipeline_stats, %{pipeline_p50: "—", pii_rate: "—", cold_store_size: "—"})
     |> assign(:error_count, 0)
     |> load()}
  end

  # ── Refresh ──────────────────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load(socket)}
  end

  # ── Data loading ──────────────────────────────────────────────────

  defp load(socket) do
    events = EventBuffer.list_recent(limit: 1000)

    # Row 1
    uptime_us = Stats.app_uptime_us()
    latency_p50 = Stats.latency_percentile(events, 50.0)
    latency_p99 = Stats.latency_percentile(events, 99.0)
    err_count = Stats.error_count(events)
    error_rate_pct = Stats.error_rate(events) * 100

    # Requests (1h)
    one_hour_ago_us = System.system_time(:microsecond) - 3_600_000_000
    requests_1h = Enum.count(events, &(&1.ended_at >= one_hour_ago_us))

    # Provider breakdown
    source_providers = Stats.top_source_providers(events, 5)
    target_providers = Stats.top_target_providers(events, 5)
    total = length(events)

    # Pipeline stats
    pipeline_p50 = Stats.avg_pipeline_ms(events)
    pii_events = Enum.count(events, &(&1.pii_detected_count > 0))
    # TODO: rename to "recall" to match mockup, but current impl is detection rate, not recall
    pii_rate = if total == 0, do: 0.0, else: pii_events / total * 100
    cold_store_bytes = Queries.cold_store_size_bytes()
    cold_store_mb = cold_store_bytes / (1024 * 1024)

    # Chart
    chart_data = Stats.hourly_counts(events, 24)

    # Errors
    recent_errors = Stats.recent_errors(events, 10)

    stat_cards_row1 = %{
      uptime: format_uptime(uptime_us),
      latency_p50: Components.format_latency(latency_p50),
      latency_p99: Components.format_latency(latency_p99),
      requests_1h: requests_1h,
      error_rate: "#{Float.round(error_rate_pct, 1)}%"
    }

    pipeline_stats = %{
      pipeline_p50: Components.format_latency(pipeline_p50),
      pii_rate: "#{Float.round(pii_rate, 1)}%",
      cold_store_size: format_cold_store_size(cold_store_mb)
    }

    socket
    |> assign(stat_cards_row1: stat_cards_row1)
    |> assign(:provider_breakdown, %{
      source: format_provider_breakdown(source_providers, total),
      target: format_provider_breakdown(target_providers, total),
      total: total
    })
    |> assign(chart_data: chart_data)
    |> assign(chart_now_us: System.system_time(:microsecond))
    |> assign(recent_errors: recent_errors)
    |> assign(pipeline_stats: pipeline_stats)
    |> assign(error_count: err_count)
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
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

  defp format_provider_breakdown(providers, total) do
    providers
    |> Enum.map(fn {provider, count} ->
      pct = if total > 0, do: round(count / total * 100), else: 0
      {provider, count, pct}
    end)
  end

  defp format_cold_store_size(mb) when mb < 1.0, do: "<1 MB"

  defp format_cold_store_size(mb) do
    "#{Float.round(mb, 0)} MB"
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
