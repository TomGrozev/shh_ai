defmodule ShhAi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias ShhAi.PII.Patterns

  @impl true
  def start(_type, _args) do
    # Record application start time for uptime tracking
    :persistent_term.put({ShhAi, :started_at}, System.system_time(:microsecond))

    # Load configuration into persistent_term for zero-cost reads
    ShhAi.Config.load()

    # Load PII patterns into persistent_term for fast detection
    Patterns.load_into_persistent_term()

    # Attach telemetry handler for metrics persistence (skip in test)
    if Mix.env() != :test do
      :telemetry.attach(
        "metrics-persist-handler",
        [:shh_ai, :request, :stop],
        &ShhAi.Metrics.persist_handler/4,
        %{}
      )
    end

    children =
      [
        ShhAiWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:shh_ai, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ShhAi.PubSub},
        # Audit Mode datastore (Ecto + SQLite). See ADR 0010.
        ShhAi.Repo,
        # HTTP connection pool for provider requests
        {Finch, name: ShhAi.Finch, pools: pool_config()},
        ShhAi.Conversation.Store,
        # Audit Mode Cloak vault. Required when AUDIT_MODE is on so the
        # Writer can encrypt PII columns. See ADR 0010. When audit mode
        # is off, `audit_vault_child/0` returns nil and the supervisor
        # filters it out.
        audit_vault_child(),
        # Audit Mode write GenServer. Always started — when AUDIT_MODE
        # is off, every cast early-bails on `Config.audit_mode?()` and
        # the GenServer is essentially idle. See ADR 0010.
        ShhAi.Audit.Writer,
        # Metrics event buffer for recent events (ETS ring buffer)
        ShhAi.Metrics.EventBuffer,
        # Start to serve requests, typically the last entry
        ShhAiWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ShhAi.Supervisor]
    Supervisor.start_link(Enum.reject(children, &is_nil/1), opts)
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

  # Conditionally starts the Audit Mode Cloak vault. The vault is only
  # required when AUDIT_MODE is true (its init/1 reads the encryption
  # key from Config and raises if it's missing). When audit mode is off,
  # return nil — the supervisor's children spec filters nils out.
  defp audit_vault_child do
    if ShhAi.Config.audit_mode?(), do: ShhAi.Audit.Vault
  end
end
