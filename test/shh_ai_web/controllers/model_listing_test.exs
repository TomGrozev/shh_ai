defmodule ShhAiWeb.ModelListingTest do
  use ShhAiWeb.ConnCase, async: false

  alias ShhAi.AuditCase
  alias ShhAi.Config
  alias ShhAi.ModelCatalog
  alias ShhAi.ProviderClient.HTTPTransport

  # Every provider-instance variable, not just the ones these tests set:
  # sibling test files enable `PROVIDER_*_2_*` without restoring it, and a
  # stray enabled instance would otherwise be probed by `refresh/0`.
  @provider_env (for provider <- ~w(OPENAI ANTHROPIC OLLAMA),
                     index <- 1..4,
                     suffix <- ~w(ENABLED API_KEY BASE_URL) do
                   "PROVIDER_#{provider}_#{index}_#{suffix}"
                 end)

  setup do
    AuditCase.snapshot_env(@provider_env)
    for key <- @provider_env, do: System.delete_env(key)

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

  # Probes one OpenAI-dialect and one Ollama-dialect instance, then leaves the
  # aggregated catalog cached — exactly what application boot does.
  defp prime_catalog do
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", "https://openai.test")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "sk-test")
    System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
    System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://ollama.test:11434")
    Config.load()

    :meck.expect(HTTPTransport, :do_request, fn _method, url, _body, _headers, _timeout ->
      if String.contains?(url, "/api/tags") do
        {:ok,
         %Req.Response{
           status: 200,
           headers: [],
           body: %{"models" => [%{"name" => "llama3", "size" => 0}]}
         }}
      else
        {:ok,
         %Req.Response{
           status: 200,
           headers: [],
           body: %{"object" => "list", "data" => [openai_model("gpt-4o")]}
         }}
      end
    end)

    :ok = ModelCatalog.refresh()
  end

  defp openai_model(id) do
    %{"id" => id, "object" => "model", "created" => 1_700_000_000, "owned_by" => "openai"}
  end

  defp json_body(conn) do
    assert conn.status == 200

    assert {"content-type", "application/json" <> _} =
             List.keyfind(conn.resp_headers, "content-type", 0)

    Jason.decode!(conn.resp_body)
  end

  test "GET /v1/models renders the cached union in the OpenAI dialect" do
    prime_catalog()

    body = json_body(get(build_conn(), "/v1/models"))

    assert body["object"] == "list"
    assert Enum.map(body["data"], & &1["id"]) == ["gpt-4o", "llama3"]
    assert Enum.all?(body["data"], &(&1["object"] == "model"))
  end

  test "GET /api/tags renders the cached union in the Ollama dialect" do
    prime_catalog()

    body = json_body(get(build_conn(), "/api/tags"))

    assert Enum.map(body["models"], & &1["name"]) == ["gpt-4o", "llama3"]
  end

  test "both listings are served entirely from cache, with no per-request probe" do
    prime_catalog()

    :meck.expect(HTTPTransport, :do_request, fn _method, url, _body, _headers, _timeout ->
      flunk("model listing reached a provider instance: #{url}")
    end)

    assert get(build_conn(), "/v1/models").status == 200
    assert get(build_conn(), "/api/tags").status == 200
  end

  test "an empty catalog renders an empty listing in the caller's dialect" do
    Config.load()
    :ok = ModelCatalog.refresh()

    assert json_body(get(build_conn(), "/v1/models")) == %{"object" => "list", "data" => []}
    assert json_body(get(build_conn(), "/api/tags")) == %{"models" => []}
  end
end
