defmodule ShhAi.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias ShhAi.AuditCase
  alias ShhAi.Config
  alias ShhAi.ModelCatalog
  alias ShhAi.ProviderClient.HTTPTransport

  # Every provider-instance variable, not just the ones these tests set:
  # sibling test files enable `PROVIDER_*_2_*` without restoring it, and a
  # stray enabled instance would otherwise be probed by `refresh/1`.
  @provider_env (for provider <- ~w(OPENAI ANTHROPIC OLLAMA),
                     index <- 1..4,
                     suffix <- ~w(ENABLED API_KEY BASE_URL) do
                   "PROVIDER_#{provider}_#{index}_#{suffix}"
                 end)

  setup do
    AuditCase.snapshot_env(@provider_env)
    original_interval = Application.get_env(:shh_ai, :model_catalog_refresh_interval)

    on_exit(fn ->
      case original_interval do
        nil -> Application.delete_env(:shh_ai, :model_catalog_refresh_interval)
        value -> Application.put_env(:shh_ai, :model_catalog_refresh_interval, value)
      end

      Config.load()
    end)

    for key <- @provider_env, do: System.delete_env(key)

    # Each test that reads the cache refreshes it first, so the singleton's
    # row is always this test's own result.

    original_http_client = Application.get_env(:shh_ai, :http_client)
    Application.put_env(:shh_ai, :http_client, HTTPTransport)

    on_exit(fn ->
      case original_http_client do
        nil -> Application.delete_env(:shh_ai, :http_client)
        module -> Application.put_env(:shh_ai, :http_client, module)
      end
    end)

    :meck.new(HTTPTransport, [:passthrough])
    on_exit(fn -> :meck.unload() end)

    :ok
  end

  defp configure_openai(base_url, opts \\ []) do
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", base_url)
    System.put_env("PROVIDER_OPENAI_1_API_KEY", Keyword.get(opts, :api_key, "sk-test"))
  end

  defp configure_ollama(base_url) do
    System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
    System.put_env("PROVIDER_OLLAMA_1_BASE_URL", base_url)
  end

  # Routes each probe by the URL the catalog builds, so the test does not
  # re-implement URL joining. Returns the `{:ok, res} | {:error, reason}`
  # shape `do_request/5` produces.
  defp expect_probes(response_for_url) do
    :meck.expect(HTTPTransport, :do_request, fn _method, url, _body, _headers, _timeout ->
      response_for_url.(url)
    end)
  end

  defp listing_ok(body) do
    {:ok, %Req.Response{status: 200, headers: [], body: body}}
  end

  defp openai_model(id) do
    %{"id" => id, "object" => "model", "created" => 1_700_000_000, "owned_by" => "openai"}
  end

  describe "refresh/1" do
    test "aggregates the de-duplicated union of every provider instance's models" do
      configure_openai("https://openai.test")
      configure_ollama("http://ollama.test:11434")
      Config.load()

      expect_probes(fn url ->
        cond do
          String.contains?(url, "/api/tags") ->
            listing_ok(%{
              "models" => [
                %{"name" => "llama3", "modified_at" => "2024-01-01T00:00:00Z", "size" => 0},
                %{"name" => "gpt-4o", "modified_at" => "2024-01-01T00:00:00Z", "size" => 0}
              ]
            })

          String.contains?(url, "/models") ->
            listing_ok(%{
              "object" => "list",
              "data" => [openai_model("gpt-4o"), openai_model("o3")]
            })
        end
      end)

      assert :ok = ModelCatalog.refresh()

      assert Enum.map(ModelCatalog.models(), & &1["id"]) == ["gpt-4o", "llama3", "o3"]
    end

    test "records every provider instance that serves a model" do
      configure_openai("https://openai.test")
      configure_ollama("http://ollama.test:11434")
      Config.load()

      expect_probes(fn url ->
        if String.contains?(url, "/api/tags") do
          listing_ok(%{"models" => [%{"name" => "gpt-4o", "size" => 0}]})
        else
          listing_ok(%{"object" => "list", "data" => [openai_model("gpt-4o")]})
        end
      end)

      ModelCatalog.refresh()

      assert ModelCatalog.provider_instances_serving("gpt-4o") == ["openai_1", "ollama_1"]
      assert ModelCatalog.provider_instances_serving("unknown-model") == []
    end

    test "excludes a provider instance whose probe fails, without breaking the listing" do
      configure_openai("https://openai.test")
      configure_ollama("http://ollama.test:11434")
      Config.load()

      expect_probes(fn url ->
        if String.contains?(url, "/api/tags") do
          {:error, :econnrefused}
        else
          listing_ok(%{"object" => "list", "data" => [openai_model("gpt-4o")]})
        end
      end)

      assert :ok = ModelCatalog.refresh()

      assert Enum.map(ModelCatalog.models(), & &1["id"]) == ["gpt-4o"]
      assert ModelCatalog.provider_instances_serving("llama3") == []
    end

    test "normalises every dialect into the canonical OpenAI listing shape" do
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_BASE_URL", "https://anthropic.test")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "sk-ant")
      Config.load()

      expect_probes(fn _url ->
        listing_ok(%{
          "data" => [
            %{
              "id" => "claude-sonnet-4-20250514",
              "type" => "model",
              "display_name" => "Claude Sonnet 4",
              "created_at" => "2025-05-14T00:00:00Z"
            }
          ],
          "has_more" => false,
          "first_id" => "claude-sonnet-4-20250514",
          "last_id" => "claude-sonnet-4-20250514"
        })
      end)

      ModelCatalog.refresh()

      assert [%{"id" => "claude-sonnet-4-20250514"} = model] = ModelCatalog.models()
      assert model["object"] == "model"
      assert model["created"] == 1_747_180_800

      assert ModelCatalog.provider_instances_serving("claude-sonnet-4-20250514") == [
               "anthropic_1"
             ]
    end

    test "an empty deployment yields an empty catalog" do
      Config.load()

      assert :ok = ModelCatalog.refresh()
      assert ModelCatalog.models() == []
      assert ModelCatalog.listing() == %{"object" => "list", "data" => []}
    end
  end

  describe "listing/0" do
    test "is the canonical OpenAI listing body for the aggregated catalog" do
      configure_openai("https://openai.test")
      Config.load()

      expect_probes(fn _url ->
        listing_ok(%{"object" => "list", "data" => [openai_model("gpt-4o")]})
      end)

      ModelCatalog.refresh()

      assert ModelCatalog.listing() == %{
               "object" => "list",
               "data" => [openai_model("gpt-4o")]
             }
    end
  end

  describe "reads" do
    test "are served from the table, not from the refresher's mailbox" do
      configure_openai("https://openai.test")
      Config.load()

      expect_probes(fn _url ->
        listing_ok(%{"object" => "list", "data" => [openai_model("gpt-4o")]})
      end)

      ModelCatalog.refresh()

      test_pid = self()

      expect_probes(fn _url ->
        send(test_pid, {:probing, self()})

        receive do
          :release -> listing_ok(%{"object" => "list", "data" => []})
        end
      end)

      probe_pid = start_supervised!({ModelCatalog, name: nil, table: :model_catalog_reads_test})
      assert_receive {:probing, ^probe_pid}, 1_000

      # The refresher is holding its mailbox mid-probe; the read still returns
      # the published catalog.
      assert Enum.map(ModelCatalog.models(), & &1["id"]) == ["gpt-4o"]

      send(probe_pid, :release)
    end

    test "degrade to the empty catalog when no refresh has published one" do
      :ets.delete(ModelCatalog.Table, :snapshot)

      assert ModelCatalog.models() == []
      assert ModelCatalog.listing() == %{"object" => "list", "data" => []}
      assert ModelCatalog.provider_instances_serving("gpt-4o") == []
    end
  end

  describe "the refresher process" do
    test "boot does not block on a probe" do
      configure_openai("https://openai.test")
      Config.load()

      test_pid = self()

      expect_probes(fn _url ->
        send(test_pid, {:probe_started, self()})

        receive do
          :release -> :ok
        end

        listing_ok(%{"object" => "list", "data" => []})
      end)

      # Starting the refresher returns as soon as its `init/1` does; the probe
      # runs afterwards, off the boot path. `name: nil` starts an unregistered
      # instance and `:table` gives it a cache of its own, since the
      # application already supervises the singleton.
      pid = start_supervised!({ModelCatalog, name: nil, table: :model_catalog_boot_test})
      assert_receive {:probe_started, probe_pid}, 1_000
      assert probe_pid == pid

      send(probe_pid, :release)
    end

    test "re-probes on the configured interval" do
      configure_openai("https://openai.test")
      Application.put_env(:shh_ai, :model_catalog_refresh_interval, 25)
      Config.load()

      test_pid = self()

      expect_probes(fn _url ->
        send(test_pid, {:probed, self()})
        listing_ok(%{"object" => "list", "data" => []})
      end)

      pid = start_supervised!({ModelCatalog, name: nil, table: :model_catalog_interval_test})

      assert_receive {:probed, ^pid}, 1_000
      assert_receive {:probed, ^pid}, 1_000
    end

    test ":disabled keeps the periodic refresh off but still probes at boot" do
      configure_openai("https://openai.test")
      Application.put_env(:shh_ai, :model_catalog_refresh_interval, :disabled)
      Config.load()

      test_pid = self()

      expect_probes(fn _url ->
        send(test_pid, {:probed, self()})
        listing_ok(%{"object" => "list", "data" => []})
      end)

      pid = start_supervised!({ModelCatalog, name: nil, table: :model_catalog_disabled_test})

      assert_receive {:probed, ^pid}, 1_000
      refute_receive {:probed, ^pid}, 150
    end
  end
end
