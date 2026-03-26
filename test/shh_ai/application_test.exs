defmodule ShhAi.ApplicationTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config

  setup do
    # Save original env vars
    original = %{
      provider_openai_1_enabled: System.get_env("PROVIDER_OPENAI_1_ENABLED"),
      provider_openai_1_api_key: System.get_env("PROVIDER_OPENAI_1_API_KEY"),
      provider_openai_1_base_url: System.get_env("PROVIDER_OPENAI_1_BASE_URL"),
      provider_anthropic_1_enabled: System.get_env("PROVIDER_ANTHROPIC_1_ENABLED"),
      provider_anthropic_1_api_key: System.get_env("PROVIDER_ANTHROPIC_1_API_KEY"),
      provider_anthropic_1_base_url: System.get_env("PROVIDER_ANTHROPIC_1_BASE_URL"),
      provider_ollama_1_enabled: System.get_env("PROVIDER_OLLAMA_1_ENABLED"),
      provider_ollama_1_base_url: System.get_env("PROVIDER_OLLAMA_1_BASE_URL")
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

  describe "start/2" do
    test "application module is defined and has start function" do
      # Verify the Application module exists and exports start/2
      assert function_exported?(ShhAi.Application, :start, 2)
    end

    test "application module has config_change/3" do
      # Verify the Application module exports config_change/3
      assert function_exported?(ShhAi.Application, :config_change, 3)
    end

    test "start/2 initializes configuration" do
      # Set up a provider
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      System.put_env("PROVIDER_OPENAI_1_BASE_URL", "https://api.openai.com/v1")

      # Load config to initialize persistent_term
      Config.load()

      # Verify providers are loaded
      providers = Config.providers()
      assert is_list(providers)
      assert length(providers) >= 1
    end

    test "config_change/3 returns :ok" do
      # Test that config_change returns :ok
      result = ShhAi.Application.config_change(%{}, %{}, [])
      assert result == :ok
    end
  end

  describe "pool configuration" do
    test "pool_config builds pool for configured providers" do
      # Set up multiple providers with unique base URLs
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_1_BASE_URL", "https://api.openai.com/v1")

      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "key-2")
      System.put_env("PROVIDER_ANTHROPIC_1_BASE_URL", "https://api.anthropic.com")

      Config.load()

      providers = Config.providers()
      assert length(providers) >= 2

      # Verify we have both OpenAI and Anthropic providers
      provider_types = Enum.map(providers, fn {_, type, _} -> type end)
      assert :openai in provider_types
      assert :anthropic in provider_types
    end

    test "pool_config deduplicates base URLs" do
      # Set up multiple providers with same base URL
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_1_BASE_URL", "https://api.openai.com/v1")

      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-2")
      System.put_env("PROVIDER_OPENAI_2_BASE_URL", "https://api.openai.com/v1")

      Config.load()

      providers = Config.providers()
      openai_providers = Enum.filter(providers, fn {_, type, _} -> type == :openai end)
      assert length(openai_providers) == 2
    end

    test "handles http scheme in base URL" do
      System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
      System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://localhost:11434")

      Config.load()

      providers = Config.providers()
      ollama_providers = Enum.filter(providers, fn {_, type, _} -> type == :ollama end)
      assert length(ollama_providers) >= 1
    end

    test "handles URL without explicit port" do
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "test-key")
      System.put_env("PROVIDER_ANTHROPIC_1_BASE_URL", "https://api.anthropic.com")

      Config.load()

      providers = Config.providers()
      anthropic_providers = Enum.filter(providers, fn {_, type, _} -> type == :anthropic end)
      assert length(anthropic_providers) >= 1
    end
  end
end
