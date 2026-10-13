defmodule ShhAi.TargetProviderTest do
  use ExUnit.Case, async: false

  alias ShhAi.{Config, Conversation, TargetProvider}

  setup do
    ShhAi.AuditCase.snapshot_env([
      "PROVIDER_OPENAI_1_ENABLED",
      "PROVIDER_OPENAI_1_API_KEY",
      "PROVIDER_OPENAI_2_ENABLED",
      "PROVIDER_OPENAI_2_API_KEY",
      "PROVIDER_OPENAI_2_BASE_URL"
    ])

    # Selection filters the configured pool through the catalog's probe
    # results, which are gathered over the network in production. Stub the
    # lookup so the tests stay deterministic and never probe a backend.
    # :no_link keeps the mock alive past the test process exit so the
    # on_exit unload below is deterministic (without it, meck auto-unloads
    # the mock when its owning process dies and the on_exit unload raises).
    :meck.new(ShhAi.ModelCatalog, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(ShhAi.ModelCatalog) end)

    :ok
  end

  describe "resolve/2 with a model" do
    test "picks a configured provider that serves the model" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      Config.load()

      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn
        "gpt-4" -> ["openai_1"]
      end)

      assert {:ok, {1, :openai, config}} =
               TargetProvider.resolve(%Conversation{}, %{"model" => "gpt-4"})

      assert config.base_url == "https://api.openai.com/v1"
    end

    test "only picks among the instances the catalog reports as serving the model" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-2")
      Config.load()

      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn
        "gpt-4" -> ["openai_2"]
      end)

      assert {:ok, {2, :openai, config}} =
               TargetProvider.resolve(%Conversation{}, %{"model" => "gpt-4"})

      assert config.api_key == "key-2"
    end

    test "returns {:error, {:model_not_served, model}} when no instance serves it" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      Config.load()

      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn _model -> [] end)

      assert TargetProvider.resolve(%Conversation{}, %{"model" => "ghost-model"}) ==
               {:error, {:model_not_served, "ghost-model"}}
    end
  end

  describe "resolve/2 with a pinned provider" do
    test "returns the configured provider carrying that instance name" do
      System.delete_env("PROVIDER_OPENAI_1_ENABLED")
      System.delete_env("PROVIDER_OPENAI_1_API_KEY")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "test-key")
      Config.load()

      assert {:ok, {2, :openai, config}} =
               TargetProvider.resolve(
                 %Conversation{pinned_provider: "openai_2"},
                 %{"model" => "gpt-4"}
               )

      assert config.api_key == "test-key"
    end

    test "re-selects a capable instance when the pinned instance name is not configured" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-2")
      Config.load()

      # Two configured instances besides the stale pin, and only openai_2
      # serves the model — so a model-less or blind random fallback would
      # sometimes pick the incapable openai_1 and fail.
      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn
        "gpt-4" -> ["openai_2"]
      end)

      assert {:ok, {2, :openai, config}} =
               TargetProvider.resolve(
                 %Conversation{pinned_provider: "openai_9"},
                 %{"model" => "gpt-4"}
               )

      assert config.api_key == "key-2"
    end
  end

  describe "resolve/2 without a model" do
    test "returns a configured provider instance" do
      # Configure only openai_1 so the choice is deterministic; other tests
      # (e.g. application_test's pool_config test) can leave PROVIDER_OPENAI_2_*
      # in the environment.
      System.delete_env("PROVIDER_OPENAI_2_ENABLED")
      System.delete_env("PROVIDER_OPENAI_2_API_KEY")
      System.delete_env("PROVIDER_OPENAI_2_BASE_URL")
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      Config.load()

      assert {:ok, {1, :openai, config}} = TargetProvider.resolve(%Conversation{}, %{})
      assert config.api_key == "test-key"
    end
  end

  describe "resolve_alternate/2 (issue #72 retry fallback)" do
    test "picks only among the capable pool minus the already-tried instances" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-2")
      Config.load()

      # openai_3 serves the model but openai_2 does not, so excluding the
      # tried openai_1 must land on openai_3, never on the incapable openai_2.
      System.put_env("PROVIDER_OPENAI_3_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_3_API_KEY", "key-3")
      Config.load()

      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn
        "fb-model" -> ["openai_1", "openai_3"]
      end)

      assert {:ok, {3, :openai, config}} =
               TargetProvider.resolve_alternate(%{"model" => "fb-model"}, ["openai_1"])

      assert config.api_key == "key-3"
    end

    test "returns {:error, {:pool_exhausted, model}} when every capable instance was tried" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      Config.load()

      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn _model -> ["openai_1"] end)

      assert {:error, {:pool_exhausted, "fb-model"}} =
               TargetProvider.resolve_alternate(%{"model" => "fb-model"}, ["openai_1"])
    end

    test "a model-less request falls back across the whole configured pool" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-1")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-2")
      Config.load()

      assert {:ok, {2, :openai, _config}} =
               TargetProvider.resolve_alternate(%{}, ["openai_1"])
    end
  end
end
