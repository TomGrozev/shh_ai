defmodule ShhAiWeb.AdminAuth do
  @moduledoc """
  Gates the admin dashboard behind a single shared operator session.

  Doubles as a `Plug` (for the plain `/admin` redirect controller) and a
  LiveView `on_mount` hook (for the dashboard LiveViews), so both the initial
  HTTP request and the live socket are authenticated. The socket gate also
  re-checks that admin auth is *configured*, so a signed cookie left over from
  an earlier boot cannot reach dashboard data once `ADMIN_PASSWORD` is unset.

  Owns the admin session marker: `open_session/1` and `close_session/1` are the
  only writers, so login, logout, and the disconnect of already-connected live
  sockets stay in one place.
  """

  @behaviour Plug

  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn

  alias ShhAi.Config

  use ShhAiWeb, :verified_routes

  @session_key :admin_authenticated
  @live_socket_id_key :live_socket_id

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if admin_session?(conn) do
      conn
    else
      conn
      |> redirect(to: ~p"/admin/login")
      |> halt()
    end
  end

  @doc """
  LiveView `on_mount` hook: continues for an authenticated admin session on a
  configured deployment, otherwise halts with a redirect to the login page.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_admin, _params, %{"admin_authenticated" => true}, socket) do
    if Config.admin_configured?() do
      {:cont, socket}
    else
      halt_socket(socket)
    end
  end

  def on_mount(:ensure_admin, _params, _session, socket), do: halt_socket(socket)

  @doc """
  Opens the admin session and tags it with a `live_socket_id`, so any live
  socket it opens can be disconnected when the session ends.
  """
  @spec open_session(Plug.Conn.t()) :: Plug.Conn.t()
  def open_session(conn) do
    conn
    |> put_session(@session_key, true)
    |> put_session(@live_socket_id_key, live_socket_id())
  end

  @doc """
  Ends the admin session: disconnects every live socket opened by it, then
  drops the session cookie.
  """
  @spec close_session(Plug.Conn.t()) :: Plug.Conn.t()
  def close_session(conn) do
    disconnect_live_sockets(conn)
    configure_session(conn, drop: true)
  end

  @doc """
  Whether the conn carries a signed-in admin session.
  """
  @spec admin_session?(Plug.Conn.t()) :: boolean()
  def admin_session?(conn), do: get_session(conn, @session_key) == true

  defp halt_socket(socket) do
    {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/admin/login")}
  end

  defp disconnect_live_sockets(conn) do
    case get_session(conn, @live_socket_id_key) do
      nil -> :ok
      id -> ShhAiWeb.Endpoint.broadcast(id, "disconnect", %{})
    end
  end

  defp live_socket_id do
    "admin_sessions:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
