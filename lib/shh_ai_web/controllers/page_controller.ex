defmodule ShhAiWeb.PageController do
  use ShhAiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
