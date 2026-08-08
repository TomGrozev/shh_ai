defmodule ShhAiWeb.DashboardLive.Activity do
  @moduledoc """
  LiveView for displaying the live request activity stream.

  Shows a real-time table of requests from the ETS EventBuffer,
  with stat cards, filters, and row-click integration with the
  existing slide-over panel.
  """

  use ShhAiWeb, :live_view

  alias ShhAi.Metrics.{Event, EventBuffer, Stats}
  alias ShhAi.Audit.{EventRecord, Queries}
  alias ShhAiWeb.DashboardLive.Components
  alias ShhAiWeb.DashboardLive.Helpers

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ShhAi.PubSub, "dashboard:requests")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:audit_mode, ShhAi.Audit.Queries.audit_mode?())
     |> assign(:filters, %{source_provider: nil, target_provider: nil, status: "all"})
     |> assign(:time_window, :day)
     |> assign(
       :stat_counts,
       %{requests_today: 0, success_rate: 0.0, avg_latency: 0.0, errors: 0}
     )
     |> assign(:events, [])
     |> assign(:slideover, nil)
     |> assign(:active_stat_filter, nil)
     |> load()}
  end

  # ── PubSub / Refresh ────────────────────────────────────────────────

  @impl true
  def handle_info({:request, %Event{}}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load(socket)}
  end

  # ── Event handlers ──────────────────────────────────────────────────

  @impl true
  def handle_event("row-click", %{"id" => conv_id}, socket)
      when is_binary(conv_id) and conv_id != "" do
    {:noreply, assign(socket, :slideover, open_slideover(conv_id))}
  end

  def handle_event("row-click", _params, socket), do: {:noreply, socket}

  def handle_event("close-slideover", _params, socket) do
    {:noreply, assign(socket, :slideover, nil)}
  end

  def handle_event("set-time-window", %{"window" => window}, socket) do
    time_window =
      case window do
        "minute" -> :minute
        "hour" -> :hour
        "day" -> :day
        "week" -> :week
        _ -> :day
      end

    socket = assign(socket, time_window: time_window)
    {:noreply, load(socket)}
  end

  def handle_event("filter", params, socket) do
    filters = %{
      source_provider: Helpers.parse_provider(params["source_provider"]),
      target_provider: parse_target_provider(params["target_provider"]),
      status: params["status"] || "all"
    }

    {:noreply, socket |> assign(filters: filters) |> load()}
  end

  def handle_event("stat-card-click", %{"filter" => filter_name}, socket) do
    socket =
      case filter_name do
        "requests" ->
          socket
          |> assign(active_stat_filter: nil)
          |> assign(filters: %{source_provider: nil, target_provider: nil, status: "all"})

        "success" ->
          socket
          |> assign(active_stat_filter: "success")
          |> update(:filters, &%{&1 | status: "success"})

        "errors" ->
          socket
          |> assign(active_stat_filter: "errors")
          |> update(:filters, &%{&1 | status: "error"})

        "latency" ->
          # Latency filtering not yet implemented — make this a no-op but keep the card clickable for future enhancement
          socket

        _ ->
          socket
      end

    {:noreply, load(socket)}
  end

  # ── Data loading ────────────────────────────────────────────────────

  defp load(socket) do
    events =
      if socket.assigns.audit_mode do
        # Audit mode ON: load from DB
        since_naive = time_window_to_naive_since(socket.assigns.time_window)

        Queries.list_events(since: since_naive, limit: 500)
        |> Enum.map(&event_record_to_event/1)
      else
        # Audit mode OFF: try DB first (historical data), then ETS
        since_naive = time_window_to_naive_since(socket.assigns.time_window)
        db_events = Queries.list_events(since: since_naive, limit: 500)

        if db_events != [] do
          # DB has data, use it
          Enum.map(db_events, &event_record_to_event/1)
        else
          # DB is empty, fall back to ETS
          since_us = time_window_since(socket.assigns.time_window)
          opts = [limit: 500]

          opts =
            if socket.assigns.filters.source_provider,
              do: Keyword.put(opts, :provider, socket.assigns.filters.source_provider),
              else: opts

          EventBuffer.list_since(since_us, opts)
        end
      end
      |> apply_client_filters(socket.assigns.filters)

    total = length(events)
    error_count = Stats.error_count(events)
    success_rate = if total > 0, do: (total - error_count) / total * 100, else: 0.0

    stat_counts = %{
      requests_today: total,
      success_rate: success_rate,
      avg_latency: Stats.avg_latency_ms(events),
      errors: error_count
    }

    socket
    |> assign(events: events)
    |> assign(stat_counts: stat_counts)
  end

  defp apply_client_filters(events, %{target_provider: nil, status: "all"}), do: events

  defp apply_client_filters(events, filters) do
    Enum.filter(events, fn event ->
      matches_target?(event, filters.target_provider) and
        matches_status?(event, filters.status)
    end)
  end

  defp matches_target?(_event, nil), do: true
  defp matches_target?(event, target), do: event.target_provider == target

  defp matches_status?(_event, "all"), do: true

  defp matches_status?(event, "success") do
    is_nil(event.error) and is_integer(event.status) and event.status >= 200 and
      event.status < 400
  end

  defp matches_status?(event, "error") do
    not is_nil(event.error) or
      (is_integer(event.status) and (event.status < 200 or event.status >= 400))
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp open_slideover(conv_id) do
    if Queries.audit_mode?() do
      case Queries.get_conversation(conv_id) do
        nil ->
          open_slideover_stats(conv_id)

        conv ->
          messages = Queries.list_messages(conv.conversation_id)
          events = Queries.list_events(conversation_id: conv.conversation_id, limit: 100)
          mapping = Queries.decode_mapping(conv.mapping)

          %{
            id: conv.conversation_id,
            view: :chat,
            source_provider: Helpers.safe_to_existing_atom(conv.source_provider),
            target_provider: Helpers.target_from_events(events),
            last_active_at_us: Helpers.naive_to_us(conv.last_active_at),
            turn_count: length(messages),
            badge: nil,
            pii_types: aggregate_pii_types(events),
            messages: messages,
            events: events,
            mapping: mapping,
            expanded_event_id: nil,
            active_placeholder: nil,
            active_selection: nil,
            flagged_false_negatives: [],
            active_message_index: 0
          }
      end
    else
      open_slideover_stats(conv_id)
    end
  end

  defp open_slideover_stats(conv_id) do
    events = Queries.list_events(conversation_id: conv_id, limit: 100)

    %{
      id: conv_id,
      view: :stats,
      source_provider: source_from_events(events),
      target_provider: Helpers.target_from_events(events),
      last_active_at_us: if(events != [], do: Helpers.naive_to_us(hd(events).ended_at), else: 0),
      turn_count: length(events),
      badge: if(Queries.audit_mode?(), do: nil, else: :audit_off),
      pii_types: aggregate_pii_types(events),
      messages: [],
      events: events,
      mapping: %{},
      expanded_event_id: nil,
      active_placeholder: nil,
      active_selection: nil,
      flagged_false_negatives: [],
      active_message_index: 0
    }
  end

  defp source_from_events([]), do: nil

  defp source_from_events([first | _]) do
    case first.source_provider do
      nil -> nil
      s when is_binary(s) -> Helpers.safe_to_existing_atom(s)
      other -> other
    end
  end

  defp aggregate_pii_types(events) do
    events
    |> Enum.flat_map(fn e ->
      types =
        if is_binary(e.pii_types),
          do: decode_pii_types(e.pii_types),
          else: e.pii_types || []

      Enum.map(types, &{&1, 1})
    end)
    |> Enum.reduce(%{}, fn {type, count}, acc ->
      Map.update(acc, type, count, &(&1 + count))
    end)
  end

  defp decode_pii_types(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(fn s ->
          try do
            String.to_existing_atom(s)
          rescue
            ArgumentError -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp decode_pii_types(_), do: []

  defp time_window_to_naive_since(:minute), do: naive_subtract(60)
  defp time_window_to_naive_since(:hour), do: naive_subtract(3600)
  defp time_window_to_naive_since(:day), do: naive_subtract(86_400)
  defp time_window_to_naive_since(:week), do: naive_subtract(604_800)
  defp time_window_to_naive_since(_), do: naive_subtract(86_400)

  defp naive_subtract(seconds) do
    NaiveDateTime.utc_now() |> NaiveDateTime.add(-seconds, :second)
  end

  defp event_record_to_event(%EventRecord{} = record) do
    %Event{
      id: record.id,
      started_at: Helpers.naive_to_us(record.started_at),
      ended_at: Helpers.naive_to_us(record.ended_at),
      duration_ms: record.duration_ms,
      source_provider: Helpers.safe_to_existing_atom(record.source_provider),
      target_provider: record.target_provider,
      request_path: record.request_path,
      method: record.method,
      streaming: record.streaming,
      status: record.status,
      conversation_id: record.conversation_id,
      pii_detected_count: record.pii_detected_count,
      pii_sanitized_count: record.pii_sanitized_count,
      pii_preserved_count: record.pii_preserved_count,
      pii_types: decode_pii_types(record.pii_types),
      timings: decode_timings(record.timings),
      error: decode_error(record.error),
      inserted_at: Helpers.naive_to_us(record.inserted_at)
    }
  end

  defp decode_timings(nil), do: %{}

  defp decode_timings(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        Map.new(map, fn {k, v} ->
          key =
            try do
              String.to_existing_atom(k)
            rescue
              ArgumentError -> String.to_atom(k)
            end

          {key, v}
        end)

      _ ->
        %{}
    end
  end

  defp decode_timings(_), do: %{}

  defp decode_error(nil), do: nil

  defp decode_error(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp decode_error(other), do: other

  defp time_window_since(:minute), do: 60_000_000
  defp time_window_since(:hour), do: 3_600_000_000
  defp time_window_since(:day), do: 86_400_000_000
  defp time_window_since(:week), do: 604_800_000_000
  defp time_window_since(_), do: 86_400_000_000

  defp parse_target_provider(""), do: nil
  defp parse_target_provider(s) when is_binary(s), do: s
  defp parse_target_provider(_), do: nil
end
