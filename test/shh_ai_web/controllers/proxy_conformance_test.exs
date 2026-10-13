defmodule ShhAiWeb.ProxyConformanceTest do
  @moduledoc """
  Dialect endpoint-conformance tests for the two supported proxy surfaces
  (issue #69; parent spec #58):

    * Anthropic dialect — `POST /v1/messages` — covers **Claude Code**.
    * OpenAI dialect — `POST /v1/chat/completions` — covers **opencode**,
      **OpenWebUI**, **Cline**, **Aider**, **Continue** and **Zed**.

  The tests are organised **by endpoint** and assert exactly what those
  dialects put on the wire — messages/chat-completions shapes, `tools`,
  `tool_use`/`tool_result`, `tool_choice`, and streaming — against a stubbed
  backend via the `HTTPTransportMock` transport seam (`Application.put_env`,
  zero new deps). The dialect converters themselves are round-tripped in
  `test/shh_ai/api_converter/`; here we prove the controller path converts,
  sanitises and returns dialect-correct responses.

  Compatibility is proven at the dialect level with **no per-harness runtime
  code**: adding a new OpenAI-compatible harness is a `docs/integrations.md`
  change only. See that doc for each harness's base-URL configuration.
  """

  use ShhAiWeb.ConnCase, async: false

  alias ShhAi.Config

  @gate_key "conformance-gate-key"

  setup do
    ShhAi.AuditCase.snapshot_env([
      "PROVIDER_OPENAI_1_ENABLED",
      "PROVIDER_OPENAI_1_API_KEY",
      "PROVIDER_OPENAI_1_BASE_URL",
      "PROVIDER_ANTHROPIC_1_ENABLED",
      "PROVIDER_ANTHROPIC_1_API_KEY",
      "PROVIDER_ANTHROPIC_1_BASE_URL",
      "PROXY_API_KEYS"
    ])

    # One OpenAI and one Anthropic provider instance, so both dialects can be
    # routed to a backend of their own kind (native path, no cross-dialect
    # conversion) while the model-aware pool stays deterministic.
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "openai-backend-key")
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", "http://localhost:9999/v1")
    System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
    System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "anthropic-backend-key")
    System.put_env("PROVIDER_ANTHROPIC_1_BASE_URL", "http://anthropic-backend:9998/v1")
    System.put_env("PROXY_API_KEYS", @gate_key)
    Config.load()

    ShhAi.ConversationCase.setup_ets()

    # The supervised catalog is empty/stale in the test env. Serve each
    # model only from providers of its own dialect, so a request is routed
    # to a backend of its own kind (native path, no cross-dialect
    # conversion): Anthropic models ("claude*") to the :anthropic
    # instance(s), everything else to the :openai instance(s). The #68
    # selection tests cover resolution; here we keep the pool deterministic.
    :meck.new(ShhAi.ModelCatalog, [:passthrough, :no_link])

    :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn model ->
      dialect = if String.starts_with?(model, "claude"), do: :anthropic, else: :openai

      Config.providers()
      |> Enum.filter(fn {_idx, provider, _config} -> provider == dialect end)
      |> Enum.map(&Config.provider_instance/1)
    end)

    on_exit(fn ->
      if ShhAi.ModelCatalog in :meck.mocked(), do: :meck.unload(ShhAi.ModelCatalog)
    end)

    Application.put_env(:shh_ai, :http_client, ShhAi.ProviderClient.HTTPTransportMock)

    on_exit(fn ->
      Application.delete_env(:shh_ai, :http_client)

      if ShhAi.ProviderClient.HTTPTransportMock in :meck.mocked() do
        :meck.unload(ShhAi.ProviderClient.HTTPTransportMock)
      end
    end)

    :ok
  end

  # A conn carrying the inbound gate token: the tests below exercise the
  # dialect surface, not the gate (the gate has its own describe blocks).
  defp authed_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@gate_key}")
    |> put_req_header("content-type", "application/json")
  end

  # Record the outbound request for the test pid, then serve the canned
  # mock-transport response for the backend's target path. Also stubs the
  # streaming seam (`StreamTransport.do_stream/4`) so the `stream: true`
  # tests drive the real streaming pipeline without opening a socket.
  defp record_requests do
    test_pid = self()

    :meck.expect(
      ShhAi.ProviderClient.HTTPTransportMock,
      :do_request,
      fn _method, url, body, headers, _timeout ->
        send(test_pid, {:backend_request, url, body, headers})

        # The Anthropic backend is called at `/v1/messages`; the OpenAI
        # backend at `/v1/chat/completions`. Base URLs differ per instance,
        # so branch on the target path, not on the host.
        response =
          if String.ends_with?(url, "/v1/messages") do
            %{
              "id" => "msg_test",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "model" => "claude-3-opus",
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            }
          else
            %{
              "id" => "chatcmpl-test",
              "object" => "chat.completion",
              "created" => 1_700_000_000,
              "model" => "gpt-4",
              "choices" => [
                %{
                  "index" => 0,
                  "message" => %{"role" => "assistant", "content" => "Hello!"},
                  "finish_reason" => "stop"
                }
              ],
              "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
            }
          end

        {:ok,
         %Req.Response{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: response
         }}
      end
    )

    # The streaming path bypasses HTTPTransportMock and calls
    # StreamTransport.do_stream/4, which would open a real socket. Stub it
    # with the passthrough mock so build_stream_request/3 (the real `into:`
    # wiring) still runs and we feed dialect-correct SSE frames straight
    # through StreamHandler.handle_chunk/2.
    :meck.new(ShhAi.ProviderClient.StreamTransport, [:passthrough, :no_link])

    :meck.expect(
      ShhAi.ProviderClient.StreamTransport,
      :do_stream,
      fn request, handle, _backend_start, _conversation_id ->
        Enum.each(stream_frames(request.url.path), fn chunk ->
          request.into.({:data, chunk}, {request, Req.Response.new(status: 200)})
        end)

        final_handle =
          Process.get({ShhAi.ProviderClient.StreamTransport, :handle}) || handle

        Process.delete({ShhAi.ProviderClient.StreamTransport, :handle})
        Process.delete({ShhAi.ProviderClient.StreamTransport, :backend_start})

        {:ok, final_handle, %Req.Response{status: 200}}
      end
    )

    on_exit(fn ->
      if ShhAi.ProviderClient.StreamTransport in :meck.mocked() do
        :meck.unload(ShhAi.ProviderClient.StreamTransport)
      end
    end)

    test_pid
  end

  # The SSE frames a backend of each target dialect emits, as consumed by
  # `StreamHandler.handle_chunk/2`. The Anthropic backend is driven with the
  # OpenAI-canonical frames its converter consumes (the Anthropic converter
  # normalises through the OpenAI view), ending in the `[DONE]` terminator
  # that closes the stream; the OpenAI backend emits the same shape.
  defp stream_frames("/v1/messages") do
    [
      ~s(data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{"content":"Hello!"}}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"end_turn"}]}\n\n),
      "data: [DONE]\n\n"
    ]
  end

  defp stream_frames(_path) do
    [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"Hello!"}}]}\n\n),
      "data: [DONE]\n\n"
    ]
  end

  defp apply_auth(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  # ---------------------------------------------------------------------------
  # Anthropic dialect — POST /v1/messages (Claude Code)
  # ---------------------------------------------------------------------------

  describe "POST /v1/messages (Anthropic dialect: Claude Code)" do
    test "messages shape round-trips: system string + structured list in, content blocks out" do
      test_pid = record_requests()

      conn =
        authed_conn()
        |> post("/v1/messages", %{
          "model" => "claude-3-opus",
          "max_tokens" => 1024,
          "system" => "You are a helpful assistant.",
          "messages" => [
            %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}
          ]
        })

      assert conn.status == 200

      assert_received {:backend_request, url, body, headers}
      assert url =~ "anthropic"
      assert url =~ "/v1/messages"

      # The wire body reaching the Anthropic backend is Anthropic-shaped.
      assert body["model"] == "claude-3-opus"
      assert body["max_tokens"] == 1024
      assert body["system"] == "You are a helpful assistant."

      assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}] =
               body["messages"]

      # Outbound auth is the configured backend key, never the gate token.
      assert {"x-api-key", "anthropic-backend-key"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers

      refute Enum.any?(headers, fn {name, value} ->
               name == "authorization" or value == @gate_key
             end)

      # And the client-visible response is Anthropic-shaped content blocks.
      response = Jason.decode!(conn.resp_body)
      assert response["type"] == "message"
      assert response["role"] == "assistant"
      assert [%{"type" => "text", "text" => "Hello!"}] = response["content"]
      assert response["stop_reason"] == "end_turn"
    end

    test "tools: Anthropic tool definitions convert to backend tool_use round-trip" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/messages", %{
          "model" => "claude-3-opus",
          "max_tokens" => 1024,
          "tools" => [
            %{
              "name" => "get_weather",
              "description" => "Get the weather for a city",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"city" => %{"type" => "string"}},
                "required" => ["city"]
              }
            }
          ],
          "tool_choice" => %{"type" => "any"},
          "messages" => [%{"role" => "user", "content" => "What is the weather in Paris?"}]
        })

      assert conn.status == 200

      assert_received {:backend_request, _url, body, _headers}

      assert [%{"name" => "get_weather", "input_schema" => %{"type" => "object"}}] =
               body["tools"]

      assert body["tool_choice"] == %{"type" => "any"}
    end

    test "tool_use / tool_result conversation turns survive conversion" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/messages", %{
          "model" => "claude-3-opus",
          "max_tokens" => 1024,
          "messages" => [
            %{"role" => "user", "content" => "What is the weather in Paris?"},
            %{
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_1",
                  "name" => "get_weather",
                  "input" => %{"city" => "Paris"}
                }
              ]
            },
            %{
              "role" => "user",
              "content" => [
                %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "18 degrees"}
              ]
            }
          ]
        })

      assert conn.status == 200

      assert_received {:backend_request, _url, body, _headers}

      # The tool_use block reaches the backend still Anthropic-shaped.
      assistant_block =
        body["messages"]
        |> Enum.find_value(fn msg ->
          Enum.find(List.wrap(msg["content"]), &(&1["type"] == "tool_use"))
        end)

      assert assistant_block["id"] == "toolu_1"
      assert assistant_block["name"] == "get_weather"
      assert assistant_block["input"] == %{"city" => "Paris"}
    end

    test "stream: true yields Anthropic SSE with typed events ending in message_stop" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/messages", %{
          "model" => "claude-3-opus",
          "max_tokens" => 1024,
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") |> IO.iodata_to_binary() =~
               "text/event-stream"

      body = conn.resp_body
      # Anthropic SSE: typed events on `event:` lines, closed by message_stop.
      assert String.contains?(body, "event:")
      assert String.contains?(body, "message_stop")
    end

    test "a harness sending x-api-key instead of Bearer is refused: the gate, not passthrough" do
      # Claude Code-authenticated SDKs sometimes present `x-api-key`. ShhAi's
      # inbound boundary is the proxy gate (Bearer on PROXY_API_KEYS) — a
      # client credential is NOT passed through to the backend.
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", @gate_key)
        |> post("/v1/messages", %{
          "model" => "claude-3-opus",
          "max_tokens" => 1024,
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "proxy_error"
    end
  end

  # ---------------------------------------------------------------------------
  # OpenAI dialect — POST /v1/chat/completions
  # (opencode / OpenWebUI / Cline / Aider / Continue / Zed)
  # ---------------------------------------------------------------------------

  describe "POST /v1/chat/completions (OpenAI dialect: opencode / OpenWebUI / Cline / Aider / Continue / Zed)" do
    test "chat-completions shape round-trips with system+user roles and a choices response" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [
            %{"role" => "system", "content" => "You are a helpful assistant."},
            %{"role" => "user", "content" => "Hello"}
          ]
        })

      assert conn.status == 200

      assert_received {:backend_request, url, body, headers}
      assert url =~ "/v1/chat/completions"
      assert url =~ "localhost:9999"

      assert body["model"] == "gpt-4"

      assert [
               %{"role" => "system", "content" => "You are a helpful assistant."},
               %{"role" => "user", "content" => "Hello"}
             ] = body["messages"]

      assert {"authorization", "Bearer openai-backend-key"} in headers
      refute Enum.any?(headers, fn {_name, value} -> value == @gate_key end)

      # OpenAI-shaped response for OpenAI-dialect clients.
      response = Jason.decode!(conn.resp_body)
      assert response["object"] == "chat.completion"

      assert [%{"message" => %{"role" => "assistant", "content" => "Hello!"}}] =
               response["choices"]
    end

    test "tools: OpenAI tool definitions and tool_choice convert untouched on the native path" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "tools" => [
            %{
              "type" => "function",
              "function" => %{
                "name" => "get_weather",
                "description" => "Get the weather for a city",
                "parameters" => %{
                  "type" => "object",
                  "properties" => %{"city" => %{"type" => "string"}},
                  "required" => ["city"]
                }
              }
            }
          ],
          "tool_choice" => "auto",
          "messages" => [%{"role" => "user", "content" => "What is the weather in Paris?"}]
        })

      assert conn.status == 200

      assert_received {:backend_request, _url, body, _headers}

      assert [
               %{
                 "type" => "function",
                 "function" => %{"name" => "get_weather", "parameters" => %{"type" => "object"}}
               }
             ] = body["tools"]

      assert body["tool_choice"] == "auto"
    end

    test "assistant tool_calls + tool-role follow-ups round-trip (agentic loop)" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [
            %{"role" => "user", "content" => "What is the weather in Paris?"},
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
                }
              ]
            },
            %{"role" => "tool", "tool_call_id" => "call_1", "content" => "18 degrees"}
          ]
        })

      assert conn.status == 200

      assert_received {:backend_request, _url, body, _headers}

      assert [%{"role" => "tool", "tool_call_id" => "call_1", "content" => "18 degrees"}] =
               Enum.filter(body["messages"], &(&1["role"] == "tool"))

      assistant = Enum.find(body["messages"], &(&1["role"] == "assistant"))

      assert [%{"id" => "call_1", "function" => %{"name" => "get_weather"}}] =
               assistant["tool_calls"]
    end

    test "stream: true yields OpenAI data:-line SSE ending with [DONE]" do
      record_requests()

      conn =
        authed_conn()
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") |> IO.iodata_to_binary() =~
               "text/event-stream"

      body = conn.resp_body
      # OpenAI SSE: `data:` lines, closed by the [DONE] sentinel.
      assert String.contains?(body, "data: ")
      assert String.contains?(body, "[DONE]")
    end
  end

  # ---------------------------------------------------------------------------
  # Inbound auth gate at the dialect endpoints (issue #55 flip from
  # "authorization passthrough" to authentication)
  # ---------------------------------------------------------------------------

  describe "inbound auth gate at the dialect endpoints (issue #55)" do
    @invalid_auth_cases [
      {"no authorization header", []},
      {"non-Bearer scheme", [{"authorization", "Basic #{@gate_key}"}]},
      {"wrong Bearer token", [{"authorization", "Bearer not-the-key"}]},
      {"Bearer with the backend's key", [{"authorization", "Bearer openai-backend-key"}]}
    ]

    for {label, headers} <- @invalid_auth_cases do
      for path <- ["/v1/messages", "/v1/chat/completions"] do
        test "POST #{path} refuses: #{label}" do
          {label, headers} = unquote({label, headers})
          path = unquote(path)

          conn =
            build_conn()
            |> put_req_header("content-type", "application/json")
            |> apply_auth(headers)
            |> post(path, %{
              "model" => "gpt-4",
              "messages" => [%{"role" => "user", "content" => "Hello"}]
            })

          assert conn.status == 401,
                 "expected 401 for #{label} on #{path}, got #{conn.status}: #{conn.resp_body}"

          assert Jason.decode!(conn.resp_body)["error"]["type"] == "proxy_error"
        end
      end
    end

    test "the only accepted credential is the proxy gate key (Config.proxy_api_keys/0)" do
      # Prove the acceptance is bound to the configured gate keys, not any
      # incidental credential: rotate the configured key and the previous
      # token is refused.
      System.put_env("PROXY_API_KEYS", "rotated-key")
      Config.load()

      stale =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@gate_key}")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert stale.status == 401

      fresh =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer rotated-key")
        |> post("/v1/chat/completions", %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert fresh.status in [200, 404, 500]
    end

    test "an unconfigured gate (PROXY_API_KEYS unset) refuses both dialect endpoints with 503" do
      System.delete_env("PROXY_API_KEYS")
      Config.load()

      for path <- ["/v1/messages", "/v1/chat/completions"] do
        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post(path, %{
            "model" => "gpt-4",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          })

        assert conn.status == 503, "expected 503 on #{path}, got #{conn.status}"
      end
    end
  end
end
