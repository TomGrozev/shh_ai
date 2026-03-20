defmodule ShhAi.Config do
  @moduledoc """
  Configuration module for the LLM Privacy Proxy.
  All configuration is loaded from environment variables at startup
  and stored in :persistent_term for low-cost reads.
  """

  @type provider :: :openai | :anthropic | :ollama

  @type provider_config :: %{
          base_url: String.t(),
          api_key: String.t() | nil,
          timeout: non_neg_integer()
        }

  @default_session_ttl 300_000
  @default_pii_types [:name, :location, :email, :phone, :ssn, :credit_card, :date, :medical_id]
  @default_pii_confidence_threshold 0.8
  @default_pii_preserve_in_system [:location, :organization]
  @default_pii_always_sanitize [:ssn, :credit_card, :email, :phone]

  @spec provider() :: {provider(), provider_config()}
  def provider() do
    :persistent_term.get({__MODULE__, :provider})
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
    provider = System.get_env("PROVIDER") || :openai

    config =
      case provider do
        :openai -> load_openai()
        :anthropic -> load_anthropic()
        :ollama -> load_ollama()
      end

    :persistent_term.put({__MODULE__, :provider}, {provider, config})
  end

  defp load_openai() do
    %{
      base_url: System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1",
      api_key: System.get_env("OPENAI_API_KEY"),
      timeout: parse_timeout(System.get_env("ANTHROPIC_TIMEOUT"), 60_000)
    }
  end

  defp load_anthropic() do
    %{
      base_url: System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com",
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      timeout: parse_timeout(System.get_env("ANTHROPIC_TIMEOUT"), 60_000)
    }
  end

  defp load_ollama() do
    %{
      base_url: System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434",
      api_key: nil,
      timeout: parse_timeout(System.get_env("OLLAMA_TIMEOUT"), 120_000)
    }
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
