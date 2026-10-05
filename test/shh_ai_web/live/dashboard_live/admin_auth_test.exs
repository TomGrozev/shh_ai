defmodule ShhAiWeb.DashboardLive.AdminAuthTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase
  import Phoenix.LiveViewTest

  alias ShhAi.Config

  @endpoint ShhAiWeb.Endpoint

  setup do
    snapshot_env(["ADMIN_USER", "ADMIN_PASSWORD", "AUDIT_MODE"])
    System.put_env("AUDIT_MODE", "false")
    configure_admin("s3cret")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Unauthenticated
  # ---------------------------------------------------------------------------

  describe "unauthenticated" do
    test "redirects a dashboard page to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/conversations")
    end

    test "redirects the admin root to the login page", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/admin")) == ~p"/admin/login"
    end
  end

  # ---------------------------------------------------------------------------
  # Socket gate
  # ---------------------------------------------------------------------------

  describe "on_mount/4" do
    test "halts the socket without a session" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, halted} = ShhAiWeb.AdminAuth.on_mount(:ensure_admin, %{}, %{}, socket)
      assert {:redirect, %{to: "/admin/login"}} = halted.redirected
    end

    test "continues the socket with an authenticated session" do
      socket = %Phoenix.LiveView.Socket{}

      session = %{"admin_authenticated" => true}

      assert {:cont, %Phoenix.LiveView.Socket{}} =
               ShhAiWeb.AdminAuth.on_mount(:ensure_admin, %{}, session, socket)
    end
  end

  # ---------------------------------------------------------------------------
  # Authenticated
  # ---------------------------------------------------------------------------

  describe "authenticated" do
    test "mounts the dashboard", %{conn: conn} do
      conn = log_in_admin(conn)

      assert {:ok, view, _html} = live(conn, ~p"/admin/conversations")
      assert has_element?(view, ".admin-nav")
    end
  end

  # ---------------------------------------------------------------------------
  # Unconfigured
  # ---------------------------------------------------------------------------

  describe "when ADMIN_PASSWORD is unset" do
    setup do
      System.delete_env("ADMIN_PASSWORD")
      Config.load()
      :ok
    end

    test "refuses to serve a dashboard page (403)", %{conn: conn} do
      assert get(conn, ~p"/admin/conversations").status == 403
    end

    test "halts the socket even for a previously signed session" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"admin_authenticated" => true}

      assert {:halt, halted} = ShhAiWeb.AdminAuth.on_mount(:ensure_admin, %{}, session, socket)
      assert {:redirect, %{to: "/admin/login"}} = halted.redirected
    end
  end
end
