defmodule ShhAiWeb.DashboardLive.Conversations do
  @moduledoc """
  LiveComponent for displaying conversation queue with card-based layout.

  Shows active conversations with message previews, PII detection,
  source provider, and opt-out status using card-based UI components.
  """

  use ShhAiWeb, :live_component

  alias ShhAi.Audit.Queries
  alias ShhAiWeb.DashboardLive.Components

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       filters: %{provider: nil, has_pii: nil, opted_out: nil},
       time_window: :day,
       active_stat_filter: nil,
       stat_counts: %{},
       cards: [],
       audit_off: false,
       slideover: nil,
       expanded_event_id: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = process_forwarded_event(assigns, socket)
    {:ok, load_conversations(socket)}
  end

  defp process_forwarded_event(assigns, socket) do
    forwarded_event = assigns[:forwarded_event]
    forwarded_ts = assigns[:forwarded_event_ts]
    last_ts = socket.assigns[:last_forwarded_ts]

    if forwarded_event && forwarded_ts != last_ts do
      {event, params} = forwarded_event

      socket
      |> assign(last_forwarded_ts: forwarded_ts)
      |> handle_forwarded_event(event, params)
    else
      socket
    end
  end

  defp handle_forwarded_event(socket, "open-selection-popover", %{"text" => text}) do
    case socket.assigns.slideover do
      nil ->
        socket

      slideover ->
        active = %{"text" => text}
        assign(socket, slideover: %{slideover | active_selection: active})
    end
  end

  defp handle_forwarded_event(socket, "confirm-false-negative", %{"text" => text}) do
    case socket.assigns.slideover do
      nil ->
        socket

      slideover ->
        flagged = slideover.flagged_false_negatives || []

        updated_flagged =
          if text in flagged, do: flagged, else: flagged ++ [text]

        new_slideover = %{
          slideover
          | flagged_false_negatives: updated_flagged,
            active_selection: nil
        }

        assign(socket, slideover: new_slideover)
    end
  end

  defp handle_forwarded_event(socket, "dismiss-selection-popover", _params) do
    case socket.assigns.slideover do
      nil ->
        socket

      slideover ->
        assign(socket, slideover: %{slideover | active_selection: nil})
    end
  end

  defp handle_forwarded_event(socket, "navigate-message", %{"direction" => direction}) do
    case socket.assigns.slideover do
      nil ->
        socket

      slideover ->
        messages = slideover.messages || []
        current = slideover[:active_message_index] || 0
        max_idx = max(length(messages) - 1, 0)

        new_index =
          case direction do
            "next" -> min(current + 1, max_idx)
            "prev" -> max(current - 1, 0)
            _ -> current
          end

        assign(socket, slideover: %{slideover | active_message_index: new_index})
    end
  end

  defp handle_forwarded_event(socket, _event, _params), do: socket

  # ── Event handlers ────────────────────────────────────────────────────

  @impl true
  def handle_event("card-click", %{"id" => conv_id}, socket) do
    {:noreply, assign(socket, slideover: load_slideover(socket, conv_id), expanded_event_id: nil)}
  end

  def handle_event("open-placeholder-popover", %{"placeholder" => placeholder} = params, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        active = %{
          "placeholder" => placeholder,
          "original" => Map.get(params, "original", ""),
          "pii_type" => Map.get(params, "pii-type", "")
        }

        {:noreply, assign(socket, slideover: %{slideover | active_placeholder: active})}
    end
  end

  def handle_event("close-placeholder-popover", _params, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        {:noreply, assign(socket, slideover: %{slideover | active_placeholder: nil})}
    end
  end

  def handle_event("open-selection-popover", %{"text" => text}, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        active = %{"text" => text}
        {:noreply, assign(socket, slideover: %{slideover | active_selection: active})}
    end
  end

  def handle_event("confirm-false-negative", %{"text" => text}, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        flagged = slideover.flagged_false_negatives || []

        updated_flagged =
          if text in flagged, do: flagged, else: flagged ++ [text]

        new_slideover = %{
          slideover
          | flagged_false_negatives: updated_flagged,
            active_selection: nil
        }

        {:noreply, assign(socket, slideover: new_slideover)}
    end
  end

  def handle_event("dismiss-selection-popover", _params, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        {:noreply, assign(socket, slideover: %{slideover | active_selection: nil})}
    end
  end

  def handle_event("navigate-message", %{"direction" => direction}, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        messages = slideover.messages || []
        current = slideover[:active_message_index] || 0
        max_idx = max(length(messages) - 1, 0)

        new_index =
          case direction do
            "next" -> min(current + 1, max_idx)
            "prev" -> max(current - 1, 0)
            _ -> current
          end

        {:noreply, assign(socket, slideover: %{slideover | active_message_index: new_index})}
    end
  end

  def handle_event("close-slideover", _, socket) do
    {:noreply, assign(socket, slideover: nil, expanded_event_id: nil)}
  end

  def handle_event("expand-row", %{"event-id" => event_id}, socket) do
    case socket.assigns.slideover do
      nil ->
        {:noreply, socket}

      slideover ->
        expanded_id = if slideover.expanded_event_id == event_id, do: nil, else: event_id

        {:noreply,
         assign(socket,
           slideover: %{slideover | expanded_event_id: expanded_id}
         )}
    end
  end

  def handle_event("view-activity", _, socket) do
    {:noreply, assign(socket, slideover: nil, expanded_event_id: nil)}
  end

  def handle_event("stat-card-click", %{"filter" => filter_name}, socket) do
    socket =
      case filter_name do
        "conversations" ->
          socket
          |> assign(active_stat_filter: nil)
          |> assign(filters: %{provider: nil, has_pii: nil, opted_out: nil})

        "pii" ->
          socket
          |> assign(active_stat_filter: "pii")
          |> update(:filters, &%{&1 | has_pii: true})

        "optouts" ->
          socket
          |> assign(active_stat_filter: "optouts")
          |> update(:filters, &%{&1 | opted_out: true})

        "optout-not-honored" ->
          socket
          |> assign(active_stat_filter: "optout-not-honored")
          |> update(:filters, &%{&1 | opted_out: true})

        _ ->
          socket
      end

    {:noreply, load_conversations(socket)}
  end

  def handle_event("filter", params, socket) do
    filters = %{
      provider: parse_provider(params["provider"]),
      has_pii: parse_bool(params["has_pii"]),
      opted_out: parse_bool(params["opted_out"])
    }

    socket =
      socket
      |> assign(filters: filters)
      |> assign(active_stat_filter: nil)

    {:noreply, load_conversations(socket)}
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
    {:noreply, load_conversations(socket)}
  end

  # ── Data loading ──────────────────────────────────────────────────────

  defp load_conversations(socket) do
    if Queries.audit_mode?() do
      load_conversations_audit_on(socket)
    else
      load_conversations_audit_off(socket)
    end
  end

  defp load_conversations_audit_on(socket) do
    filters = socket.assigns.filters
    since = time_window_since(socket.assigns.time_window)

    records =
      Queries.list_conversations(
        limit: 50,
        source_provider: filters.provider,
        opted_out: filters.opted_out,
        has_pii: filters.has_pii,
        since: since
      )

    conv_ids = Enum.map(records, & &1.conversation_id)

    previews = Queries.first_user_message_for_conversations(conv_ids)
    pii_types = Queries.pii_type_counts_for_conversations(conv_ids)
    metadata = Queries.count_metadata_for_conversations(conv_ids)

    cards =
      Enum.map(records, fn record ->
        conv_id = record.conversation_id
        meta = Map.get(metadata, conv_id, %{event_count: 0, total_pii: 0})
        provider = record.source_provider && safe_to_existing_atom(record.source_provider)
        last_active_us = naive_to_us(record.last_active_at)

        # Tombstone detection: opted out AND mapping cleared (Cloak decrypts to nil)
        tombstoned? = record.opted_out == true and is_nil(record.mapping)

        if tombstoned? do
          type_counts = Map.get(pii_types, conv_id, %{})
          pii_type_list = Map.keys(type_counts)

          %{
            type: :tombstoned,
            id: conv_id,
            source_provider: provider,
            request_count: meta.event_count,
            pii_type_count: length(pii_type_list),
            pii_types: pii_type_list,
            pii_type_counts: type_counts,
            total_pii: meta.total_pii,
            last_active_at_us: last_active_us,
            opted_out: Map.get(record, :opted_out, false)
          }
        else
          preview = Map.get(previews, conv_id) || "No message preview available"

          %{
            type: :normal,
            id: conv_id,
            preview: preview,
            source_provider: provider,
            total_pii: meta.total_pii,
            turn_count: meta.event_count,
            last_active_at_us: last_active_us,
            pii_type_counts: Map.get(pii_types, conv_id, %{}),
            opted_out: Map.get(record, :opted_out, false)
          }
        end
      end)

    stat_counts = %{
      conversations_today: Queries.count_conversations_today(),
      pii_detected: Queries.count_pii_detected_today(),
      optouts_handled: Queries.count_opt_outs_handled(),
      optouts_not_honored: Queries.count_opt_outs_not_honored()
    }

    socket
    |> assign(
      cards: cards,
      stat_counts: stat_counts,
      audit_off: false
    )
  end

  defp load_conversations_audit_off(socket) do
    filters = socket.assigns.filters
    since = time_window_since(socket.assigns.time_window)

    records =
      Queries.list_conversations(
        limit: 50,
        source_provider: filters.provider,
        since: since
      )

    conv_ids = Enum.map(records, & &1.conversation_id)

    event_stats = Queries.event_stats_for_conversations(conv_ids)
    pii_types = Queries.pii_type_counts_for_conversations(conv_ids)

    cards =
      Enum.map(records, fn record ->
        conv_id = record.conversation_id
        stats = Map.get(event_stats, conv_id, %{event_count: 0, total_pii: 0, avg_latency: 0.0})
        provider = record.source_provider && safe_to_existing_atom(record.source_provider)
        last_active_us = naive_to_us(record.last_active_at)
        type_counts = Map.get(pii_types, conv_id, %{})
        pii_type_list = Map.keys(type_counts)

        %{
          type: :audit_off,
          id: conv_id,
          source_provider: provider,
          request_count: stats.event_count,
          pii_types: pii_type_list,
          pii_type_counts: type_counts,
          total_pii: stats.total_pii,
          last_active_at_us: last_active_us,
          opted_out: Map.get(record, :opted_out, false)
        }
      end)

    stat_counts = %{
      conversations_today: Queries.count_conversations_today(),
      pii_detected: Queries.count_pii_detected_today(),
      total_requests: Queries.count_total_requests_today(),
      avg_latency: Queries.avg_latency_today()
    }

    socket
    |> assign(
      cards: cards,
      stat_counts: stat_counts,
      audit_off: true
    )
  end

  # ── Private helpers ───────────────────────────────────────────────────

  defp load_slideover(socket, conv_id) do
    card = Enum.find(socket.assigns.cards, &(&1.id == conv_id))

    case card do
      nil -> nil
      %{type: :normal} -> load_slideover_chat(socket, card)
      %{type: :tombstoned} -> load_slideover_stats(socket, card, :opted_out)
      %{type: :audit_off} -> load_slideover_stats(socket, card, :audit_off)
    end
  end

  defp load_slideover_chat(_socket, card) do
    conv = Queries.get_conversation(card.id)
    messages = Queries.list_messages(card.id)
    # Only need 1 event to get the target_provider
    events = Queries.list_events(conversation_id: card.id, limit: 1)

    mapping =
      case conv do
        nil -> %{}
        %{} -> Queries.decode_mapping(conv.mapping)
      end

    %{
      id: card.id,
      view: :chat,
      source_provider: card.source_provider,
      target_provider: target_from_events(events),
      last_active_at_us: card.last_active_at_us,
      turn_count: card.turn_count,
      badge: nil,
      pii_types: card_pii_type_counts(card),
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

  defp load_slideover_stats(_socket, card, badge) do
    events = Queries.list_events(conversation_id: card.id, limit: 100)

    %{
      id: card.id,
      view: :stats,
      source_provider: card.source_provider,
      target_provider: target_from_events(events),
      last_active_at_us: card.last_active_at_us,
      turn_count: card.request_count,
      badge: badge,
      pii_types: card_pii_type_counts(card),
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

  defp target_from_events([]), do: nil
  defp target_from_events([first | _]), do: parse_target(first.target_provider)

  defp parse_target(nil), do: nil

  defp parse_target(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_target(other), do: other

  defp card_pii_type_counts(card) do
    # Prefer the precomputed count map; fall back to list-based count (1 each)
    # for backwards compatibility with shapes that only carry a list.
    card[:pii_type_counts] || Map.new(card[:pii_types] || [], fn type -> {type, 1} end)
  end

  defp parse_provider(""), do: nil
  defp parse_provider("openai"), do: "openai"
  defp parse_provider("anthropic"), do: "anthropic"
  defp parse_provider("ollama"), do: "ollama"
  defp parse_provider(_), do: nil

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp time_window_since(:minute), do: NaiveDateTime.utc_now() |> NaiveDateTime.add(-60, :second)
  defp time_window_since(:hour), do: NaiveDateTime.utc_now() |> NaiveDateTime.add(-3600, :second)

  defp time_window_since(:week),
    do: NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 86_400, :second)

  defp time_window_since(_),
    do:
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.beginning_of_day()

  defp safe_to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp naive_to_us(nil), do: 0

  defp naive_to_us(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div :if={@audit_off} class="text-sm text-base-content/60">
        Conversations (Audit Mode OFF — stats only)
      </div>
      <div :if={not @audit_off} class="text-sm text-base-content/60">
        Conversations
      </div>

      <%!-- Stat cards --%>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Components.stat_card_clickable
          title="Conversations today"
          value={@stat_counts[:conversations_today] || 0}
          icon="hero-chat-bubble-left"
          active={@active_stat_filter == "conversations"}
          filter="conversations"
          phx_target={@myself}
        />

        <Components.stat_card_clickable
          title="PII detected"
          value={@stat_counts[:pii_detected] || 0}
          icon="hero-shield-check"
          active={@active_stat_filter == "pii"}
          filter="pii"
          value_class="text-primary"
          phx_target={@myself}
        />

        <%= if @audit_off do %>
          <Components.stat_card_clickable
            title="Total requests"
            value={@stat_counts[:total_requests] || 0}
            icon="hero-server-stack"
            active={@active_stat_filter == "total-requests"}
            filter="total-requests"
            phx_target={@myself}
          />
          <Components.stat_card_clickable
            title="Avg latency"
            value={Components.format_latency(@stat_counts[:avg_latency] || 0.0)}
            icon="hero-clock"
            active={@active_stat_filter == "avg-latency"}
            filter="avg-latency"
            phx_target={@myself}
          />
        <% else %>
          <Components.stat_card_clickable
            title="Opt-outs handled"
            value={@stat_counts[:optouts_handled] || 0}
            icon="hero-no-symbol"
            active={@active_stat_filter == "optouts"}
            filter="optouts"
            phx_target={@myself}
          />
          <Components.stat_card_clickable
            title="Opt-outs not honored"
            value={@stat_counts[:optouts_not_honored] || 0}
            icon="hero-check-circle"
            active={@active_stat_filter == "optout-not-honored"}
            filter="optout-not-honored"
            phx_target={@myself}
          />
        <% end %>
      </div>

      <%!-- Filter bar --%>
      <Components.filter_bar
        filters={
          %{provider: @filters.provider, has_pii: @filters.has_pii, opted_out: @filters.opted_out}
        }
        time_window={@time_window}
        on_filter="filter"
        on_time_window="set-time-window"
        phx_target={@myself}
      />

      <%!-- Card list --%>
      <div class="flex flex-col gap-2">
        <%= for card <- @cards do %>
          <Components.conversation_card
            :if={card.type == :normal}
            id={card.id}
            preview={card.preview}
            source_provider={card.source_provider}
            total_pii={card.total_pii}
            turn_count={card.turn_count}
            last_active_at_us={card.last_active_at_us}
            phx_target={@myself}
          />
          <Components.conversation_card_tombstoned
            :if={card.type == :tombstoned}
            id={card.id}
            source_provider={card.source_provider}
            request_count={card.request_count}
            pii_type_count={card.pii_type_count}
            pii_types={card.pii_types}
            total_pii={card.total_pii}
            last_active_at_us={card.last_active_at_us}
            phx_target={@myself}
          />
          <Components.conversation_card_audit_off
            :if={card.type == :audit_off}
            id={card.id}
            source_provider={card.source_provider}
            request_count={card.request_count}
            pii_types={card.pii_types}
            total_pii={card.total_pii}
            last_active_at_us={card.last_active_at_us}
            phx_target={@myself}
          />
        <% end %>
      </div>

      <Components.slideover slideover={@slideover} phx_target={@myself} />
    </div>
    """
  end
end
