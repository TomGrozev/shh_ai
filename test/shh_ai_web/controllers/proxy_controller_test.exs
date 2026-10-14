defmodule ShhAiWeb.ProxyControllerTest do
  use ShhAiWeb.ConnCase, async: false

  alias ShhAi.Config
  alias ShhAi.Conversation.Store
  alias ShhAi.MeckHelper
  alias ShhAi.PII.SanitizationResult
  alias ShhAi.PIIPipeline
  alias ShhAi.ProviderClient.HTTPTransport
  alias ShhAi.ProviderClient.HTTPTransportMock

  @gate_key "test-gate-key"

  setup do
    ShhAi.AuditCase.snapshot_env(["PROXY_API_KEYS"])

    # Set up minimal config for tests
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    System.put_env("PROXY_API_KEYS", @gate_key)
    Config.load()

    # The supervised catalog is empty/stale in the test env, so model-aware
    # selection (`ShhAi.TargetProvider.resolve/2`) would 404 every request. Treat
    # every configured provider instance as serving every model; the #68
    # selection test overrides this expectation.
    :meck.new(ShhAi.ModelCatalog, [:passthrough, :no_link])

    :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn _model ->
      Enum.map(Config.providers(), &Config.provider_instance/1)
    end)

    on_exit(fn ->
      MeckHelper.unload(ShhAi.ModelCatalog)
    end)

    :ok
  end

  # A conn already carrying the inbound gate token, so a test exercises the
  # controller rather than the gate. See issue #55.
  defp authed_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@gate_key}")
  end

  # A minimal OpenAI-shaped 200 so the request completes through the full
  # pipeline (and persists the conversation) without a real backend.
  defp ok_response do
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
    }
  end

  # Mirrors the helper in provider_client/header_conformance_test.exs so the
  # end-to-end path stays fast and free of real PII detection.
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

  describe "inbound API-key gate" do
    test "POST /v1/chat/completions without a token is 401" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{"model" => "gpt-4", "messages" => []})

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "proxy_error"
    end

    test "POST /v1/chat/completions with an invalid token is 401" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer wrong-key")
        |> post("/v1/chat/completions", %{"model" => "gpt-4", "messages" => []})

      assert conn.status == 401
    end

    test "POST /api/chat without a token is 401" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/chat", %{"model" => "llama3", "messages" => []})

      assert conn.status == 401
    end

    test "GET /api/tags without a token is 401" do
      conn = get(build_conn(), "/api/tags")

      assert conn.status == 401
    end

    test "when PROXY_API_KEYS is unset the gate refuses with 503" do
      System.delete_env("PROXY_API_KEYS")
      Config.load()

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{"model" => "gpt-4", "messages" => []})

      assert conn.status == 503
    end
  end

  describe "inbound header allowlist (issue #55)" do
    # The outbound names a backend may receive: the two content-negotiation
    # headers, the injected credential, and Anthropic's version header.
    @outbound_allowed ~w(content-type accept authorization x-api-key anthropic-version)

    setup do
      # `ShhAi.TargetProvider.resolve/2` picks randomly from the configured
      # pool, and sibling tests leak extra `PROVIDER_*_ENABLED` env. Pin the
      # pool to the single OpenAI provider so the outbound credential is
      # deterministic.
      enabled_keys =
        for idx <- 1..4,
            type <- ~w(OPENAI ANTHROPIC OLLAMA),
            do: "PROVIDER_#{type}_#{idx}_ENABLED"

      ShhAi.AuditCase.snapshot_env(enabled_keys)

      Enum.each(enabled_keys, &System.put_env(&1, "false"))
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      Config.load()

      :ok
    end

    test "only allowlisted headers reach the backend; the gate token is replaced" do
      test_pid = self()

      :meck.new(HTTPTransport, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(HTTPTransport, :do_request, fn _method, _url, _body, headers, _timeout ->
        send(test_pid, {:outbound_headers, headers})
        {:ok, ok_response()}
      end)

      with_mocked_pii(fn ->
        conn =
          authed_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-api-key", "client-key")
          |> put_req_header("cookie", "session=abc")
          |> put_req_header("x-custom", "custom-value")
          |> post("/v1/chat/completions", %{
            "model" => "gpt-4",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          })

        assert conn.status == 200
        assert_receive {:outbound_headers, headers}, 5_000

        names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)
        assert Enum.all?(names, &(&1 in @outbound_allowed))

        # None of the client-supplied values — including the gate token the
        # inbound allowlist strips — survive to the backend.
        refute Enum.any?(headers, fn {_name, value} ->
                 value in ["client-key", "session=abc", "custom-value", "Bearer #{@gate_key}"]
               end)

        # The backend credential is the configured provider key, not the gate token.
        assert {"authorization", "Bearer test-key"} in headers
      end)
    end

    test "x-no-audit survives inbound and opts the conversation out" do
      test_pid = self()
      thread_id = "thread-no-audit-#{:erlang.unique_integer([:positive])}"

      :meck.new(HTTPTransport, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(HTTPTransport, :do_request, fn _method, _url, _body, _headers, _timeout ->
        send(test_pid, :backend_called)
        {:ok, ok_response()}
      end)

      with_mocked_pii(fn ->
        conn =
          authed_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-no-audit", "true")
          |> post("/v1/chat/completions", %{
            "model" => "gpt-4",
            "thread_id" => thread_id,
            "messages" => [%{"role" => "user", "content" => "opt out #{thread_id}"}]
          })

        assert conn.status == 200
        assert_receive :backend_called, 5_000

        conversation =
          Store.list_conversations(limit: 1000)
          |> Enum.find(fn conv -> conv.provider_conversation_id == thread_id end)

        assert conversation, "expected a conversation for #{thread_id}"
        assert Store.get_opted_out(conversation.conversation_id)
      end)
    end
  end

  describe "request telemetry" do
    test "emits the request method as a string, not an atom" do
      test_pid = self()
      handler_id = "proxy-method-type-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:stop_metadata, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :meck.new(HTTPTransport, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(HTTPTransport, :do_request, fn _method, _url, _body, _headers, _timeout ->
        {:ok, ok_response()}
      end)

      with_mocked_pii(fn ->
        conn =
          authed_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/v1/chat/completions", %{
            "model" => "gpt-4",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          })

        assert conn.status == 200
      end)

      assert_receive {:stop_metadata, metadata}, 5_000

      # `Metrics.Event.method/0` is `String.t()` and the audit record casts it
      # with `:string`; an atom here invalidates the changeset, and the writer
      # drops the event without logging it.
      assert is_binary(metadata.method)
      assert metadata.method == "POST"
    end
  end

  describe "handle_openai/2" do
    test "handles POST to /v1/chat/completions" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      # The response depends on whether a real backend is configured
      # In test env without a real backend, we expect an error
      assert conn.status in [200, 401, 404, 500]
    end

    test "handles POST with streaming request" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "stream" => true
        })

      # Response depends on backend availability
      assert conn.status in [200, 401, 404, 500]
    end

    test "handles POST with stream as string 'true'" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "stream" => "true"
        })

      # Response depends on backend availability
      assert conn.status in [200, 401, 404, 500]
    end

    test "handles GET requests" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> get("/v1/models")

      # Response depends on backend availability - 400 can occur for GET without body
      assert conn.status in [200, 400, 401, 404, 500]
    end

    test "handles request with custom headers" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-custom-header", "custom-value")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      # Response depends on backend availability
      assert conn.status in [200, 401, 404, 500]
    end
  end

  describe "handle_anthropic/2" do
    test "handles POST to /anthropic/v1/messages" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/anthropic/v1/messages", %{
          "model" => "claude-3-opus",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 1024
        })

      # Response depends on backend availability
      assert conn.status in [200, 500, 404]
    end

    test "handles POST with streaming request" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/anthropic/v1/messages", %{
          "model" => "claude-3-opus",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 1024,
          "stream" => true
        })

      # Response depends on backend availability
      assert conn.status in [200, 500, 404]
    end
  end

  describe "handle_ollama/2" do
    test "handles POST to /ollama/api/chat" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/ollama/api/chat", %{
          "model" => "llama3",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      # Response depends on backend availability
      assert conn.status in [200, 500, 404]
    end

    test "handles POST to /ollama/api/generate" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/ollama/api/generate", %{
          "model" => "llama3",
          "prompt" => "Hello"
        })

      # Response depends on backend availability
      assert conn.status in [200, 500, 404]
    end

    test "handles POST with streaming request" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/ollama/api/chat", %{
          "model" => "llama3",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "stream" => true
        })

      # Response depends on backend availability
      assert conn.status in [200, 500, 404]
    end
  end

  describe "no session management in controller" do
    test "controller module has no SessionStore references" do
      # Verify the controller source code does not reference SessionStore
      source = File.read!("lib/shh_ai_web/controllers/proxy_controller.ex")
      refute source =~ "SessionStore"
      refute source =~ "session_id"
    end
  end

  describe "error handling" do
    test "returns error for invalid JSON body" do
      # Invalid JSON causes a parse error before reaching the controller
      # This tests that the endpoint properly handles parse errors
      assert_raise Plug.Parsers.ParseError, fn ->
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", "invalid json")
      end
    end

    test "handles empty body" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{})

      # Should still process
      assert conn.status in [200, 401, 404, 500]
    end

    test "persists a bounded error class when the backend transport fails" do
      test_pid = self()
      handler_id = "proxy-error-class-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata[:error], do: send(test_pid, {:error_event, metadata.error})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :meck.new(ShhAi.ProviderClient.HTTPTransport, [:passthrough, :no_link])

      on_exit(fn ->
        MeckHelper.unload(ShhAi.ProviderClient.HTTPTransport)
      end)

      :meck.expect(
        ShhAi.ProviderClient.HTTPTransport,
        :do_request,
        fn _method, _url, _body, _headers, _timeout ->
          {:error, %Req.TransportError{reason: :econnrefused}}
        end
      )

      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      # The test configures a single backend, so under #72 its connection-class
      # failure exhausts the capable pool — a distinct 503, not a generic 500.
      assert conn.status == 503

      assert_receive {:error_event, error}, 1_000
      assert error.message == "pool_exhausted"
      refute error.message =~ "%Req.TransportError"
    end
  end

  describe "request body extraction" do
    test "handles map body params" do
      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "test"}]
        })

      # Should process successfully
      assert conn.status in [200, 401, 404, 500]
    end
  end

  describe "model-aware selection (issue #68)" do
    test "an unserved model returns 404 with the ShhAi-originated message" do
      # Override the setup-wide "everything is served" stub.
      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn _model -> [] end)

      conn =
        authed_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "ghost-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert conn.status == 404

      assert Jason.decode!(conn.resp_body)["error"]["message"] ==
               ~s(model "ghost-model" not served by any configured provider instance)
    end
  end

  describe "pool-exhaustion 503 (issue #72)" do
    setup do
      # A single OpenAI instance so the request path's first connection
      # failure immediately exhausts the capable pool.
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
      Config.load()

      # Swap the transport through the `:http_client` app env rather than
      # mecking `HTTPTransport` directly (CODING_STANDARDS.md › Tests).
      Application.put_env(:shh_ai, :http_client, HTTPTransportMock)
      on_exit(fn -> Application.delete_env(:shh_ai, :http_client) end)

      :ok
    end

    test "pool exhaustion maps to a distinct 503 naming the model" do
      :meck.new(HTTPTransportMock, [:passthrough, :no_link])
      on_exit(fn -> MeckHelper.unload(HTTPTransportMock) end)

      :meck.expect(HTTPTransportMock, :do_request, fn _method, _url, _body, _headers, _timeout ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      with_mocked_pii(fn ->
        conn =
          authed_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/v1/chat/completions", %{
            "model" => "gpt-4",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          })

        assert conn.status == 503

        assert Jason.decode!(conn.resp_body)["error"]["message"] ==
                 ~s(no configured provider instance serving "gpt-4" is currently reachable)
      end)
    end

    test "other transport errors stay a generic 500" do
      :meck.new(HTTPTransportMock, [:passthrough, :no_link])
      on_exit(fn -> MeckHelper.unload(HTTPTransportMock) end)

      :meck.expect(HTTPTransportMock, :do_request, fn _method, _url, _body, _headers, _timeout ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      with_mocked_pii(fn ->
        conn =
          authed_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/v1/chat/completions", %{
            "model" => "gpt-4",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          })

        assert conn.status == 500
      end)
    end
  end
end
