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
      assert providers != []
    end
  end

  describe "audit mode conditional supervision (ADR 0016)" do
    setup do
      original_env = %{
        "AUDIT_MODE" => System.get_env("AUDIT_MODE"),
        "AUDIT_ENCRYPTION_KEY" => System.get_env("AUDIT_ENCRYPTION_KEY")
      }

      original_repo_config = Application.get_env(:shh_ai, ShhAi.Repo)
      original_audit_mode_config = Application.get_env(:shh_ai, :audit_mode)

      on_exit(fn ->
        for {name, value} <- original_env do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end

        put_or_delete_env(:shh_ai, ShhAi.Repo, original_repo_config)
        put_or_delete_env(:shh_ai, :audit_mode, original_audit_mode_config)

        # Leave the application booted in the suite's original shape.
        _ = Application.stop(:shh_ai)
        :ok = Application.start(:shh_ai)
      end)

      :ok
    end

    test "audit mode off: boot starts no Repo, no Vault, and creates no database file" do
      path = unique_db_path()

      Application.put_env(:shh_ai, :audit_mode, false)
      Application.put_env(:shh_ai, ShhAi.Repo, database: path, pool_size: 5, journal_mode: :wal)

      restart_app!()

      refute Config.audit_mode?()
      refute Process.whereis(ShhAi.Repo), "expected no Repo process with audit mode off"
      refute Process.whereis(ShhAi.Audit.Vault), "expected no Vault process with audit mode off"
      refute File.exists?(path), "expected no audit database file with audit mode off"
    end

    test "audit mode on: boot starts Repo and Vault against the audit database" do
      path = unique_db_path()

      Application.put_env(:shh_ai, :audit_mode, true)
      System.put_env("AUDIT_ENCRYPTION_KEY", Base.encode32(:crypto.strong_rand_bytes(32)))
      Application.put_env(:shh_ai, ShhAi.Repo, database: path, pool_size: 5, journal_mode: :wal)

      restart_app!()

      assert Config.audit_mode?()
      assert Process.whereis(ShhAi.Repo), "expected a Repo process with audit mode on"
      assert Process.whereis(ShhAi.Audit.Vault), "expected a Vault process with audit mode on"
      # The repo is lazily connected, so touch it to prove the datastore works.
      assert {:ok, _} = Ecto.Adapters.SQL.query(ShhAi.Repo, "SELECT 1", [])
      assert File.exists?(path), "expected the audit database file to be created"
    end

    defp restart_app! do
      _ = Application.stop(:shh_ai)
      :ok = Application.start(:shh_ai)
      :ok
    end

    defp unique_db_path do
      Path.join(
        System.tmp_dir!(),
        "shh_ai_boot_test_#{:erlang.unique_integer([:positive])}.db"
      )
    end

    defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
    defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
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

      # Ollama with http:// scheme
      System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
      System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://localhost:11434")

      Config.load()

      providers = Config.providers()
      assert length(providers) >= 3

      # Verify we have OpenAI, Anthropic, and Ollama providers
      provider_types = Enum.map(providers, fn {_, type, _} -> type end)
      assert :openai in provider_types
      assert :anthropic in provider_types
      assert :ollama in provider_types

      # Verify http:// scheme is handled (Ollama without explicit port)
      ollama_providers = Enum.filter(providers, fn {_, type, _} -> type == :ollama end)
      assert ollama_providers != []
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
  end
end
