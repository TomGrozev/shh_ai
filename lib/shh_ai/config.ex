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
      PROVIDER_OLLAMA_1_API_KEY=sk-ol-xxx

  Can support up to 4 providers of each type.

  """

  @type provider :: :openai | :anthropic | :ollama

  @type provider_config :: %{
          base_url: String.t(),
          api_key: String.t() | nil,
          timeout: non_neg_integer()
        }

  @type named_provider :: {integer(), provider(), provider_config()}

  alias ShhAi.PII.NER

  @supported_pii_types [
    :name,
    :location,
    :email,
    :phone,
    :ssn,
    :financial,
    :date,
    :medical_id,
    :ip_address,
    :url,
    :api_key,
    :secret,
    :auth_token,
    :private_key,
    :national_id,
    :device_id,
    :passport,
    :organization,
    :age,
    :title
  ]

  @default_conversation_ttl 3_600_000
  @default_pii_types [
    :name,
    :location,
    :email,
    :phone,
    :ssn,
    :financial,
    :medical_id,
    :ip_address,
    :api_key,
    :secret,
    :auth_token,
    :private_key,
    :url,
    :national_id,
    :device_id,
    :passport
  ]
  @default_pii_regex_confidence_threshold 0.8
  @default_pii_preserve_in_system [:location, :organization, :date]
  @default_pii_always_sanitize [
    :ssn,
    :financial,
    :email,
    :phone,
    :api_key,
    :secret,
    :auth_token,
    :private_key,
    :medical_id,
    :national_id
  ]

  # NER (Neural Entity Recognition) configuration
  @default_pii_ner_enabled true
  @default_pii_ner_confidence_threshold 0.85
  @default_pii_hybrid_mode :complementary

  # Confidence calibration configuration
  # Temperature for NER confidence scaling (> 1.0 reduces overconfidence)
  @default_pii_ner_temperature 1.5

  @doc """
  Returns all configured providers as a list of {idx, type, name, config} tuples.
  """
  @spec providers() :: [named_provider()]
  def providers do
    :persistent_term.get({__MODULE__, :providers})
  end

  @doc """
  Selects a random provider from the configured pool.
  Returns {idx, provider_type, provider_name, config}.
  """
  @spec select_provider() :: named_provider()
  def select_provider do
    providers = providers()

    if providers == [] do
      raise ArgumentError,
            "No providers configured. Set at least one PROVIDER_{TYPE}_{IDX}_ENABLED=true environment variable."
    end

    idx = :rand.uniform(length(providers)) - 1
    Enum.at(providers, idx)
  end

  @spec conversation_store_backend() :: :ets | :redis
  def conversation_store_backend do
    :persistent_term.get({__MODULE__, :conversation_store_backend})
  end

  @spec conversation_ttl() :: non_neg_integer()
  def conversation_ttl do
    :persistent_term.get({__MODULE__, :conversation_ttl})
  end

  @spec redis_url() :: String.t() | nil
  def redis_url do
    :persistent_term.get({__MODULE__, :redis_url})
  end

  @spec pii_enabled?() :: boolean()
  def pii_enabled? do
    :persistent_term.get({__MODULE__, :pii_enabled})
  end

  @spec pii_types() :: [atom()]
  def pii_types do
    :persistent_term.get({__MODULE__, :pii_types})
  end

  @spec pii_regex_confidence_threshold() :: float()
  def pii_regex_confidence_threshold do
    :persistent_term.get({__MODULE__, :pii_regex_confidence_threshold})
  end

  @spec preserve_in_system_messages() :: [atom()]
  def preserve_in_system_messages do
    :persistent_term.get({__MODULE__, :preserve_in_system_messages})
  end

  @spec always_sanitize() :: [atom()]
  def always_sanitize do
    :persistent_term.get({__MODULE__, :always_sanitize})
  end

  @spec pii_ner_enabled() :: boolean()
  def pii_ner_enabled do
    :persistent_term.get({__MODULE__, :pii_ner_enabled})
  end

  @spec pii_ner_confidence_threshold() :: float()
  def pii_ner_confidence_threshold do
    :persistent_term.get({__MODULE__, :pii_ner_confidence_threshold})
  end

  @spec pii_hybrid_mode() :: :complementary | :ner_only | :regex_only
  def pii_hybrid_mode do
    :persistent_term.get({__MODULE__, :pii_hybrid_mode})
  end

  @spec pii_ner_temperature() :: float()
  def pii_ner_temperature do
    :persistent_term.get({__MODULE__, :pii_ner_temperature})
  end

  @spec pii_ner_unvalidated_penalty() :: float()
  def pii_ner_unvalidated_penalty do
    :persistent_term.get({__MODULE__, :pii_ner_unvalidated_penalty})
  end

  @spec audit_mode?() :: boolean()
  def audit_mode? do
    :persistent_term.get({__MODULE__, :audit_mode})
  end

  @spec audit_encryption_key() :: String.t()
  def audit_encryption_key do
    :persistent_term.get({__MODULE__, :audit_encryption_key})
  end

  @spec audit_retention_days() :: non_neg_integer()
  def audit_retention_days do
    :persistent_term.get({__MODULE__, :audit_retention_days})
  end

  @spec audit_db_path() :: String.t()
  def audit_db_path do
    :persistent_term.get({__MODULE__, :audit_db_path})
  end

  @doc """
  Loads all configuration into :persistent_term at startup.
  This should be called once during application start.
  """
  @spec load() :: :ok
  def load do
    load_providers()
    load_conversation_store()
    load_pii_config()
    load_audit_config()
    :ok
  end

  defp load_providers do
    providers = load_all_providers()
    :persistent_term.put({__MODULE__, :providers}, providers)
  end

  defp load_all_providers do
    for idx <- 1..4, provider <- [:openai, :anthropic, :ollama] do
      config =
        load_provider_config(provider, idx)
        |> add_provider_name(provider, idx)

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

  defp add_provider_name(nil, _provider, _idx), do: nil

  defp add_provider_name(config, provider, idx) do
    env_val = get_provider_env(provider, idx, "NAME")
    name = if env_val, do: env_val, else: ShhAi.ProviderName.for_provider(idx, config)
    Map.put(config, :name, name)
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
        timeout: parse_timeout(get_provider_env(:anthropic, idx, "TIMEOUT"), 60_000)
      }
    end
  end

  defp load_provider_config(:ollama, idx) do
    if get_provider_env(:ollama, idx, "ENABLED") == "true" do
      %{
        base_url: get_provider_env(:ollama, idx, "BASE_URL") || "http://localhost:11434",
        api_key: get_provider_env(:ollama, idx, "API_KEY"),
        timeout: parse_timeout(get_provider_env(:ollama, idx, "TIMEOUT"), 120_000)
      }
    end
  end

  defp load_conversation_store do
    backend =
      case System.get_env("CONVERSATION_STORE_BACKEND") do
        "redis" -> :redis
        _ -> :ets
      end

    ttl =
      System.get_env("CONVERSATION_TTL")
      |> case do
        nil -> @default_conversation_ttl
        val -> String.to_integer(val)
      end

    redis_url = System.get_env("REDIS_URL")

    :persistent_term.put({__MODULE__, :conversation_store_backend}, backend)
    :persistent_term.put({__MODULE__, :conversation_ttl}, ttl)
    :persistent_term.put({__MODULE__, :redis_url}, redis_url)
  end

  defp load_pii_config do
    ner_enabled = env_bool("PII_NER_ENABLED", @default_pii_ner_enabled)

    if ner_enabled do
      NER.init()
    end

    config = %{
      pii_enabled: env_bool("PII_ENABLED", true),
      pii_types:
        env_csv("PII_TYPES", @default_pii_types, &String.to_existing_atom/1)
        |> Enum.filter(&(&1 in @supported_pii_types)),
      pii_regex_confidence_threshold:
        env_float("PII_REGEX_CONFIDENCE_THRESHOLD", @default_pii_regex_confidence_threshold),
      preserve_in_system_messages:
        env_csv(
          "PII_PRESERVE_IN_SYSTEM",
          @default_pii_preserve_in_system,
          &String.to_existing_atom/1
        ),
      always_sanitize:
        env_csv("PII_ALWAYS_SANITIZE", @default_pii_always_sanitize, &String.to_existing_atom/1),
      pii_ner_enabled: ner_enabled,
      pii_ner_confidence_threshold:
        env_float("PII_NER_CONFIDENCE_THRESHOLD", @default_pii_ner_confidence_threshold),
      pii_hybrid_mode:
        env_enum("PII_HYBRID_MODE", @default_pii_hybrid_mode, [:ner_only, :regex_only]),
      pii_ner_temperature: env_float("PII_NER_TEMPERATURE", @default_pii_ner_temperature)
    }

    Enum.each(config, fn {key, value} ->
      :persistent_term.put({__MODULE__, key}, value)
    end)
  end

  defp load_audit_config do
    # Priority: Application.get_env (set in config/test.exs) > env var > default.
    # This lets test config override env vars without System.put_env.
    audit_mode = app_or_env(:audit_mode, "AUDIT_MODE", false, &env_bool/2)

    audit_encryption_key =
      app_or_env(:audit_encryption_key, "AUDIT_ENCRYPTION_KEY", "", &env_string/2)

    audit_retention_days =
      app_or_env(:audit_retention_days, "AUDIT_RETENTION_DAYS", 30, &env_int/2)

    audit_db_path =
      app_or_env(:audit_db_path, "AUDIT_DB_PATH", "priv/audit/audit.db", &env_string/2)

    if audit_mode and audit_encryption_key == "" do
      raise "AUDIT_ENCRYPTION_KEY is required when AUDIT_MODE=true"
    end

    :persistent_term.put({__MODULE__, :audit_mode}, audit_mode)
    :persistent_term.put({__MODULE__, :audit_encryption_key}, audit_encryption_key)
    :persistent_term.put({__MODULE__, :audit_retention_days}, audit_retention_days)
    :persistent_term.put({__MODULE__, :audit_db_path}, audit_db_path)
  end

  # Read from Application config first, then env var, then default.
  # The `parser` is a 2-arity function (env_key, default) that reads
  # from the environment variable and coerces the type.
  defp app_or_env(app_key, env_key, default, parser) do
    case Application.get_env(:shh_ai, app_key) do
      nil -> parser.(env_key, default)
      value -> value
    end
  end

  defp env_bool(key, default) do
    case System.get_env(key) do
      nil -> default
      "false" -> false
      "true" -> true
      _ -> default
    end
  end

  defp env_string(key, default) do
    System.get_env(key, default)
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_integer(val)
    end
  end

  defp env_float(key, default) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_float(val)
    end
  end

  defp env_csv(key, default, parser) do
    case System.get_env(key) do
      nil -> default
      val -> val |> String.split(",") |> Enum.map(parser)
    end
  end

  defp env_enum(key, default, allowed) do
    case System.get_env(key) do
      nil -> default
      val -> if val in allowed, do: String.to_atom(val), else: default
    end
  end

  defp parse_timeout(nil, default), do: default
  defp parse_timeout(val, _default), do: String.to_integer(val)
end
