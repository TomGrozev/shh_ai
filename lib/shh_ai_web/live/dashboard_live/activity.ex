defmodule ShhAiWeb.DashboardLive.Activity do
  @moduledoc """
  LiveView for displaying the live request activity stream.

  Shows a real-time table of requests from the ETS EventBuffer,
  with stat cards, filters, and row-click integration with the
  existing slide-over panel.
  """

  use ShhAiWeb, :live_view

  alias ShhAi.Metrics
  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.Stats
  alias ShhAi.Audit.{ConversationRecord, Queries}
  alias ShhAiWeb.DashboardLive.Components
  alias ShhAiWeb.DashboardLive.Helpers
  alias ShhAi.Utils

  defmodule SlideoverState do
    @moduledoc false
    defstruct view: :chat,
              last_active_at_us: 0,
              turn_count: 0,
              badge: nil,
              pii_types: %{},
              messages: [],
              events: [],
              mapping: %{},
              expanded_event_id: nil,
              active_placeholder: nil,
              active_selection: nil,
              flagged_false_negatives: [],
              active_message_index: 0,
              id: nil,
              source_provider: nil,
              target_provider: nil
  end

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
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

  # ── Refresh ──────────────────────────────────────────────────────────

  @impl true
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
    opts = build_query_opts(socket.assigns.filters)

    events =
      socket.assigns.time_window
      |> Metrics.list_since(opts)
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
  defp matches_target?(event, target), do: Event.matches_target_provider?(event, target)

  defp matches_status?(_event, "all"), do: true

  defp matches_status?(event, "success") do
    Event.successful?(event)
  end

  defp matches_status?(event, "error") do
    not Event.successful?(event)
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
          mapping = ConversationRecord.decode_mapping(conv.mapping)

          %SlideoverState{
            id: conv.conversation_id,
            view: :chat,
            source_provider: Utils.safe_to_existing_atom(conv.source_provider),
            target_provider: Helpers.target_from_events(events),
            last_active_at_us: Utils.naive_to_us(conv.last_active_at),
            turn_count: length(messages),
            pii_types: aggregate_pii_types(events),
            messages: messages,
            events: events,
            mapping: mapping
          }
      end
    else
      open_slideover_stats(conv_id)
    end
  end

  defp open_slideover_stats(conv_id) do
    events = Queries.list_events(conversation_id: conv_id, limit: 100)

    %SlideoverState{
      id: conv_id,
      view: :stats,
      source_provider: source_from_events(events),
      target_provider: Helpers.target_from_events(events),
      last_active_at_us: if(events != [], do: Utils.naive_to_us(hd(events).ended_at), else: 0),
      turn_count: length(events),
      badge: if(Queries.audit_mode?(), do: nil, else: :audit_off),
      pii_types: aggregate_pii_types(events),
      events: events
    }
  end

  defp source_from_events([]), do: nil
  defp source_from_events([first | _]), do: first.source_provider

  defp aggregate_pii_types(events) do
    events
    |> Enum.flat_map(fn e ->
      # All events should have pii_types as [atom()] after EventRecord.to_event/1
      types = e.pii_types || []
      Enum.map(types, &{&1, 1})
    end)
    |> Enum.reduce(%{}, fn {type, count}, acc ->
      Map.update(acc, type, count, &(&1 + count))
    end)
  end

  defp build_query_opts(filters) do
    opts = [limit: 500]

    if filters.source_provider,
      do: Keyword.put(opts, :provider, filters.source_provider),
      else: opts
  end

  defp parse_target_provider(""), do: nil
  defp parse_target_provider(s) when is_binary(s), do: s
  defp parse_target_provider(_), do: nil
end
