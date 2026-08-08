defmodule ShhAiWeb.DashboardLive.Activity do
  @moduledoc """
  LiveComponent for displaying the live request activity stream.

  Shows a real-time table of requests from the ETS EventBuffer,
  with stat cards, filters, and row-click integration with the
  existing slide-over panel.
  """

  use ShhAiWeb, :live_component

  alias ShhAi.Metrics.{Event, EventBuffer, Stats}
  alias ShhAi.Audit.Queries
  alias ShhAiWeb.DashboardLive.Components

  @impl true
  def mount(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ShhAi.PubSub, "dashboard:requests")
    end

    socket =
      socket
      |> assign(:filters, %{source_provider: nil, target_provider: nil, status: "all"})
      |> assign(:time_window, :day)
      |> assign(
        :stat_counts,
        %{requests_today: 0, success_rate: 0.0, avg_latency: 0.0, errors: 0}
      )
      |> assign(:events, [])
      |> assign(:slideover, nil)

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)
    {:ok, load(socket)}
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  def handle_info({:request, %Event{}}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

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
      source_provider: parse_source_provider(params["source_provider"]),
      target_provider: parse_target_provider(params["target_provider"]),
      status: params["status"] || "all"
    }

    {:noreply, socket |> assign(filters: filters) |> load()}
  end

  def handle_event("stat-card-click", _params, socket), do: {:noreply, socket}

  # ── Data loading ────────────────────────────────────────────────────

  defp load(socket) do
    since_us = time_window_since(socket.assigns.time_window)

    opts = [limit: 500]

    opts =
      if socket.assigns.filters.source_provider,
        do: Keyword.put(opts, :provider, socket.assigns.filters.source_provider),
        else: opts

    events =
      since_us
      |> EventBuffer.list_since(opts)
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
    is_integer(event.status) and event.status >= 200 and event.status < 300
  end

  defp matches_status?(event, "error") do
    not is_nil(event.error) or
      (is_integer(event.status) and (event.status < 200 or event.status >= 400))
  end

  # ── Slideover ───────────────────────────────────────────────────────

  defp open_slideover(conv_id) do
    if Queries.audit_mode?() do
      case Queries.get_conversation(conv_id) do
        nil ->
          open_slideover_stats(conv_id)

        conv ->
          messages = Queries.list_messages(conv.id)
          events = Queries.list_events(conversation_id: conv.id, limit: 100)
          mapping = Queries.decode_mapping(conv.mapping)

          %{
            id: conv.id,
            view: :chat,
            source_provider: safe_to_atom(conv.source_provider),
            target_provider: target_from_events(events),
            last_active_at_us: naive_to_us(conv.last_active_at),
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
      target_provider: target_from_events(events),
      last_active_at_us: if(events != [], do: naive_to_us(hd(events).ended_at), else: 0),
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

  # ── Private helpers ─────────────────────────────────────────────────

  defp target_from_events([]), do: nil

  defp target_from_events([first | _]) do
    case first.target_provider do
      nil -> nil
      s when is_binary(s) -> safe_to_atom(s)
      other -> other
    end
  end

  defp source_from_events([]), do: nil

  defp source_from_events([first | _]) do
    case first.source_provider do
      nil -> nil
      s when is_binary(s) -> safe_to_atom(s)
      other -> other
    end
  end

  defp safe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom(other), do: other

  defp naive_to_us(nil), do: 0

  defp naive_to_us(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
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

  defp time_window_since(:minute), do: 60_000_000
  defp time_window_since(:hour), do: 3_600_000_000
  defp time_window_since(:day), do: 86_400_000_000
  defp time_window_since(:week), do: 604_800_000_000
  defp time_window_since(_), do: 86_400_000_000

  defp parse_source_provider(""), do: nil
  defp parse_source_provider("openai"), do: :openai
  defp parse_source_provider("anthropic"), do: :anthropic
  defp parse_source_provider("ollama"), do: :ollama
  defp parse_source_provider(_), do: nil

  defp parse_target_provider(""), do: nil
  defp parse_target_provider(s) when is_binary(s), do: s
  defp parse_target_provider(_), do: nil

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="text-sm text-base-content/60">Activity</div>

      <%!-- Stat cards --%>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Components.stat_card_clickable
          title="Requests today"
          value={@stat_counts.requests_today}
          icon="hero-server-stack"
          active={false}
          filter="requests"
          phx_target={@myself}
        />
        <Components.stat_card_clickable
          title="Success rate"
          value={"#{Float.round(@stat_counts.success_rate, 1)}%"}
          icon="hero-check-circle"
          active={false}
          filter="success"
          phx_target={@myself}
        />
        <Components.stat_card_clickable
          title="Avg latency"
          value={Components.format_latency(@stat_counts.avg_latency)}
          icon="hero-clock"
          active={false}
          filter="latency"
          phx_target={@myself}
        />
        <Components.stat_card_clickable
          title="Errors"
          value={@stat_counts.errors}
          icon="hero-exclamation-triangle"
          active={false}
          filter="errors"
          phx_target={@myself}
        />
      </div>

      <%!-- Filter bar --%>
      <div class="flex flex-wrap items-end gap-3">
        <.form
          phx-change="filter"
          phx-target={@myself}
          for={%{}}
          class="flex flex-wrap items-end gap-3"
        >
          <label class="fieldset">
            <span class="fieldset-label text-xs font-medium opacity-60">
              <.icon name="hero-server-stack-mini" class="h-3.5 w-3.5" /> Source
            </span>
            <select name="source_provider" class="select select-sm">
              <option value="" selected={is_nil(@filters.source_provider)}>All</option>
              <option value="openai" selected={@filters.source_provider == :openai}>OpenAI</option>
              <option
                value="anthropic"
                selected={@filters.source_provider == :anthropic}
              >
                Anthropic
              </option>
              <option value="ollama" selected={@filters.source_provider == :ollama}>Ollama</option>
            </select>
          </label>

          <label class="fieldset">
            <span class="fieldset-label text-xs font-medium opacity-60">
              <.icon name="hero-arrow-right-mini" class="h-3.5 w-3.5" /> Target
            </span>
            <select name="target_provider" class="select select-sm">
              <option value="" selected={is_nil(@filters.target_provider)}>All</option>
              <option
                value="openai"
                selected={@filters.target_provider == "openai"}
              >
                OpenAI
              </option>
              <option
                value="anthropic"
                selected={@filters.target_provider == "anthropic"}
              >
                Anthropic
              </option>
              <option value="ollama" selected={@filters.target_provider == "ollama"}>
                Ollama
              </option>
            </select>
          </label>

          <label class="fieldset">
            <span class="fieldset-label text-xs font-medium opacity-60">
              <.icon name="hero-signal-mini" class="h-3.5 w-3.5" /> Status
            </span>
            <select name="status" class="select select-sm">
              <option value="all" selected={@filters.status == "all"}>All</option>
              <option value="success" selected={@filters.status == "success"}>Success</option>
              <option value="error" selected={@filters.status == "error"}>Error</option>
            </select>
          </label>
        </.form>

        <div class="flex items-center gap-1">
          <span class="text-xs font-medium opacity-60 mr-1">
            <.icon name="hero-clock-mini" class="h-3.5 w-3.5" /> Window
          </span>
          <input
            class="join-item btn btn-sm"
            type="radio"
            name="time-window"
            aria-label="1m"
            checked={@time_window == :minute}
            phx-click="set-time-window"
            phx-target={@myself}
            phx-value-window="minute"
          />
          <input
            class="join-item btn btn-sm"
            type="radio"
            name="time-window"
            aria-label="1h"
            checked={@time_window == :hour}
            phx-click="set-time-window"
            phx-target={@myself}
            phx-value-window="hour"
          />
          <input
            class="join-item btn btn-sm"
            type="radio"
            name="time-window"
            aria-label="24h"
            checked={@time_window == :day}
            phx-click="set-time-window"
            phx-target={@myself}
            phx-value-window="day"
          />
          <input
            class="join-item btn btn-sm"
            type="radio"
            name="time-window"
            aria-label="7d"
            checked={@time_window == :week}
            phx-click="set-time-window"
            phx-target={@myself}
            phx-value-window="week"
          />
        </div>
      </div>

      <%!-- Event table --%>
      <div class="overflow-x-auto">
        <table class="activity-table">
          <thead>
            <tr>
              <th>Time</th>
              <th>Source</th>
              <th>Target</th>
              <th>Path</th>
              <th>Status</th>
              <th>Latency</th>
              <th>PII</th>
              <th>Conv ID</th>
            </tr>
          </thead>
          <tbody>
            <%= if @events == [] do %>
              <tr>
                <td colspan="8" class="text-center py-8 text-base-content/40">
                  No requests in this time window
                </td>
              </tr>
            <% end %>
            <%= for event <- @events do %>
              <tr
                class={["activity-table-row", event.conversation_id && "clickable"]}
                phx-click={event.conversation_id && "row-click"}
                phx-value-id={event.conversation_id}
                phx-target={event.conversation_id && @myself}
              >
                <td>
                  <span class="tooltip" data-tip={Components.format_absolute_time(event.ended_at)}>
                    {Components.format_relative_time(event.ended_at)}
                  </span>
                </td>
                <td>
                  <span class={"provider-badge #{event.source_provider}"}>
                    {Components.humanize_provider(event.source_provider)}
                  </span>
                </td>
                <td>
                  <span class={"provider-badge #{event.target_provider}"}>
                    {Components.humanize_provider(event.target_provider)}
                  </span>
                </td>
                <td class="truncate">{event.request_path}</td>
                <td>
                  <%= if event.error do %>
                    <span class="badge badge-sm badge-error">ERR</span>
                  <% else %>
                    <span class={["badge badge-sm", Components.status_class(event.status)]}>
                      {event.status || "—"}
                    </span>
                  <% end %>
                </td>
                <td>{Components.format_latency(event.duration_ms)}</td>
                <td>
                  <%= if event.pii_detected_count > 0 do %>
                    <span class="badge badge-sm badge-secondary">
                      {event.pii_detected_count}
                    </span>
                  <% else %>
                    <span class="text-base-content/30">—</span>
                  <% end %>
                </td>
                <td>
                  {Components.format_conversation_id(event.conversation_id)}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <Components.slideover slideover={@slideover} phx_target={@myself} />
    </div>
    """
  end
end
