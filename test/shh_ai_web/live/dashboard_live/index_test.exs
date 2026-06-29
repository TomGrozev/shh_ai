defmodule ShhAiWeb.DashboardLive.IndexTest do
  use ShhAiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias ShhAi.Audit.Queries

  describe "mount" do
    test "renders three nav links with data-nav attributes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ ~s(data-nav="conversations")
      assert html =~ ~s(data-nav="activity")
      assert html =~ ~s(data-nav="system")
    end

    test "renders the logo and brand", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ ~s(src="/images/logo.png")
      assert html =~ ~s(width="32")
      assert html =~ ~s(class="rounded")
      assert html =~ "ShhAi"
      assert html =~ "Admin"
    end

    test "renders the theme toggle buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ ~s(data-phx-theme="light")
      assert html =~ ~s(data-phx-theme="dark")
    end

    test "default view is :conversations", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      assert view |> has_element?("#view-conversations.view-panel.active")
    end

    test "shows audit mode OFF by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "Audit Mode:"
      assert html =~ "OFF"
    end

    test "shows audit mode ON when audit is enabled", %{conn: conn} do
      :meck.new(Queries, [:passthrough])
      :meck.expect(Queries, :audit_mode?, fn -> true end)
      :meck.expect(Queries, :list_conversations, fn _opts -> [] end)
      :meck.expect(Queries, :count_metadata_for_conversations, fn _ids -> %{} end)

      try do
        {:ok, _view, html} = live(conn, ~p"/admin")
        assert html =~ "Audit Mode:"
        assert html =~ "ON"
        assert html =~ "audit-dot"
        assert html =~ ~s(flex-shrink-0 on)
      after
        :meck.unload()
      end
    end
  end

  describe "set-view event" do
    test "switches to :activity", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = render_click(view, "set-view", %{"view" => "activity"})
      assert html =~ ~s(id="view-activity")
      assert html =~ "Coming in a later slice"
    end

    test "switches to :system", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = render_click(view, "set-view", %{"view" => "system"})
      assert html =~ ~s(id="view-system")
      assert html =~ "Coming in a later slice"
    end

    test "switches back to :conversations", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      render_click(view, "set-view", %{"view" => "activity"})
      html = render_click(view, "set-view", %{"view" => "conversations"})
      assert html =~ ~s(id="view-conversations")
    end

    test "falls back to :conversations for unknown view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      render_click(view, "set-view", %{"view" => "unknown"})
      assert view |> has_element?("#view-conversations.view-panel.active")
    end
  end

  describe "view panels" do
    test "Conversations panel renders the LiveComponent", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "view-conversations"
    end

    test "Activity view shows the empty-state heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = render_click(view, "set-view", %{"view" => "activity"})
      assert html =~ "<h2>Activity</h2>"
    end

    test "System view shows the empty-state heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      html = render_click(view, "set-view", %{"view" => "system"})
      assert html =~ "<h2>System</h2>"
    end
  end

  describe "active panel visibility" do
    test "only the conversations panel has the active class by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      assert view |> has_element?("#view-conversations.view-panel.active")
      refute view |> has_element?("#view-activity.view-panel.active")
      refute view |> has_element?("#view-system.view-panel.active")
    end

    test "switching to activity moves the active class", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      render_click(view, "set-view", %{"view" => "activity"})
      refute view |> has_element?("#view-conversations.view-panel.active")
      assert view |> has_element?("#view-activity.view-panel.active")
      refute view |> has_element?("#view-system.view-panel.active")
    end
  end
end
