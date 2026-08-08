defmodule ShhAiWeb.DashboardLive.IndexTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase
  import Phoenix.LiveViewTest

  alias ShhAi.Audit.Queries
  alias ShhAi.Config

  setup do
    setup_audit()

    # Default to audit-off mode for these tests
    snapshot_env(["AUDIT_MODE"])
    System.put_env("AUDIT_MODE", "false")
    Config.load()

    :ok
  end

  # ---------------------------------------------------------------------------
  # Admin layout
  # ---------------------------------------------------------------------------

  describe "admin layout" do
    test "renders nav links with correct routes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conversations")

      assert html =~ ~s(/admin/conversations)
      assert html =~ ~s(/admin/activity)
      assert html =~ ~s(/admin/system)

      assert html =~ ~s(Conversations)
      assert html =~ ~s(Activity)
      assert html =~ ~s(System)
    end

    test "conversations nav link has active class", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conversations")

      # Only the conversations link should carry the "active" class
      assert html =~ ~s(admin-nav-link active)
    end

    test "renders the logo and brand", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conversations")

      assert html =~ ~s(src="/images/logo.png")
      assert html =~ ~s(width="32")
      assert html =~ ~s(class="rounded")
      assert html =~ "ShhAi"
      assert html =~ "Admin"
    end

    test "renders the theme toggle buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conversations")

      assert html =~ ~s(data-phx-theme="light")
      assert html =~ ~s(data-phx-theme="dark")
    end

    test "shows audit mode OFF by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conversations")

      assert html =~ "Audit Mode:"
      assert html =~ "OFF"
    end

    test "shows audit mode ON when audit is enabled", %{conn: conn} do
      :meck.new(Queries, [:passthrough])
      :meck.expect(Queries, :audit_mode?, fn -> true end)
      :meck.expect(Queries, :list_conversations, fn _opts -> [] end)
      :meck.expect(Queries, :count_metadata_for_conversations, fn _ids -> %{} end)

      try do
        {:ok, _view, html} = live(conn, ~p"/admin/conversations")

        assert html =~ "Audit Mode:"
        assert html =~ "ON"
        assert html =~ "audit-dot"
        assert html =~ ~s(flex-shrink-0 on)
      after
        :meck.unload()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Navigation
  # ---------------------------------------------------------------------------

  describe "navigation" do
    test "clicking Activity link navigates to /admin/activity", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conversations")

      {:error, {:live_redirect, %{to: "/admin/activity"}}} =
        view |> element("a", "Activity") |> render_click()
    end

    test "clicking System link navigates to /admin/system", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conversations")

      {:error, {:live_redirect, %{to: "/admin/system"}}} =
        view |> element("a", "System") |> render_click()
    end
  end

  # ---------------------------------------------------------------------------
  # Route-specific content
  # ---------------------------------------------------------------------------

  describe "route-specific content" do
    test "/admin/conversations renders Conversations text", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conversations")

      assert html =~ "Conversations"
    end

    test "/admin/activity renders Requests today", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/activity")

      assert html =~ "Requests today"
    end

    test "/admin/system renders Uptime", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/system")

      assert html =~ "Uptime"
    end
  end
end
