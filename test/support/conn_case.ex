defmodule ShhAiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Since this is a stateless proxy, we don't need database setup.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ShhAiWeb.Endpoint

      use ShhAiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ShhAiWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Configures the admin dashboard credential in the environment and reloads
  config, so admin-auth tests start from a configured dashboard.

  Pair with `ShhAi.AuditCase.snapshot_env/1` to restore the environment.
  """
  @spec configure_admin(String.t(), keyword()) :: :ok
  def configure_admin(password \\ "test-admin-password", opts \\ []) do
    System.put_env("ADMIN_USER", Keyword.get(opts, :user, "operator"))
    System.put_env("ADMIN_PASSWORD", password)
    ShhAi.Config.load()
  end

  @doc """
  Returns the conn carrying an authenticated admin session.
  """
  @spec log_in_admin(Plug.Conn.t()) :: Plug.Conn.t()
  def log_in_admin(conn),
    do: Phoenix.ConnTest.init_test_session(conn, %{admin_authenticated: true})
end
