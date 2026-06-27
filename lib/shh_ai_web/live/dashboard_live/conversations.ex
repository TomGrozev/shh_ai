defmodule ShhAiWeb.DashboardLive.Conversations do
  @moduledoc """
  LiveComponent for displaying conversation list with metadata.

  Shows active conversations with turn counts, PII detection totals,
  source provider, and expandable per-request details using shared
  Components.
  """

  use ShhAiWeb, :live_component

  alias ShhAi.Audit.Queries
  alias ShhAiWeb.DashboardLive.Components

  import Phoenix.LiveView.JS

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded_conversations: [],
       conversations: [],
       audit_off: false
     )}
  end

  @impl true
  def update(_params, socket) do
    {:ok, load_conversations(socket)}
  end

  @impl true
  def handle_event("toggle-conversation", %{"id" => conv_id}, socket) do
    expanded = socket.assigns.expanded_conversations

    expanded =
      if conv_id in expanded do
        List.delete(expanded, conv_id)
      else
        [conv_id | expanded]
      end

    socket = assign(socket, :expanded_conversations, expanded)
    {:noreply, load_conversations(socket)}
  end

  defp load_conversations(socket) do
    if Queries.audit_mode?() do
      load_conversations_audit_on(socket)
    else
      assign(socket, audit_off: true, conversations: [])
    end
  end

  defp load_conversations_audit_on(socket) do
    expanded = socket.assigns[:expanded_conversations] || []

    records = Queries.list_conversations(limit: 50)

    # Load events only for expanded conversations
    events_by_conv =
      Map.new(expanded, fn conv_id ->
        {conv_id, Queries.list_events(conversation_id: conv_id, limit: 100)}
      end)

    conversations_with_metadata =
      Enum.map(records, fn %ShhAi.Audit.ConversationRecord{} = record ->
        events =
          events_by_conv
          |> Map.get(record.conversation_id, [])
          |> Enum.map(&event_record_to_event/1)

        %{
          conversation: conversation_record_to_conversation(record),
          turn_count: length(events),
          total_pii: Enum.sum(Enum.map(events, &(&1.pii_detected_count || 0))),
          duration_ms: naive_diff_ms(record.last_active_at, record.created_at),
          events: events
        }
      end)

    assign(socket,
      conversations: conversations_with_metadata,
      expanded_conversations: expanded,
      audit_off: false
    )
  end

  # Build a display struct compatible with `Components.humanize_provider/1`
  # and the existing template (expects `%ShhAi.Conversation{}`-shaped data with
  # `source_provider` as an atom).
  defp conversation_record_to_conversation(%ShhAi.Audit.ConversationRecord{} = r) do
    %ShhAi.Conversation{
      conversation_id: r.conversation_id,
      source_provider: r.source_provider && safe_to_existing_atom(r.source_provider),
      provider_conversation_id: r.provider_conversation_id,
      fingerprint_hash: r.fingerprint_hash,
      opted_out: r.opted_out,
      mapping: %{},
      reverse_index: %{},
      created_at: naive_to_ms(r.created_at),
      last_active_at: naive_to_ms(r.last_active_at),
      new?: false
    }
  end

  # Build a display struct compatible with `Components.request_row/1` and
  # `Components.request_row_detail/1` (expects `%ShhAi.Metrics.Event{}`).
  defp event_record_to_event(%ShhAi.Audit.EventRecord{} = r) do
    %ShhAi.Metrics.Event{
      id: r.id,
      started_at: naive_to_us(r.started_at),
      ended_at: naive_to_us(r.ended_at),
      duration_ms: r.duration_ms || 0.0,
      source_provider: r.source_provider && safe_to_existing_atom(r.source_provider),
      target_provider: r.target_provider,
      request_path: r.request_path,
      method: r.method,
      streaming: r.streaming || false,
      status: r.status,
      conversation_id: r.conversation_id,
      pii_detected_count: r.pii_detected_count || 0,
      pii_sanitized_count: r.pii_sanitized_count || 0,
      pii_preserved_count: r.pii_preserved_count || 0,
      pii_types: decode_pii_types(r.pii_types),
      timings: decode_timings(r.timings),
      error: decode_error(r.error),
      inserted_at: naive_to_us(r.inserted_at)
    }
  end

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

  defp naive_to_ms(nil), do: 0

  defp naive_to_ms(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp naive_diff_ms(%NaiveDateTime{} = a, %NaiveDateTime{} = b) do
    naive_to_ms(a) - naive_to_ms(b)
  end

  defp naive_diff_ms(_, _), do: 0

  defp decode_pii_types(nil), do: []

  defp decode_pii_types(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Enum.map(fn s -> safe_to_existing_atom(s) end)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_timings(nil), do: %{}

  defp decode_timings(json) when is_binary(json) do
    Jason.decode!(json)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp decode_error(nil), do: nil
  defp decode_error(json) when is_binary(json), do: Jason.decode!(json)

  defp toggle_request_detail(id) do
    toggle(
      to: "#details-#{id}",
      display: "block",
      in: {"ease-out duration-300 transition-all", "opacity-0 scale-80", "opacity-100 scale-100"},
      out: {"ease-out duration-300 transition-all", "opacity-100 scale-100", "opacity-0 scale-80"}
    )
    |> toggle_class("rotate-180",
      to: "#chevron-#{id} span",
      transition: {"ease-out", "rotate-0", "rotate-180"}
    )
  end

  defp format_duration(duration_ms) when duration_ms < 1000, do: "#{duration_ms}ms"

  defp format_duration(duration_ms) when duration_ms < 60_000 do
    "#{Float.round(duration_ms / 1000, 1)}s"
  end

  defp format_duration(duration_ms) do
    minutes = div(duration_ms, 60_000)
    "#{minutes}m"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div :if={not @audit_off} class="card-body">
        <h2 class="card-title">Conversations</h2>

        <%!-- Header row --%>
        <div class="hidden md:grid md:grid-cols-[1fr_0.5fr_0.5fr_1fr_1fr_0.5fr] gap-2 px-4 pb-2 text-xs font-semibold text-base-content/60 uppercase tracking-wide">
          <span>Conversation</span>
          <span>Turns</span>
          <span>PII</span>
          <span>Duration</span>
          <span>Provider</span>
          <span></span>
        </div>

        <div class="divide-y divide-base-300">
          <div :for={conv_data <- @conversations}>
            <%!-- Conversation header row (clickable to expand) --%>
            <div
              class="cursor-pointer hover:bg-base-300 rounded-lg"
              phx-click="toggle-conversation"
              phx-value-id={conv_data.conversation.conversation_id}
              phx-target={@myself}
            >
              <%!-- Desktop grid --%>
              <div class="hidden md:grid md:grid-cols-[1fr_0.5fr_0.5fr_1fr_1fr_0.5fr] gap-2 p-4 items-center">
                <div class="font-mono text-xs truncate">
                  {String.slice(conv_data.conversation.conversation_id, 0..11)}
                </div>
                <div class="text-sm">
                  {if conv_data.conversation.conversation_id in @expanded_conversations,
                    do: conv_data.turn_count,
                    else: "-"}
                </div>
                <div>
                  <span :if={conv_data.total_pii > 0} class="badge badge-sm badge-secondary">
                    {conv_data.total_pii}
                  </span>
                  <span :if={conv_data.total_pii <= 0} class="text-base-content/30">-</span>
                </div>
                <div class="text-sm">{format_duration(conv_data.duration_ms)}</div>
                <div>
                  <span class="badge badge-sm badge-primary">
                    {Components.humanize_provider(conv_data.conversation.source_provider)}
                  </span>
                </div>
                <div>
                  <button
                    id={"conv-chevron-#{conv_data.conversation.conversation_id}"}
                    class="btn btn-ghost btn-sm btn-circle"
                  >
                    <.icon
                      name="hero-chevron-down"
                      class={[
                        "w-4 h-4 transition-transform duration-200",
                        conv_data.conversation.conversation_id in @expanded_conversations &&
                          "rotate-180"
                      ]}
                    />
                  </button>
                </div>
              </div>

              <%!-- Mobile stacked layout --%>
              <div class="md:hidden flex flex-col gap-3 p-4">
                <div>
                  <div class="flex items-center gap-2 mb-1">
                    <span class="font-mono text-xs">
                      {String.slice(conv_data.conversation.conversation_id, 0..11)}
                    </span>
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="badge badge-sm badge-primary">
                      {Components.humanize_provider(conv_data.conversation.source_provider)}
                    </span>
                  </div>
                </div>

                <div class="flex items-center gap-2 flex-wrap text-sm text-base-content/50">
                  <span>
                    {if conv_data.conversation.conversation_id in @expanded_conversations,
                      do: "#{conv_data.turn_count} turns",
                      else: "- turns"}
                  </span>
                  <span>·</span>
                  <span>{format_duration(conv_data.duration_ms)}</span>
                  <span :if={conv_data.total_pii > 0}>·</span>
                  <span :if={conv_data.total_pii > 0} class="badge badge-sm badge-secondary">
                    {conv_data.total_pii}
                  </span>
                  <button
                    id={"conv-chevron-mobile-#{conv_data.conversation.conversation_id}"}
                    class="btn btn-ghost btn-sm btn-circle ml-auto !gap-0"
                  >
                    <.icon
                      name="hero-chevron-down"
                      class={[
                        "w-4 h-4 transition-transform duration-200",
                        conv_data.conversation.conversation_id in @expanded_conversations &&
                          "rotate-180"
                      ]}
                    />
                  </button>
                </div>
              </div>
            </div>

            <%!-- Expanded request rows (only when expanded) --%>
            <div :if={conv_data.conversation.conversation_id in @expanded_conversations} class="p-4">
              <div class="border-t border-base-300 pt-3 space-y-2">
                <h3 class="font-semibold mb-2">Requests</h3>
                <div :for={{event, idx} <- Enum.with_index(conv_data.events)}>
                  <% event_id = "conv-#{conv_data.conversation.conversation_id}-#{idx}" %>
                  <Components.request_row
                    request={event}
                    id={event_id}
                    toggle_action={toggle_request_detail(event_id)}
                    show_conversation_link={false}
                    show_field_labels={true}
                  />
                  <Components.request_row_detail request={event} id={"details-#{event_id}"} />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@audit_off} class="card-body">
        <h2 class="card-title">Conversations</h2>
        <p class="text-base-content/60">
          Audit Mode is OFF. No audit data available.
        </p>
      </div>
    </div>
    """
  end
end
