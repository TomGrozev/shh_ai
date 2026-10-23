defmodule ShhAi.Config do
  @moduledoc """
  Configuration module for the LLM Privacy Proxy.
  All configuration is loaded from environment variables at startup
  and stored in :persistent_term for low-cost reads.

  ## Multi-Provider Configuration

  Configuration configures the provider instances; `ShhAi.TargetProvider`
  chooses the Target Provider for a request among them.
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

  @typedoc """
  A **Provider Instance**'s stable identity, as the ADR-0013 composite name —
  `provider_index`, e.g. `"openai_1"`.

  `provider_index` names one configured provider endpoint. The index is stable
  for as long as a deployment's configuration is unchanged, so this name — not
  the list index — is what a conversation pins and what `ShhAi.ModelCatalog`
  indexes provider instances under.
  """
  @type provider_instance :: String.t()

  @type pii_error_mode :: :block | :forward

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
  #
  # NER defaults on only where the ML stack is compiled in. The slim,
  # regex-only image drops Bumblebee/Nx/EXLA (mix.exs `ml_deps/0`, ticket
  # #70), so it defaults to NER off and serves regex-only out of the box.
  # An operator who sets PII_NER_ENABLED=true in the slim image still hits
  # the fail-closed boot abort in `load_pii_config/0` below.
  @ml_available Code.ensure_loaded?(Bumblebee)
  @default_pii_ner_enabled @ml_available

  # The NER model's softmax scores cluster high, so the old 0.85 cutoff
  # discarded most true entities. The detector keeps an unvalidated NER hit's
  # confidence unchanged, so this threshold is a true floor on the model's
  # calibrated score. 0.60 is the knee of a sweep over a held-out sample (2000
  # docs, seed 7, disjoint from the benchmark) against PII-free code and prose:
  # 0.48 NER false hits per 1k ordinary (lib/docs/deps) chars, below which
  # over-masking roughly doubles for a few points of extra PII coverage.
  # Re-sweep when the model or regex set changes (docs/benchmarks.md).
  @default_pii_ner_confidence_threshold 0.60
  @default_pii_hybrid_mode :complementary

  # Per-type NER thresholds: `%{pii_type => min_confidence}` overriding the
  # global NER threshold for the listed types. Empty by default, so behaviour
  # is unchanged unless an operator opts in via PII_NER_TYPE_THRESHOLDS.
  @default_pii_ner_type_thresholds %{}

  # Detector hard-error policy: `:block` (fail closed) unless the operator
  # explicitly opts into `:forward` (fail open) via PII_ERROR_MODE.
  @default_pii_error_mode :block

  # Confidence calibration configuration
  # Temperature for NER confidence scaling (> 1.0 reduces overconfidence).
  # 1.0 (no scaling): 1.5 gave the same coverage at the 0.30 cutoff with more
  # false positives, and at higher cutoffs flattened true scores below the
  # threshold.
  @default_pii_ner_temperature 1.0

  @doc """
  Returns all configured providers as a list of {idx, type, name, config} tuples.
  """
  @spec providers() :: [named_provider()]
  def providers do
    :persistent_term.get({__MODULE__, :providers})
  end

  @doc """
  The composite ADR-0013 identity of a configured provider — `provider_index`,
  e.g. `"openai_1"`.

  This is the identity stored on a conversation's pin and the key
  `ShhAi.ModelCatalog` indexes provider instances under.
  """
  @spec provider_instance(named_provider()) :: provider_instance()
  def provider_instance({idx, provider, _config}) do
    "#{provider}_#{idx}"
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

  @doc """
  Returns how a PII detector hard error is handled.

  `:block` (default) fails the request closed — nothing is forwarded
  upstream. `:forward` fails open: the request is forwarded un-sanitized.
  """
  @spec pii_error_mode() :: pii_error_mode()
  def pii_error_mode do
    :persistent_term.get({__MODULE__, :pii_error_mode})
  end

  @spec pii_types() :: [atom()]
  def pii_types do
    :persistent_term.get({__MODULE__, :pii_types})
  end

  @doc """
  Lists the PII types the configured detectors can emit.

  This is the full type space of the regex patterns and the NER model,
  independent of the `pii_types/0` allow-list. `pii_types/0` is the product
  default (a subset of this list); the accuracy benchmark enables every type
  here so its score reflects the detector's whole capability.
  """
  @spec supported_pii_types() :: [atom()]
  def supported_pii_types, do: @supported_pii_types

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

  @doc """
  Per-type NER confidence thresholds, `%{pii_type => min_confidence}`.

  A type present here uses its own threshold instead of
  `pii_ner_confidence_threshold/0`; unlisted types keep the global one.
  """
  @spec pii_ner_type_thresholds() :: %{atom() => float()}
  def pii_ner_type_thresholds do
    :persistent_term.get({__MODULE__, :pii_ner_type_thresholds}, @default_pii_ner_type_thresholds)
  end

  @spec pii_hybrid_mode() :: :complementary | :ner_only | :regex_only
  def pii_hybrid_mode do
    :persistent_term.get({__MODULE__, :pii_hybrid_mode})
  end

  @spec pii_ner_temperature() :: float()
  def pii_ner_temperature do
    :persistent_term.get({__MODULE__, :pii_ner_temperature})
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

  @spec audit_cleanup_interval() :: non_neg_integer()
  def audit_cleanup_interval do
    :persistent_term.get({__MODULE__, :audit_cleanup_interval})
  end

  @spec audit_db_path() :: String.t()
  def audit_db_path do
    :persistent_term.get({__MODULE__, :audit_db_path})
  end

  @doc """
  The admin dashboard username (`ADMIN_USER`). Defaults to `"admin"` when unset.
  """
  @spec admin_user() :: String.t()
  def admin_user do
    :persistent_term.get({__MODULE__, :admin_user})
  end

  @doc """
  The admin dashboard password (`ADMIN_PASSWORD`), or `nil` when unset.

  A `nil` or empty password means the dashboard is **not configured** and
  must refuse to serve — see `admin_configured?/0`.
  """
  @spec admin_password() :: String.t() | nil
  def admin_password do
    :persistent_term.get({__MODULE__, :admin_password})
  end

  @doc """
  Whether admin dashboard authentication is configured — `ADMIN_PASSWORD` is a
  non-empty value.

  When `false`, every `/admin` route refuses to serve (403).
  """
  @spec admin_configured?() :: boolean()
  def admin_configured? do
    case admin_password() do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc """
  The inbound proxy API keys (`PROXY_API_KEYS`), comma-separated and trimmed.

  These are the credentials the `ShhAiWeb.ProxyAuth` gate accepts on the
  `/v1` and `/api` scopes. An empty list means the gate is unconfigured and
  every proxy request is refused (503).
  """
  @spec proxy_api_keys() :: [String.t()]
  def proxy_api_keys do
    :persistent_term.get({__MODULE__, :proxy_api_keys})
  end

  @doc """
  Whether the inbound proxy API-key gate is configured — `PROXY_API_KEYS`
  holds at least one non-empty key.
  """
  @spec proxy_configured?() :: boolean()
  def proxy_configured? do
    proxy_api_keys() != []
  end

  @doc """
  How often `ShhAi.ModelCatalog` re-probes every provider instance, in milliseconds.
  `:disabled` turns the periodic refresh off (the boot probe still runs).
  """
  @spec model_catalog_refresh_interval() :: pos_integer() | :disabled
  def model_catalog_refresh_interval do
    :persistent_term.get({__MODULE__, :model_catalog_refresh_interval})
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
    load_admin_config()
    load_proxy_config()
    load_model_catalog_config()
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
    |> Enum.map(&require_provider_api_key!/1)
  end

  # Every enabled provider must carry a non-empty API key. The key is a
  # credential, so a provider instance without one is a configuration error — mirroring
  # the AUDIT_ENCRYPTION_KEY / NER boot validation. This guarantees every pool
  # member always has a configured key. See issue #55.
  defp require_provider_api_key!({idx, provider, config} = named_provider) do
    case config.api_key do
      key when is_binary(key) and key != "" ->
        named_provider

      _ ->
        env_var = "PROVIDER_#{provider |> to_string() |> String.upcase()}_#{idx}_API_KEY"

        raise "#{env_var} is required: the enabled provider #{provider}_#{idx} has no API key. " <>
                "Set #{env_var}, or disable the provider with " <>
                "PROVIDER_#{provider |> to_string() |> String.upcase()}_#{idx}_ENABLED=false."
    end
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

    # Fail closed at boot: with NER enabled, a model that won't load aborts
    # startup (crash-loop) rather than serving with detection silently
    # degraded. The operator's escape hatch is PII_NER_ENABLED=false. See
    # issue #65.
    if ner_enabled do
      case NER.init() do
        :ok ->
          :ok

        {:error, reason} ->
          raise "NER model failed to load with PII_NER_ENABLED=true: #{inspect(reason)}. " <>
                  "Set PII_NER_ENABLED=false to boot without NER, or fix the model/cache."
      end
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
      pii_ner_type_thresholds:
        parse_ner_type_thresholds(System.get_env("PII_NER_TYPE_THRESHOLDS")),
      pii_hybrid_mode:
        env_enum("PII_HYBRID_MODE", @default_pii_hybrid_mode, [:ner_only, :regex_only]),
      pii_ner_temperature: env_float("PII_NER_TEMPERATURE", @default_pii_ner_temperature),
      pii_error_mode: parse_pii_error_mode(System.get_env("PII_ERROR_MODE"))
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

    audit_cleanup_interval =
      app_or_env(:audit_cleanup_interval, "AUDIT_CLEANUP_INTERVAL_HOURS", 1, &env_int/2)

    audit_db_path =
      app_or_env(:audit_db_path, "AUDIT_DB_PATH", "priv/audit/audit.db", &env_string/2)

    if audit_mode do
      validate_audit_encryption_key!(audit_encryption_key)
    end

    :persistent_term.put({__MODULE__, :audit_mode}, audit_mode)
    :persistent_term.put({__MODULE__, :audit_encryption_key}, audit_encryption_key)
    :persistent_term.put({__MODULE__, :audit_retention_days}, audit_retention_days)
    :persistent_term.put({__MODULE__, :audit_cleanup_interval}, audit_cleanup_interval)
    :persistent_term.put({__MODULE__, :audit_db_path}, audit_db_path)
  end

  # The Cloak vault (ShhAi.Audit.Vault) Base32-decodes this key and needs
  # exactly 32 bytes for AES-256-GCM. Validating here — with the same
  # `Base.decode32/1` defaults the vault uses — turns a misconfigured key into
  # a clear boot failure instead of an opaque crash later. See issue #56.
  defp validate_audit_encryption_key!("") do
    raise "AUDIT_ENCRYPTION_KEY is required when AUDIT_MODE=true. " <>
            "Set it to a Base32-encoded 32-byte key. Generate one with: " <>
            "mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode32())'"
  end

  defp validate_audit_encryption_key!(key) do
    case Base.decode32(key) do
      {:ok, decoded} when byte_size(decoded) == 32 ->
        :ok

      {:ok, decoded} ->
        raise "AUDIT_ENCRYPTION_KEY must Base32-decode to exactly 32 bytes, " <>
                "but decoded to #{byte_size(decoded)} bytes. " <>
                "Generate one with: mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode32())'"

      :error ->
        raise "AUDIT_ENCRYPTION_KEY is not valid Base32. " <>
                "Provide a Base32-encoded 32-byte key (uppercase A-Z2-7, padded with '=')."
    end
  end

  defp load_admin_config do
    admin_user =
      case System.get_env("ADMIN_USER") do
        blank when blank in [nil, ""] -> "admin"
        user -> user
      end

    :persistent_term.put({__MODULE__, :admin_user}, admin_user)
    :persistent_term.put({__MODULE__, :admin_password}, System.get_env("ADMIN_PASSWORD"))
  end

  defp load_proxy_config do
    keys =
      case System.get_env("PROXY_API_KEYS") do
        nil ->
          []

        value ->
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    # Do not raise: test/dev must still boot without an operator-set gate key.
    # The gate itself refuses proxy traffic (503) while the list is empty, so
    # the deployment fails closed rather than serving an unauthenticated proxy.
    # The loud boot warning lives in `ShhAi.Application.start/2` (once per boot),
    # mirroring the admin-dashboard warning.
    :persistent_term.put({__MODULE__, :proxy_api_keys}, keys)
  end

  defp load_model_catalog_config do
    # Priority: Application.get_env (set in config/test.exs) > env var > default.
    interval =
      app_or_env(
        :model_catalog_refresh_interval,
        "MODEL_CATALOG_REFRESH_INTERVAL_MS",
        300_000,
        &env_int/2
      )

    :persistent_term.put({__MODULE__, :model_catalog_refresh_interval}, interval)
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

  # `PII_ERROR_MODE` is fail-closed: only the literal "forward" opts into
  # fail-open; unset, "block", and any unrecognised value stay on :block.
  defp parse_pii_error_mode("forward"), do: :forward
  defp parse_pii_error_mode(_), do: @default_pii_error_mode

  # `PII_NER_TYPE_THRESHOLDS` is a comma-separated list of `type:threshold`
  # pairs, e.g. "type:0.5,title:0.4". Malformed entries raise at boot rather
  # than silently dropping a threshold the operator believes is in effect.
  defp parse_ner_type_thresholds(nil), do: @default_pii_ner_type_thresholds

  defp parse_ner_type_thresholds(value) do
    value
    |> String.split(",", trim: true)
    |> Map.new(fn entry ->
      with [type, threshold] <- String.split(entry, ":", parts: 2),
           type when type in @supported_pii_types <- parse_pii_type(String.trim(type)) do
        {type, parse_ner_threshold!(String.trim(threshold))}
      else
        _ ->
          raise ArgumentError,
                "invalid PII_NER_TYPE_THRESHOLDS entry #{inspect(entry)}; " <>
                  "expected comma-separated type:threshold pairs with a supported PII type"
      end
    end)
  end

  defp parse_pii_type(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp parse_ner_threshold!(value) do
    case Float.parse(value) do
      {threshold, ""} ->
        threshold

      _ ->
        raise ArgumentError,
              "invalid threshold #{inspect(value)} in PII_NER_TYPE_THRESHOLDS; expected a number"
    end
  end

  defp parse_timeout(nil, default), do: default
  defp parse_timeout(val, _default), do: String.to_integer(val)
end
