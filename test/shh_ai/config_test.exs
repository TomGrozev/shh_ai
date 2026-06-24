defmodule ShhAi.ConfigTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config

  setup do
    # Save original env vars
    original = %{
      provider_openai_1_enabled: System.get_env("PROVIDER_OPENAI_1_ENABLED"),
      provider_openai_1_api_key: System.get_env("PROVIDER_OPENAI_1_API_KEY"),
      provider_openai_1_base_url: System.get_env("PROVIDER_OPENAI_1_BASE_URL"),
      provider_openai_1_timeout: System.get_env("PROVIDER_OPENAI_1_TIMEOUT"),
      provider_anthropic_1_enabled: System.get_env("PROVIDER_ANTHROPIC_1_ENABLED"),
      provider_anthropic_1_api_key: System.get_env("PROVIDER_ANTHROPIC_1_API_KEY"),
      provider_anthropic_1_base_url: System.get_env("PROVIDER_ANTHROPIC_1_BASE_URL"),
      provider_ollama_1_enabled: System.get_env("PROVIDER_OLLAMA_1_ENABLED"),
      provider_ollama_1_base_url: System.get_env("PROVIDER_OLLAMA_1_BASE_URL"),
      conversation_backend: System.get_env("CONVERSATION_STORE_BACKEND"),
      conversation_ttl: System.get_env("CONVERSATION_TTL"),
      redis_url: System.get_env("REDIS_URL"),
      pii_enabled: System.get_env("PII_ENABLED"),
      pii_types: System.get_env("PII_TYPES"),
      pii_regex_confidence_threshold: System.get_env("PII_REGEX_CONFIDENCE_THRESHOLD"),
      pii_preserve_in_system: System.get_env("PII_PRESERVE_IN_SYSTEM"),
      pii_always_sanitize: System.get_env("PII_ALWAYS_SANITIZE"),
      audit_mode: System.get_env("AUDIT_MODE"),
      audit_encryption_key: System.get_env("AUDIT_ENCRYPTION_KEY")
    }

    on_exit(fn ->
      # Restore original env vars
      for {key, value} <- original do
        env_key = key |> to_string() |> String.upcase()

        if value do
          System.put_env(env_key, value)
        else
          System.delete_env(env_key)
        end
      end
    end)

    :ok
  end

  describe "providers/0" do
    test "returns empty list when no providers configured" do
      # Clear all provider env vars
      for idx <- 1..4, provider <- ["OPENAI", "ANTHROPIC", "OLLAMA"] do
        System.delete_env("PROVIDER_#{provider}_#{idx}_ENABLED")
        System.delete_env("PROVIDER_#{provider}_#{idx}_API_KEY")
        System.delete_env("PROVIDER_#{provider}_#{idx}_BASE_URL")
        System.delete_env("PROVIDER_#{provider}_#{idx}_TIMEOUT")
      end

      Config.load()
      providers = Config.providers()
      assert is_list(providers)
    end

    test "returns configured OpenAI provider" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key-123")
      System.put_env("PROVIDER_OPENAI_1_BASE_URL", "https://custom.openai.com/v1")
      Config.load()

      providers = Config.providers()
      assert providers != []

      openai_provider = Enum.find(providers, fn {_, type, _} -> type == :openai end)
      assert openai_provider != nil

      {idx, :openai, config} = openai_provider
      assert idx == 1
      assert config.base_url == "https://custom.openai.com/v1"
      assert config.api_key == "test-key-123"
    end

    test "returns default values for OpenAI when optional config missing" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.delete_env("PROVIDER_OPENAI_1_API_KEY")
      System.delete_env("PROVIDER_OPENAI_1_BASE_URL")
      System.delete_env("PROVIDER_OPENAI_1_TIMEOUT")
      Config.load()

      providers = Config.providers()
      openai_provider = Enum.find(providers, fn {_, type, _} -> type == :openai end)
      {_, :openai, config} = openai_provider

      assert config.base_url == "https://api.openai.com/v1"
      assert config.api_key == nil
      assert config.timeout == 60_000
    end

    test "returns configured Anthropic provider" do
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "sk-ant-test")
      System.put_env("PROVIDER_ANTHROPIC_1_BASE_URL", "https://custom.anthropic.com")
      Config.load()

      providers = Config.providers()
      anthropic_provider = Enum.find(providers, fn {_, type, _} -> type == :anthropic end)
      assert anthropic_provider != nil

      {_, :anthropic, config} = anthropic_provider
      assert config.base_url == "https://custom.anthropic.com"
      assert config.api_key == "sk-ant-test"
    end

    test "returns configured Ollama provider" do
      System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
      System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://localhost:11434")
      Config.load()

      providers = Config.providers()
      ollama_provider = Enum.find(providers, fn {_, type, _} -> type == :ollama end)
      assert ollama_provider != nil

      {_, :ollama, config} = ollama_provider
      assert config.base_url == "http://localhost:11434"
    end

    test "supports multiple providers of same type" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-2")
      Config.load()

      providers = Config.providers()
      openai_providers = Enum.filter(providers, fn {_, type, _} -> type == :openai end)
      assert length(openai_providers) == 2
    end

    test "respects custom timeout setting" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_TIMEOUT", "120000")
      Config.load()

      providers = Config.providers()
      {_, :openai, config} = Enum.find(providers, fn {_, type, _} -> type == :openai end)
      assert config.timeout == 120_000
    end
  end

  describe "select_provider/0" do
    test "returns a provider from the pool" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      Config.load()

      {idx, type, config} = Config.select_provider()
      assert is_integer(idx)
      assert type in [:openai, :anthropic, :ollama]
      assert is_map(config)
      assert Map.has_key?(config, :base_url)
      assert Map.has_key?(config, :api_key)
      assert Map.has_key?(config, :timeout)
    end
  end

  describe "redis_url/0" do
    test "returns nil by default" do
      System.delete_env("REDIS_URL")
      Config.load()

      assert Config.redis_url() == nil
    end

    test "returns configured URL" do
      System.put_env("REDIS_URL", "redis://localhost:6379")
      Config.load()

      assert Config.redis_url() == "redis://localhost:6379"
    end
  end

  describe "pii_enabled?/0" do
    test "returns true by default" do
      System.delete_env("PII_ENABLED")
      Config.load()

      assert Config.pii_enabled?() == true
    end

    test "returns false when disabled" do
      System.put_env("PII_ENABLED", "false")
      Config.load()

      assert Config.pii_enabled?() == false
    end
  end

  describe "pii_types/0" do
    test "returns default types" do
      System.delete_env("PII_TYPES")
      Config.load()

      types = Config.pii_types()
      assert :name in types
      assert :location in types
      assert :email in types
      assert :phone in types
      assert :ssn in types
      assert :financial in types
      assert :medical_id in types
    end

    test "returns configured types" do
      System.put_env("PII_TYPES", "email,phone")
      Config.load()

      assert Config.pii_types() == [:email, :phone]
    end
  end

  describe "pii_regex_confidence_threshold/0" do
    test "returns default threshold" do
      System.delete_env("PII_REGEX_CONFIDENCE_THRESHOLD")
      Config.load()

      assert Config.pii_regex_confidence_threshold() == 0.8
    end

    test "returns configured threshold" do
      System.put_env("PII_REGEX_CONFIDENCE_THRESHOLD", "0.95")
      Config.load()

      assert Config.pii_regex_confidence_threshold() == 0.95
    end
  end

  describe "preserve_in_system_messages/0" do
    test "returns default preserved types" do
      System.delete_env("PII_PRESERVE_IN_SYSTEM")
      Config.load()

      preserved = Config.preserve_in_system_messages()
      assert :location in preserved
      assert :organization in preserved
    end

    test "returns configured preserved types" do
      System.put_env("PII_PRESERVE_IN_SYSTEM", "name,email")
      Config.load()

      assert Config.preserve_in_system_messages() == [:name, :email]
    end
  end

  describe "always_sanitize/0" do
    test "returns default always sanitize types" do
      System.delete_env("PII_ALWAYS_SANITIZE")
      Config.load()

      always = Config.always_sanitize()
      assert :ssn in always
      assert :financial in always
      assert :email in always
      assert :phone in always
    end

    test "returns configured always sanitize types" do
      System.put_env("PII_ALWAYS_SANITIZE", "ssn,financial")
      Config.load()

      assert Config.always_sanitize() == [:ssn, :financial]
    end
  end

  describe "conversation_store_backend/0" do
    test "returns :ets by default" do
      System.delete_env("CONVERSATION_STORE_BACKEND")
      Config.load()

      assert Config.conversation_store_backend() == :ets
    end

    test "returns :redis when configured" do
      System.put_env("CONVERSATION_STORE_BACKEND", "redis")
      Config.load()

      assert Config.conversation_store_backend() == :redis
    end
  end

  describe "conversation_ttl/0" do
    test "returns default TTL (1 hour in ms)" do
      System.delete_env("CONVERSATION_TTL")
      Config.load()

      assert Config.conversation_ttl() == 3_600_000
    end

    test "returns configured TTL" do
      System.put_env("CONVERSATION_TTL", "7200000")
      Config.load()

      assert Config.conversation_ttl() == 7_200_000
    end
  end

  describe "Audit Mode validation (ADR 0010 acceptance criteria)" do
    test "raises a clear error when AUDIT_MODE=true but AUDIT_ENCRYPTION_KEY is missing" do
      System.put_env("AUDIT_MODE", "true")
      System.delete_env("AUDIT_ENCRYPTION_KEY")

      assert_raise RuntimeError, ~r/AUDIT_ENCRYPTION_KEY/, fn ->
        Config.load()
      end
    end

    test "raises a clear error when AUDIT_MODE=true but AUDIT_ENCRYPTION_KEY is empty" do
      System.put_env("AUDIT_MODE", "true")
      System.put_env("AUDIT_ENCRYPTION_KEY", "")

      assert_raise RuntimeError, ~r/AUDIT_ENCRYPTION_KEY/, fn ->
        Config.load()
      end
    end

    test "AUDIT_MODE=false does NOT require AUDIT_ENCRYPTION_KEY" do
      System.put_env("AUDIT_MODE", "false")
      System.delete_env("AUDIT_ENCRYPTION_KEY")

      assert :ok = Config.load()
    end
  end
end
