defmodule ShhAi.ProviderClient.HeaderConformanceTest do
  @moduledoc """
  Header-conformance tests for the outbound allowlist (issue #55).

  Two seams:

    * `HTTPTransport.build_headers/3` — the pure function that decides which
      names reach a backend and which credential is attached.
    * `ProviderClient.request/6` — the end-to-end path, with a recording
      transport, proving a client-supplied `authorization`/`x-api-key` never
      reaches the backend while the configured per-backend key does.
  """

  use ExUnit.Case, async: false

  alias ShhAi.AuditCase
  alias ShhAi.Config
  alias ShhAi.ConversationCase
  alias ShhAi.PII.Patterns
  alias ShhAi.PII.SanitizationResult
  alias ShhAi.PIIPipeline
  alias ShhAi.ProviderClient
  alias ShhAi.ProviderClient.HTTPTransport

  @backend_key "backend-key"
  @gate_token "gate-key"
  @allowed ~w(authorization content-type accept x-api-key anthropic-version)

  setup do
    AuditCase.snapshot_env([
      "PROVIDER_OPENAI_1_ENABLED",
      "PROVIDER_OPENAI_1_API_KEY",
      "PROVIDER_OPENAI_1_BASE_URL",
      "PROXY_API_KEYS"
    ])

    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", @backend_key)
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", "http://localhost:9999/v1")
    System.put_env("PROXY_API_KEYS", @gate_token)
    Config.load()

    ConversationCase.setup_ets()
    Patterns.load_into_persistent_term()

    # Model-aware selection (#68) filters the configured pool through the
    # catalog, which is empty/stale in the test env, so it would reject every
    # model. Name only the instance this test configures: this test's intent
    # is the outbound header set, and a provider instance leaked into the env
    # by another test must not be selectable.
    :meck.new(ShhAi.ModelCatalog, [:passthrough, :no_link])

    :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn _model -> ["openai_1"] end)

    on_exit(fn ->
      if ShhAi.ModelCatalog in :meck.mocked(), do: :meck.unload(ShhAi.ModelCatalog)
    end)

    :ok
  end

  describe "HTTPTransport.build_headers/3" do
    test "drops client authorization/x-api-key/arbitrary headers for an OpenAI backend" do
      config = %{api_key: @backend_key, base_url: "http://x", timeout: 1_000}

      client_headers = [
        {"authorization", "Bearer #{@gate_token}"},
        {"x-api-key", "client-key"},
        {"x-custom", "custom-value"},
        {"cookie", "session=abc"},
        {"content-type", "application/json"}
      ]

      headers = HTTPTransport.build_headers(:openai, client_headers, config)

      assert {"authorization", "Bearer #{@backend_key}"} in headers

      names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)
      assert Enum.all?(names, &(&1 in @allowed))

      refute Enum.any?(headers, fn {_name, value} ->
               value in ["Bearer #{@gate_token}", "client-key", "custom-value", "session=abc"]
             end)
    end

    test "drops client headers and emits x-api-key + anthropic-version for an Anthropic backend" do
      config = %{api_key: @backend_key, base_url: "http://x", timeout: 1_000}

      client_headers = [
        {"authorization", "Bearer #{@gate_token}"},
        {"x-api-key", "client-key"},
        {"x-custom", "custom-value"}
      ]

      headers = HTTPTransport.build_headers(:anthropic, client_headers, config)

      assert {"x-api-key", @backend_key} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
      refute Enum.any?(headers, fn {name, _} -> String.downcase(name) == "authorization" end)

      refute Enum.any?(headers, fn {_name, value} ->
               value in ["Bearer #{@gate_token}", "client-key", "custom-value"]
             end)
    end

    test "deduplicates by lowercased name, first wins" do
      config = %{api_key: @backend_key, base_url: "http://x", timeout: 1_000}

      headers =
        HTTPTransport.build_headers(
          :openai,
          [{"Content-Type", "text/plain"}],
          config
        )

      assert Enum.filter(headers, fn {name, _} -> String.downcase(name) == "content-type" end) ==
               [{"content-type", "application/json"}]
    end
  end

  describe "ProviderClient.request/6" do
    test "the gate token and client headers never reach the backend; the configured key does" do
      test_pid = self()

      :meck.new(HTTPTransport, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(HTTPTransport, :do_request, fn _method, _url, _body, headers, _timeout ->
        send(test_pid, {:outbound_headers, headers})

        {:ok,
         %Req.Response{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: %{
             "id" => "chatcmpl-test",
             "object" => "chat.completion",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{"role" => "assistant", "content" => "Hello!"},
                 "finish_reason" => "stop"
               }
             ]
           }
         }}
      end)

      with_mocked_pii(fn ->
        client_headers = [
          {"authorization", "Bearer #{@gate_token}"},
          {"x-api-key", "client-key"},
          {"x-custom", "custom-value"}
        ]

        body = %{"model" => "gpt-4", "messages" => [%{"role" => "user", "content" => "Hi"}]}

        _ = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, client_headers)

        assert_receive {:outbound_headers, headers}, 5_000

        assert {"authorization", "Bearer #{@backend_key}"} in headers

        names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)
        assert Enum.all?(names, &(&1 in @allowed))

        refute Enum.any?(headers, fn {_name, value} ->
                 value in ["Bearer #{@gate_token}", "client-key", "custom-value"]
               end)
      end)
    end
  end

  # Run a test function with the PII pipeline mocked out — mirrors the helper
  # in provider_client_test.exs so this end-to-end path stays fast.
  defp with_mocked_pii(fun) do
    :meck.new(PIIPipeline, [:passthrough])

    :meck.expect(PIIPipeline, :sanitize_openai_request, fn body, _conversation, _opts ->
      messages = body["messages"] || body["input"] || [body]

      {:ok,
       %SanitizationResult{
         sanitized_messages: messages,
         mapping: %{},
         reverse_index: %{},
         detection_counts: {0, 0},
         pii_info: %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}
       }}
    end)

    :meck.expect(PIIPipeline, :restore_openai_response, fn response, _conversation, _opts ->
      {:ok, response}
    end)

    try do
      fun.()
    after
      :meck.unload(PIIPipeline)
    end
  end
end
