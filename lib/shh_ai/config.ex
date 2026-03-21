defmodule ShhAi.Config do
  @moduledoc """
  Configuration module for the LLM Privacy Proxy.
  All configuration is loaded from environment variables at startup
  and stored in :persistent_term for low-cost reads.

  ## Multi-Provider Configuration

  The proxy supports multiple backend providers with random selection for load balancing.
  Configuration is done via environment variables using a named provider approach:

      PROVIDER_OPENAI_1_ENABLED=true
      PROVIDER_OPENAI_1_API_KEY=sk-xxx
      PROVIDER_OPENAI_1_BASE_URL=https://api.openai.com/v1

      PROVIDER_ANTHROPIC_1_ENABLED=true
      PROVIDER_ANTHROPIC_1_API_KEY=sk-ant-xxx
      PROVIDER_ANTHROPIC_1_BASE_URL=sk-ant-xxx

      PROVIDER_OLLAMA_1_ENABLED=true
      PROVIDER_OLLAMA_1_BASE_URL=http://localhost:11434

  Can support up to 4 providers of each type.

  """

  @type provider :: :openai | :anthropic | :ollama

  @type provider_config :: %{
          base_url: String.t(),
          api_key: String.t() | nil,
          timeout: non_neg_integer()
        }

  @type named_provider :: {integer(), provider(), provider_config()}

  @default_session_ttl 300_000
  @default_pii_types [:name, :location, :email, :phone, :ssn, :credit_card, :date, :medical_id]
  @default_pii_confidence_threshold 0.8
  @default_pii_preserve_in_system [:location, :organization]
  @default_pii_always_sanitize [:ssn, :credit_card, :email, :phone]

  @doc """
  Returns all configured providers as a list of {name, type, config} tuples.
  """
  @spec providers() :: [named_provider()]
  def providers() do
    :persistent_term.get({__MODULE__, :providers})
  end

  @doc """
  Selects a random provider from the configured pool.
  Returns {name, provider_type, config}.
  """
  @spec select_provider() :: named_provider()
  def select_provider() do
    providers = providers()

    idx = :rand.uniform(length(providers)) - 1
    Enum.at(providers, idx)
  end

  @spec session_store_backend() :: :ets | :redis
  def session_store_backend do
    :persistent_term.get({__MODULE__, :session_store_backend})
  end

  @spec session_ttl() :: non_neg_integer()
  def session_ttl do
    :persistent_term.get({__MODULE__, :session_ttl})
  end

  @spec redis_url() :: String.t() | nil
  def redis_url do
    :persistent_term.get({__MODULE__, :redis_url})
  end

  @spec pii_enabled() :: boolean()
  def pii_enabled do
    :persistent_term.get({__MODULE__, :pii_enabled})
  end

  @spec pii_types() :: [atom()]
  def pii_types do
    :persistent_term.get({__MODULE__, :pii_types})
  end

  @spec pii_confidence_threshold() :: float()
  def pii_confidence_threshold do
    :persistent_term.get({__MODULE__, :pii_confidence_threshold})
  end

  @spec preserve_in_system_messages() :: [atom()]
  def preserve_in_system_messages do
    :persistent_term.get({__MODULE__, :preserve_in_system_messages})
  end

  @spec always_sanitize() :: [atom()]
  def always_sanitize do
    :persistent_term.get({__MODULE__, :always_sanitize})
  end

  @doc """
  Loads all configuration into :persistent_term at startup.
  This should be called once during application start.
  """
  @spec load() :: :ok
  def load do
    load_providers()
    load_session_store()
    load_pii_config()
    :ok
  end

  defp load_providers do
    providers = load_all_providers() |> dbg()
    :persistent_term.put({__MODULE__, :providers}, providers)
  end

  defp load_all_providers do
    for idx <- 1..4, provider <- [:openai, :anthropic, :ollama] do
      config = load_provider_config(provider, idx)

      {idx, provider, config}
    end
    |> Enum.reject(fn {_, _, config} -> is_nil(config) end)
  end

  defp get_provider_env(type, idx, key) do
    [
      "PROVIDER",
      type |> to_string() |> String.upcase(),
      Integer.to_string(idx),
      key
    ]
    |> Enum.join("_")
    |> System.get_env()
  end

  defp load_provider_config(:openai, idx) do
    if get_provider_env(:openai, idx, "ENABLED") == "true" do
      %{
        base_url: get_provider_env(:openai, idx, "BASE_URL") || "https://api.openai.com/v1",
        api_key: get_provider_env(:openai, idx, "API_KEY"),
        timeout: parse_timeout(get_provider_env(:openai, idx, "TIMEOUT"), 60_000)
      }
    end
  end

  defp load_provider_config(:anthropic, idx) do
    if get_provider_env(:anthropic, idx, "ENABLED") == "true" do
      %{
        base_url: get_provider_env(:anthropic, idx, "BASE_URL") || "https://api.anthropic.com",
        api_key: get_provider_env(:anthropic, idx, "API_KEY"),
        timeout: parse_timeout(get_provider_env(:openai, idx, "TIMEOUT"), 60_000)
      }
    end
  end

  defp load_provider_config(:ollama, idx) do
    if get_provider_env(:ollama, idx, "ENABLED") == "true" do
      %{
        base_url: get_provider_env(:ollama, idx, "BASE_URL") || "http://localhost:11434",
        api_key: nil,
        timeout: parse_timeout(get_provider_env(:ollama, idx, "TIMEOUT"), 120_000)
      }
    end
  end

  defp load_session_store do
    backend =
      case System.get_env("SESSION_STORE_BACKEND") do
        "redis" -> :redis
        _ -> :ets
      end

    ttl =
      System.get_env("SESSION_TTL")
      |> case do
        nil -> @default_session_ttl
        val -> String.to_integer(val)
      end

    redis_url = System.get_env("REDIS_URL")

    :persistent_term.put({__MODULE__, :session_store_backend}, backend)
    :persistent_term.put({__MODULE__, :session_ttl}, ttl)
    :persistent_term.put({__MODULE__, :redis_url}, redis_url)
  end

  defp load_pii_config do
    enabled = System.get_env("PII_ENABLED") != "false"

    types =
      System.get_env("PII_TYPES")
      |> case do
        nil -> @default_pii_types
        val -> val |> String.split(",") |> Enum.map(&str_to_pii_type/1)
      end

    threshold =
      System.get_env("PII_CONFIDENCE_THRESHOLD")
      |> case do
        nil -> @default_pii_confidence_threshold
        val -> String.to_float(val)
      end

    preserve_in_system =
      System.get_env("PII_PRESERVE_IN_SYSTEM")
      |> case do
        nil -> @default_pii_preserve_in_system
        val -> val |> String.split(",") |> Enum.map(&str_to_pii_type/1)
      end

    always_sanitize =
      System.get_env("PII_ALWAYS_SANITIZE")
      |> case do
        nil -> @default_pii_always_sanitize
        val -> val |> String.split(",") |> Enum.map(&str_to_pii_type/1)
      end

    :persistent_term.put({__MODULE__, :pii_enabled}, enabled)
    :persistent_term.put({__MODULE__, :pii_types}, types)
    :persistent_term.put({__MODULE__, :pii_confidence_threshold}, threshold)
    :persistent_term.put({__MODULE__, :preserve_in_system_messages}, preserve_in_system)
    :persistent_term.put({__MODULE__, :always_sanitize}, always_sanitize)
  end

  defp str_to_pii_type("name"), do: :name
  defp str_to_pii_type("location"), do: :location
  defp str_to_pii_type("email"), do: :email
  defp str_to_pii_type("phone"), do: :phone
  defp str_to_pii_type("ssn"), do: :ssn
  defp str_to_pii_type("credit_card"), do: :credit_card
  defp str_to_pii_type("date"), do: :date
  defp str_to_pii_type("medical_id"), do: :medical_id

  defp parse_timeout(nil, default), do: default
  defp parse_timeout(val, _default), do: String.to_integer(val)
end
