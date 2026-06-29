defmodule ShhAiWeb.DashboardLive.Index do
  use ShhAiWeb, :live_view

  alias ShhAi.Audit.Queries

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:view, :conversations)
     |> assign(:audit_mode, Queries.audit_mode?())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    if socket.assigns.view == :conversations do
      send_update(ShhAiWeb.DashboardLive.Conversations, id: "conversations")
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set-view", %{"view" => raw_view}, socket) do
    {:noreply, assign(socket, :view, parse_view(raw_view))}
  end

  # Private functions

  defp parse_view("conversations"), do: :conversations
  defp parse_view("activity"), do: :activity
  defp parse_view("system"), do: :system
  defp parse_view(_), do: :conversations

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
