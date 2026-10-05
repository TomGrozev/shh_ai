defmodule ShhAiWeb.AdminSessionController do
  @moduledoc """
  Hand-rolled login/logout for the admin dashboard.

  A single shared operator credential (`ADMIN_USER` / `ADMIN_PASSWORD`) is
  compared in constant time; a correct pair opens the admin session, and
  logout drops it. Chosen over `Plug.BasicAuth` for real logout and UX.
  """

  use ShhAiWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias ShhAi.Config
  alias ShhAiWeb.AdminAuth

  @doc """
  Renders the login form.
  """
  def new(conn, _params) do
    render(conn, :new, form: login_form())
  end

  @doc """
  Verifies the submitted credential and, on success, opens the admin session.
  """
  def create(conn, %{"admin" => %{"username" => username, "password" => password}})
      when is_binary(username) and is_binary(password) do
    if valid_credentials?(username, password) do
      conn
      |> AdminAuth.open_session()
      |> put_flash(:info, "Signed in.")
      |> redirect(to: ~p"/admin/conversations")
    else
      reject_login(conn, username)
    end
  end

  def create(conn, _params) do
    reject_login(conn, nil)
  end

  @doc """
  Clears the admin session and returns to the login page.
  """
  def delete(conn, _params) do
    conn
    |> AdminAuth.close_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/admin/login")
  end

  defp login_form(username \\ ""),
    do: to_form(%{"username" => username || ""}, as: :admin)

  defp reject_login(conn, username) do
    conn
    |> put_flash(:error, "Invalid username or password.")
    |> render(:new, form: login_form(username))
  end

  defp valid_credentials?(username, password) do
    admin_ok = Config.admin_configured?()

    # Both comparisons run regardless, keeping the check constant-time.
    user_ok = Plug.Crypto.secure_compare(username, Config.admin_user())
    password_ok = Plug.Crypto.secure_compare(password, Config.admin_password() || "")

    admin_ok and user_ok and password_ok
  end
end
