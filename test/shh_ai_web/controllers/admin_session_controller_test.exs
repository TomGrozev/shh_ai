defmodule ShhAiWeb.AdminSessionControllerTest do
  use ShhAiWeb.ConnCase, async: false
  use ShhAi.AuditCase

  alias ShhAi.Config

  setup do
    snapshot_env(["ADMIN_USER", "ADMIN_PASSWORD"])
    configure_admin("s3cret")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Login page
  # ---------------------------------------------------------------------------

  describe "GET /admin/login" do
    test "renders the login form", %{conn: conn} do
      html = get(conn, ~p"/admin/login") |> html_response(200)

      assert html =~ "Sign in"
      assert html =~ "Username"
      assert html =~ "Password"
    end
  end

  # ---------------------------------------------------------------------------
  # Sign in
  # ---------------------------------------------------------------------------

  describe "POST /admin/login" do
    test "opens an admin session for the correct credentials", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", admin: %{username: "operator", password: "s3cret"})

      assert redirected_to(conn) == ~p"/admin/conversations"
      assert get_session(conn, :admin_authenticated) == true
      assert is_binary(get_session(conn, :live_socket_id))
    end

    test "rejects non-binary credentials without crashing", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", admin: %{username: "operator", password: ["x"]})

      assert html_response(conn, 200) =~ "Invalid username or password"
      refute get_session(conn, :admin_authenticated)
    end

    test "rejects a wrong password", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", admin: %{username: "operator", password: "wrong"})

      assert html_response(conn, 200) =~ "Invalid username or password"
      refute get_session(conn, :admin_authenticated)
    end

    test "rejects a wrong username", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", admin: %{username: "nobody", password: "s3cret"})

      assert html_response(conn, 200) =~ "Invalid username or password"
      refute get_session(conn, :admin_authenticated)
    end

    test "rejects a malformed submission", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", %{})

      assert html_response(conn, 200) =~ "Invalid username or password"
      refute get_session(conn, :admin_authenticated)
    end
  end

  # ---------------------------------------------------------------------------
  # Sign out
  # ---------------------------------------------------------------------------

  describe "DELETE /admin/logout" do
    test "ends the session so the dashboard is unreachable again", %{conn: conn} do
      logged_in =
        conn
        |> post(~p"/admin/login", admin: %{username: "operator", password: "s3cret"})
        |> recycle()

      conn = delete(logged_in, ~p"/admin/logout")
      assert redirected_to(conn) == ~p"/admin/login"

      assert redirected_to(get(recycle(conn), ~p"/admin/conversations")) == ~p"/admin/login"
    end

    test "disconnects the live sockets opened by the session", %{conn: conn} do
      logged_in = post(conn, ~p"/admin/login", admin: %{username: "operator", password: "s3cret"})
      socket_id = get_session(logged_in, :live_socket_id)

      ShhAiWeb.Endpoint.subscribe(socket_id)
      delete(recycle(logged_in), ~p"/admin/logout")

      assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}
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

    test "refuses to serve the login page (403)", %{conn: conn} do
      assert get(conn, ~p"/admin/login").status == 403
    end

    test "refuses a login attempt (403)", %{conn: conn} do
      conn = post(conn, ~p"/admin/login", admin: %{username: "operator", password: "s3cret"})
      assert conn.status == 403
    end
  end
end
