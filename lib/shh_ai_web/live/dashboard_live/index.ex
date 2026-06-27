defmodule ShhAiWeb.DashboardLive.Index do
  use ShhAiWeb, :live_view

  alias ShhAi.Metrics
  alias ShhAiWeb.DashboardLive.Components

  @refresh_interval 5_000
  @default_limit 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ShhAi.PubSub, "dashboard:requests")
      schedule_refresh()
    end

    socket =
      socket
      |> assign_defaults()
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    socket =
      if socket.assigns.view == :conversations do
        send_update(ShhAiWeb.DashboardLive.Conversations, id: "conversations")
        socket
      else
        load_data(socket)
      end

    {:noreply, socket}
  end

  def handle_info({:request, event}, socket) do
    matches_view =
      case socket.assigns.view do
        :errors -> error?(event)
        :requests -> true
        :conversations -> false
      end

    socket =
      if matches_filters?(event, socket.assigns.filters) and matches_view do
        socket
        |> stream_insert(:requests, event, at: 0)
        |> update_stats_incremental(event)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = parse_filters(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("set-time-window", %{"window" => window}, socket) do
    time_window = String.to_existing_atom(window)

    socket =
      socket
      |> assign(:time_window, time_window)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("set-view", params, socket) do
    view =
      case params["view"] do
        "errors" -> :errors
        "conversations" -> :conversations
        _ -> :requests
      end

    socket =
      socket
      |> assign(:view, view)
      |> assign(:filters, %{
        socket.assigns.filters
        | status: if(view == :errors, do: "error", else: nil)
      })
      |> load_data()

    {:noreply, socket}
  end

  # Private functions

  defp assign_defaults(socket) do
    assign(socket,
      stats: empty_stats(),
      filters: %{provider: nil, status: nil, streaming: nil},
      time_window: :hour,
      view: :requests
    )
  end

  defp load_data(socket) do
    opts = build_opts(socket.assigns)

    requests =
      case socket.assigns.time_window do
        nil ->
          Metrics.list_recent(opts)

        window ->
          Metrics.list_since(window)
      end

    stats = Metrics.calculate_stats(Keyword.put(opts, :events, requests))

    socket
    |> assign(stats: stats)
    |> stream(:requests, requests, reset: true)
    |> push_chart_data(requests)
  end

  defp build_opts(assigns) do
    []
    |> maybe_add_filter(:provider, assigns.filters.provider)
    |> maybe_add_filter(:status_success, parse_status_filter(assigns.filters.status))
    |> maybe_add_filter(:streaming, assigns.filters.streaming)
    |> Keyword.put(:limit, @default_limit)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_status_filter("success"), do: true
  defp parse_status_filter("error"), do: false
  defp parse_status_filter(_), do: nil

  defp parse_filters(params) do
    %{
      provider: parse_provider(params["provider"]),
      status: params["status"],
      streaming: parse_streaming(params["streaming"])
    }
  end

  defp parse_provider(""), do: nil

  defp parse_provider(value) when value in ~w(openai anthropic ollama),
    do: String.to_existing_atom(value)

  defp parse_provider(_), do: nil

  defp parse_streaming("true"), do: true
  defp parse_streaming("false"), do: false
  defp parse_streaming(_), do: nil

  defp matches_filters?(event, filters) do
    matches_provider?(event, filters.provider) and
      matches_status?(event, filters.status) and
      matches_streaming?(event, filters.streaming)
  end

  defp matches_provider?(_event, nil), do: true
  defp matches_provider?(event, provider), do: event.target_provider == provider

  defp matches_status?(_event, nil), do: true
  defp matches_status?(event, "success"), do: event.status >= 200 and event.status < 300
  defp matches_status?(event, "error"), do: event.status < 200 or event.status >= 400

  defp matches_streaming?(_event, nil), do: true
  defp matches_streaming?(event, streaming), do: event.is_streaming == streaming

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp update_stats_incremental(socket, event) do
    update(socket, :stats, fn stats ->
      %{
        stats
        | requests_total: stats.requests_total + 1,
          requests_success: stats.requests_success + if(success?(event), do: 1, else: 0),
          requests_error: stats.requests_error + if(error?(event), do: 1, else: 0),
          client_errors: stats.client_errors + if(client_error?(event), do: 1, else: 0),
          server_errors: stats.server_errors + if(server_error?(event), do: 1, else: 0)
      }
    end)
  end

  defp success?(%{status: status}) when is_integer(status), do: status >= 200 and status < 300
  defp success?(_), do: false

  defp error?(%{status: status}) when is_integer(status), do: status < 200 or status >= 400
  defp error?(%{error: error}) when not is_nil(error), do: true
  defp error?(_), do: false

  defp client_error?(%{status: status}) when is_integer(status),
    do: status >= 400 and status < 500

  defp client_error?(_), do: false

  defp server_error?(%{status: status}) when is_integer(status), do: status >= 500
  defp server_error?(_), do: false

  defp push_chart_data(socket, requests) do
    chart_data = build_chart_data(requests, socket.assigns.stats)
    push_event(socket, "stats", chart_data)
  end

  defp build_chart_data(requests, stats) do
    %{
      request_volume: request_volume_data(requests),
      latency: latency_data(stats),
      provider: provider_data(stats),
      status: status_data(stats, requests),
      pii: pii_data(stats)
    }
  end

  defp request_volume_data(requests) do
    now = System.system_time(:microsecond)

    buckets =
      requests
      |> Enum.group_by(fn r -> div(now - r.ended_at, 300_000_000) end)
      |> Stream.map(fn {bucket, reqs} -> {bucket, length(reqs)} end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    labels = Enum.map(buckets, fn {i, _} -> format_bucket_label(i * 5) end)
    values = Enum.map(buckets, fn {_, count} -> count end)

    build_chart(:area, "Request Volume", labels, values)
  end

  defp format_bucket_label(minutes) when minutes < 60, do: "#{minutes}m"

  defp format_bucket_label(minutes) when minutes < 1440,
    do: "#{div(minutes, 60)}h#{rem(minutes, 60)}m"

  defp format_bucket_label(minutes) do
    days = div(minutes, 1440)
    remaining = rem(minutes, 1440)
    hours = div(remaining, 60)
    if hours > 0, do: "#{days}d#{hours}h", else: "#{days}d"
  end

  defp latency_data(stats) do
    labels = ["0-50ms", "50-100ms", "100-250ms", "250-500ms", "500ms+"]

    values =
      [
        stats.requests_total,
        round(stats.avg_latency_ms / 2),
        round(stats.p95_latency_ms / 2),
        round(stats.p99_latency_ms / 3),
        max(0, stats.requests_total - round(stats.avg_latency_ms))
      ]
      |> Enum.reject(&(&1 == 0))

    build_chart(:bar, "Latency Data", labels, values)
  end

  defp provider_data(stats) do
    target = stats.provider_usage[:target] || %{}

    labels = Map.keys(target)
    values = Map.values(target)

    build_chart(:pie, "Provider Data", labels, values)
  end

  defp status_data(_stats, requests) do
    success = Enum.count(requests, &(&1.status >= 200 and &1.status < 300))
    client_error = Enum.count(requests, &(&1.status >= 400 and &1.status < 500))
    server_error = Enum.count(requests, &(&1.status >= 500))

    labels = ["Success (2xx)", "Client Error (4xx)", "Server Error (5xx)"]
    values = [success, client_error, server_error] |> Enum.reject(&(&1 == 0))

    build_chart(:bar, "Status Codes", labels, values)
  end

  defp pii_data(stats) do
    pii_by_type = stats.pii_by_type || %{}

    labels = Map.keys(pii_by_type) |> Enum.map(&Atom.to_string/1)
    values = Map.values(pii_by_type)

    build_chart(:bar, "PII Types Detected", labels, values)
  end

  defp build_chart(:pie, _name, labels, values) do
    %{
      chart: %{
        type: :pie,
        height: "100%",
        maxWidth: "100%",
        fontFamily: "Inter, sans-serif",
        dropShadow: %{
          enabled: false
        },
        toolbar: %{
          show: false
        }
      },
      tooltip: %{
        enabled: false
      },
      fill: %{
        opacity: 1
      },
      dataLabels: %{
        enabled: true
      },
      series: values,
      legend: %{
        show: true,
        labels: %{
          useSeriesColors: true
        }
      },
      labels: labels
    }
  end

  defp build_chart(type, name, labels, values) do
    %{
      chart: %{
        type: type,
        height: "100%",
        maxWidth: "100%",
        fontFamily: "Inter, sans-serif",
        dropShadow: %{
          enabled: false
        },
        toolbar: %{
          show: false
        }
      },
      tooltip: %{
        enabled: false
      },
      fill: %{
        opacity: 1
      },
      dataLabels: %{
        enabled: false
      },
      grid: %{
        show: true,
        strokeDashArray: 4
      },
      series: [
        %{
          name: name,
          data: values
        }
      ],
      legend: %{
        show: false
      },
      stroke: %{
        curve: "smooth"
      },
      xaxis: %{
        categories: labels,
        labels: %{
          show: true,
          style: %{
            fontFamily: "Inter, sans-serif",
            cssClass: "text-xs font-normal fill-base-content"
          }
        },
        axisBorder: %{
          show: false
        },
        axisTicks: %{
          show: false
        }
      },
      yaxis: %{
        show: true,
        labels: %{
          show: true,
          style: %{
            fontFamily: "Inter, sans-serif",
            cssClass: "text-xs font-normal fill-base-content"
          }
        }
      }
    }
  end

  defp empty_stats do
    %{
      requests_total: 0,
      requests_success: 0,
      requests_error: 0,
      client_errors: 0,
      server_errors: 0,
      avg_latency_ms: 0.0,
      p95_latency_ms: 0.0,
      p99_latency_ms: 0.0,
      min_latency_ms: 0.0,
      max_latency_ms: 0.0,
      pii_total_detected: 0,
      pii_total_sanitized: 0,
      pii_total_preserved: 0,
      pii_by_type: %{},
      provider_usage: %{source: %{}, target: %{}},
      streaming_count: 0,
      error_rate: 0.0
    }
  end

  defp toggle_details(id) do
    JS.toggle(
      to: "#details-#{id}",
      display: "block",
      in: {"ease-out duration-300 transition-all", "opacity-0 scale-80", "opacity-100 scale-100"},
      out: {"east-out duration-300 transition-all", "opacity-100 scale-100", "opacity-0 scale-80"}
    )
    |> JS.toggle_class("rotate-180",
      to: "#chevron-#{id} span",
      transition: {"ease-out", "rotate-0", "rotate-180"}
    )
  end
end
