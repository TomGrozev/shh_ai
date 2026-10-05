defmodule ShhAiWeb.Router do
  use ShhAiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ShhAiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :put_resp_content_type, "application/json"
  end

  # Every `/admin` route: refuse to serve (403) when admin auth is unconfigured,
  # so the dashboard is never world-readable.
  pipeline :admin do
    plug :require_admin_configured
  end

  # Admin pages that require a signed-in operator: redirect to the login page
  # otherwise. The LiveViews additionally check the socket via `on_mount`.
  pipeline :admin_authenticated do
    plug ShhAiWeb.AdminAuth
  end

  # Pipeline for proxy requests - accepts both JSON and streaming
  pipeline :proxy do
    plug :accepts, ["json", "text/event-stream"]
    plug :put_resp_content_type, "application/json"
  end

  scope "/", ShhAiWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Admin login/logout: reachable without a session, but refused (403) when
  # admin auth is unconfigured.
  scope "/admin", ShhAiWeb do
    pipe_through [:browser, :admin]

    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create
    delete "/logout", AdminSessionController, :delete
  end

  # Admin dashboard: an authenticated operator only. The `on_mount` gate also
  # covers the live socket, so there is no unauthenticated back door.
  scope "/admin", ShhAiWeb do
    pipe_through [:browser, :admin, :admin_authenticated]

    live_session :admin, on_mount: {ShhAiWeb.AdminAuth, :ensure_admin} do
      live "/conversations", DashboardLive.Conversations, :index
      live "/activity", DashboardLive.Activity, :index
      live "/system", DashboardLive.System, :index
    end

    get "/", AdminRedirectController, :index
  end

  # OpenAI-compatible API proxy endpoints
  scope "/v1", ShhAiWeb do
    pipe_through :proxy

    # Chat completions
    post "/chat/completions", ProxyController, :handle_openai
    # Completions (legacy)
    post "/completions", ProxyController, :handle_openai
    # Embeddings
    post "/embeddings", ProxyController, :handle_openai
    # Models listing
    get "/models", ProxyController, :handle_openai
    # Anthropic messages API endpoint
    post "/messages", ProxyController, :handle_anthropic
    # Catch-all for other OpenAI endpoints
    forward "/", ProxyController, :handle_openai
  end

  # Ollama API proxy endpoints
  scope "/api", ShhAiWeb do
    pipe_through :proxy

    post "/chat", ProxyController, :handle_ollama
    post "/generate", ProxyController, :handle_ollama
    post "/embeddings", ProxyController, :handle_ollama
    get "/tags", ProxyController, :handle_ollama
    forward "/", ProxyController, :handle_ollama
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:shh_ai, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ShhAiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Refuses every `/admin` route (403) until an operator sets ADMIN_PASSWORD.
  # Reads config at request time so a test-time reload takes effect.
  defp require_admin_configured(conn, _opts) do
    if ShhAi.Config.admin_configured?() do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:forbidden, "Admin dashboard is disabled: ADMIN_PASSWORD is not set.")
      |> halt()
    end
  end
end
