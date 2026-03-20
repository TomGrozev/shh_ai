defmodule ShhAi.Proxy.ConfigTest do
  use ExUnit.Case, async: false

  alias ShhAi.Proxy.Config

  setup do
    # Save original env vars
    original = %{
      openai_api_key: System.get_env("OPENAI_API_KEY"),
      openai_base_url: System.get_env("OPENAI_BASE_URL"),
      anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
      anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL"),
      ollama_base_url: System.get_env("OLLAMA_BASE_URL"),
      session_backend: System.get_env("SESSION_STORE_BACKEND"),
      session_ttl: System.get_env("SESSION_TTL"),
      pii_enabled: System.get_env("PII_ENABLED"),
      pii_types: System.get_env("PII_TYPES")
    }

    on_exit(fn ->
      # Restore original env vars
      for {key, value} <- original do
        if value do
          System.put_env(key |> to_string() |> String.upcase(), value)
        else
          System.delete_env(key |> to_string() |> String.upcase())
        end
      end
    end)

    :ok
  end

  describe "providers/0" do
    test "returns provider configurations" do
      System.put_env("OPENAI_API_KEY", "test-key")
      Config.load()

      providers = Config.providers()

      assert Keyword.has_key?(providers, :openai)
      assert Keyword.has_key?(providers, :anthropic)
      assert Keyword.has_key?(providers, :ollama)
    end

    test "returns correct OpenAI config" do
      System.put_env("OPENAI_API_KEY", "test-key")
      System.put_env("OPENAI_BASE_URL", "https://custom.openai.com")
      Config.load()

      {:ok, config} = Config.get_provider(:openai)

      assert config.base_url == "https://custom.openai.com"
      assert config.api_key == "test-key"
    end

    test "returns default values when env vars not set" do
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_BASE_URL")
      Config.load()

      {:ok, config} = Config.get_provider(:openai)

      assert config.base_url == "https://api.openai.com"
      assert config.api_key == nil
    end
  end

  describe "session_store_backend/0" do
    test "returns :ets by default" do
      System.delete_env("SESSION_STORE_BACKEND")
      Config.load()

      assert Config.session_store_backend() == :ets
    end

    test "returns :redis when configured" do
      System.put_env("SESSION_STORE_BACKEND", "redis")
      Config.load()

      assert Config.session_store_backend() == :redis
    end
  end

  describe "session_ttl/0" do
    test "returns default TTL" do
      System.delete_env("SESSION_TTL")
      Config.load()

      assert Config.session_ttl() == 300_000
    end

    test "returns configured TTL" do
      System.put_env("SESSION_TTL", "60000")
      Config.load()

      assert Config.session_ttl() == 60_000
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

      assert :name in Config.pii_types()
      assert :location in Config.pii_types()
      assert :email in Config.pii_types()
    end

    test "returns configured types" do
      System.put_env("PII_TYPES", "email,phone")
      Config.load()

      assert Config.pii_types() == [:email, :phone]
    end
  end
end
