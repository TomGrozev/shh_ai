defmodule ShhAiWeb.AdminRedirectController do
  use ShhAiWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: ~p"/admin/conversations")
  end
end
