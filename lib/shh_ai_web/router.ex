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

  # Pipeline for proxy requests - accepts both JSON and streaming
  pipeline :proxy do
    plug :accepts, ["json", "text/event-stream"]
    plug :put_resp_content_type, "application/json"
  end

  scope "/", ShhAiWeb do
    pipe_through :browser

    get "/", PageController, :home
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
    # Catch-all for other OpenAI endpoints
    forward "/", ProxyController, :handle_openai
  end

  # Anthropic API proxy endpoints
  scope "/v1/anthropic", ShhAiWeb do
    pipe_through :proxy

    post "/messages", ProxyController, :handle_anthropic
    forward "/", ProxyController, :handle_anthropic
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
end
