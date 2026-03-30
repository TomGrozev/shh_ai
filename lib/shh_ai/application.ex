defmodule ShhAi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Load configuration into persistent_term for zero-cost reads
    ShhAi.Config.load()

    # Load PII patterns into persistent_term for fast detection
    ShhAi.PII.Patterns.load_into_persistent_term()

    children =
      [
        ShhAiWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:shh_ai, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ShhAi.PubSub},
        # HTTP connection pool for backend requests
        {Finch, name: ShhAi.Finch, pools: pool_config()},
        ShhAi.SessionStore,
        # Start to serve requests, typically the last entry
        ShhAiWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ShhAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ShhAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp pool_config do
    # Configure connection pools for all LLM providers
    # Finch requires pool configuration with full URLs
    ShhAi.Config.providers()
    |> Enum.map(fn {_idx, _provider, config} -> config.base_url end)
    |> Enum.uniq()
    |> Enum.map(&pool_entry_for_url/1)
    |> Enum.reduce(%{}, fn entry, acc -> Map.merge(acc, entry) end)
  end

  defp pool_entry_for_url(base_url) do
    uri = URI.parse(base_url)

    if is_nil(uri.scheme) or is_nil(uri.host), do: raise(ArgumentError, "invalid provider url")

    # Ensure we have a complete URL with scheme
    scheme = uri.scheme || "https"
    host = uri.host
    port = uri.port || default_port(scheme)

    # Build the URL for Finch
    url = "#{scheme}://#{host}:#{port}"

    # Pool configuration: 50 connections per host, 5 pools of 10 each
    pool_size = 10
    pool_count = 5

    %{
      url => [
        {:size, pool_size},
        {:count, pool_count}
      ]
    }
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: 443
end
