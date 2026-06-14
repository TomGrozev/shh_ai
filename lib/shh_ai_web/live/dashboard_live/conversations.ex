defmodule ShhAiWeb.DashboardLive.Conversations do
  @moduledoc """
  LiveComponent for displaying conversation list with metadata.

  Shows active conversations with turn counts, PII detection totals,
  identification method, and expandable per-request details.
  """

  use ShhAiWeb, :live_component

  alias ShhAi.ConversationStore
  alias ShhAi.Metrics.EventBuffer

  @impl true
  def mount(socket) do
    {:ok, assign(socket, expanded_conversations: [], conversations: [])}
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

    {:noreply, assign(socket, :expanded_conversations, expanded)}
  end

  defp load_conversations(socket) do
    conversations = ConversationStore.list_conversations(limit: 50)

    # Fetch all recent events once and group by conversation_id
    # to avoid N+1 GenServer calls (one per conversation).
    all_events = EventBuffer.list_recent(limit: 1000)
    events_by_conversation = Enum.group_by(all_events, & &1.conversation_id)

    conversations_with_metadata =
      Enum.map(conversations, fn conv ->
        events = Map.get(events_by_conversation, conv.conversation_id, [])

        %{
          conversation: conv,
          turn_count: length(events),
          total_pii: Enum.sum(Enum.map(events, & &1.pii_detected_count)),
          duration_ms: conv.last_active_at - conv.created_at,
          identification_method:
            if(conv.fingerprint_hash, do: "Fingerprinted", else: "Stateful"),
          source_provider: conv.source_provider,
          events: events
        }
      end)

    assign(socket,
      conversations: conversations_with_metadata,
      expanded_conversations: socket.assigns[:expanded_conversations] || []
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Conversations</h2>

        <div class="hidden md:grid md:grid-cols-[1fr_0.5fr_0.5fr_1fr_1fr_1fr_0.5fr] gap-2 px-4 pb-2 text-xs font-semibold text-base-content/60 uppercase tracking-wide">
          <span>Conversation</span>
          <span>Turns</span>
          <span>PII</span>
          <span>Duration</span>
          <span>Method</span>
          <span>Provider</span>
          <span></span>
        </div>

        <div class="divide-y divide-base-300">
          <div
            :for={conv_data <- @conversations}
            class="cursor-pointer hover:bg-base-300 rounded-lg"
            phx-click="toggle-conversation"
            phx-value-id={conv_data.conversation.conversation_id}
            phx-target={@myself}
          >
            <%!-- Desktop grid row --%>
            <div class="hidden md:grid md:grid-cols-[1fr_0.5fr_0.5fr_1fr_1fr_1fr_0.5fr] gap-2 p-4 items-center">
              <div class="font-mono text-xs truncate">{String.slice(conv_data.conversation.conversation_id, 0..11)}</div>
              <div class="text-sm">{conv_data.turn_count}</div>
              <div>
                <span :if={conv_data.total_pii > 0} class="badge badge-sm badge-secondary">{conv_data.total_pii}</span>
                <span :if={conv_data.total_pii <= 0} class="text-base-content/30">-</span>
              </div>
              <div class="text-sm">{format_duration(conv_data.duration_ms)}</div>
              <div>
                <span class={["badge badge-sm", if(conv_data.identification_method == "Fingerprinted", do: "badge-primary", else: "badge-ghost")]}>
                  {conv_data.identification_method}
                </span>
              </div>
              <div>
                <span class="badge badge-sm badge-primary">{conv_data.source_provider}</span>
              </div>
              <div>
                <button
                  id={"conv-chevron-#{conv_data.conversation.conversation_id}"}
                  class="btn btn-ghost btn-sm btn-circle"
                >
                  <.icon
                    name="hero-chevron-down"
                    class="w-4 h-4 transition-transform duration-200"
                  />
                </button>
              </div>
            </div>

            <%!-- Mobile stacked layout --%>
            <div class="md:hidden flex flex-col gap-3 p-4">
              <div>
                <div class="flex items-center gap-2 mb-1">
                  <span class="font-mono text-xs">{String.slice(conv_data.conversation.conversation_id, 0..11)}</span>
                </div>
                <div class="flex items-center gap-2">
                  <span class={["badge badge-sm", if(conv_data.identification_method == "Fingerprinted", do: "badge-primary", else: "badge-ghost")]}>
                    {conv_data.identification_method}
                  </span>
                  <span class="badge badge-sm badge-primary">{conv_data.source_provider}</span>
                </div>
              </div>

              <div class="flex items-center gap-2 flex-wrap text-sm text-base-content/50">
                <span>{conv_data.turn_count} turns</span>
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
                    class="w-4 h-4 transition-transform duration-200"
                  />
                </button>
              </div>
            </div>

            <%!-- Expanded details --%>
            <div :if={conv_data.conversation.conversation_id in @expanded_conversations} class="p-4">
              <div class="border-t border-base-300 pt-3 space-y-2">
                <h3 class="font-semibold mb-2">Requests</h3>
                <div :for={event <- conv_data.events} class="bg-base-100 p-3 rounded-lg">
                  <div class="flex justify-between items-center text-sm">
                    <span class="font-mono text-xs">{event.id}</span>
                    <span class="text-sm">{Float.round(event.duration_ms, 1)}ms</span>
                    <span :if={event.pii_detected_count > 0} class="badge badge-sm badge-secondary">
                      PII: {event.pii_detected_count}
                    </span>
                    <span :if={event.pii_detected_count <= 0} class="text-base-content/30">-</span>
                    <span class={["badge badge-sm", if(event.status && event.status >= 400, do: "badge-error", else: "badge-success")]}>
                      {event.status || "N/A"}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_duration(duration_ms) when duration_ms < 1000, do: "#{duration_ms}ms"

  defp format_duration(duration_ms) when duration_ms < 60_000 do
    "#{Float.round(duration_ms / 1000, 1)}s"
  end

  defp format_duration(duration_ms) do
    minutes = div(duration_ms, 60_000)
    "#{minutes}m"
  end
end
