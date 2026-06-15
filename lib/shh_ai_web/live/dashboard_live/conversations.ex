defmodule ShhAiWeb.DashboardLive.Conversations do
  @moduledoc """
  LiveComponent for displaying conversation list with metadata.

  Shows active conversations with turn counts, PII detection totals,
  source provider, and expandable per-request details using shared
  Components.
  """

  use ShhAiWeb, :live_component

  alias ShhAi.ConversationStore
  alias ShhAi.Metrics.EventBuffer
  alias ShhAiWeb.DashboardLive.Components

  import Phoenix.LiveView.JS

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

    socket = assign(socket, :expanded_conversations, expanded)
    {:noreply, load_conversations(socket)}
  end

  defp load_conversations(socket) do
    conversations = ConversationStore.list_conversations(limit: 50)
    expanded = socket.assigns[:expanded_conversations] || []

    # Load events only for expanded conversations
    conversation_events =
      Map.new(expanded, fn conv_id ->
        events = EventBuffer.list_recent(conversation_id: conv_id, limit: 100)
        {conv_id, events}
      end)

    conversations_with_metadata =
      Enum.map(conversations, fn conv ->
        events = Map.get(conversation_events, conv.conversation_id, [])

        %{
          conversation: conv,
          turn_count: length(events),
          total_pii: Enum.sum(Enum.map(events, &(&1.pii_detected_count || 0))),
          duration_ms: (conv.last_active_at || 0) - (conv.created_at || 0),
          events: events
        }
      end)

    assign(socket,
      conversations: conversations_with_metadata,
      expanded_conversations: expanded
    )
  end

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
      <div class="card-body">
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
                <div class="font-mono text-xs truncate">{String.slice(conv_data.conversation.conversation_id, 0..11)}</div>
                <div class="text-sm">
                  {if conv_data.conversation.conversation_id in @expanded_conversations, do: conv_data.turn_count, else: "-"}
                </div>
                <div>
                  <span :if={conv_data.total_pii > 0} class="badge badge-sm badge-secondary">{conv_data.total_pii}</span>
                  <span :if={conv_data.total_pii <= 0} class="text-base-content/30">-</span>
                </div>
                <div class="text-sm">{format_duration(conv_data.duration_ms)}</div>
                <div>
                  <span class="badge badge-sm badge-primary">{Components.humanize_provider(conv_data.conversation.source_provider)}</span>
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
                        conv_data.conversation.conversation_id in @expanded_conversations && "rotate-180"
                      ]}
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
                    <span class="badge badge-sm badge-primary">{Components.humanize_provider(conv_data.conversation.source_provider)}</span>
                  </div>
                </div>

                <div class="flex items-center gap-2 flex-wrap text-sm text-base-content/50">
                  <span>
                    {if conv_data.conversation.conversation_id in @expanded_conversations, do: "#{conv_data.turn_count} turns", else: "- turns"}
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
                        conv_data.conversation.conversation_id in @expanded_conversations && "rotate-180"
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
    </div>
    """
  end
end
