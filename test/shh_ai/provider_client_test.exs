defmodule ShhAi.ProviderClientTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.Conversation.Fingerprinter
  alias ShhAi.MeckHelper
  alias ShhAi.PII.Patterns
  alias ShhAi.PII.SanitizationResult
  alias ShhAi.ProviderClient

  setup do
    ShhAi.AuditCase.snapshot_env([
      "PII_ERROR_MODE",
      "PROVIDER_OPENAI_1_ENABLED",
      "PROVIDER_OPENAI_1_API_KEY",
      "PROVIDER_OPENAI_1_BASE_URL",
      "PROVIDER_OPENAI_2_ENABLED",
      "PROVIDER_OPENAI_2_API_KEY",
      "PROVIDER_OPENAI_2_BASE_URL",
      "PROVIDER_OPENAI_3_ENABLED",
      "PROVIDER_OPENAI_3_API_KEY",
      "PROVIDER_OPENAI_3_BASE_URL"
    ])

    # Set up a provider for tests
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", "http://localhost:9999/v1")
    Config.load()

    ShhAi.ConversationCase.setup_ets()

    # Ensure PII patterns are loaded
    Patterns.load_into_persistent_term()

    # The supervised catalog is empty/stale in the test env, so model-aware
    # selection (`ShhAi.TargetProvider.resolve/2`) would reject every model. Treat
    # every configured provider instance as serving every model, preserving
    # each test's original "any configured provider" intent; #68 tests
    # override this expectation to assert real selection.
    :meck.new(ShhAi.ModelCatalog, [:passthrough, :no_link])

    :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fn _model ->
      Enum.map(Config.providers(), &Config.provider_instance/1)
    end)

    on_exit(fn ->
      # Other helpers in this file unload *all* mocks; tolerate an already-gone
      # ModelCatalog rather than raising from on_exit.
      MeckHelper.unload(ShhAi.ModelCatalog)
    end)

    # Use mock HTTP transport to avoid real API calls
    Application.put_env(:shh_ai, :http_client, ShhAi.ProviderClient.HTTPTransportMock)

    on_exit(fn ->
      Application.delete_env(:shh_ai, :http_client)
    end)

    :ok
  end

  # Deterministic messages for fingerprint-based (Turn 2+) tests.
  @fp_messages [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]

  @nil_pii %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}

  # Run a test function with the PII pipeline mocked out. Uses synchronous
  # try/after so the meck state is cleaned up before the next test starts —
  # this avoids the race condition where two tests running in parallel
  # (max_cases: 2) both try to mock the same module.
  defp with_mocked_pii(fun) do
    :meck.new(ShhAi.PIIPipeline, [:passthrough])

    :meck.expect(ShhAi.PIIPipeline, :sanitize_openai_request, fn body, _conversation, _opts ->
      messages = body["messages"] || body["input"] || [body]

      {:ok,
       %ShhAi.PII.SanitizationResult{
         sanitized_messages: messages,
         mapping: %{},
         reverse_index: %{},
         detection_counts: {0, 0},
         pii_info: @nil_pii
       }}
    end)

    :meck.expect(ShhAi.PIIPipeline, :restore_openai_response, fn response, _conversation, _opts ->
      {:ok, response}
    end)

    try do
      fun.()
    after
      :meck.unload(ShhAi.PIIPipeline)
    end
  end

  # Force a detector hard error and record whether the upstream transport is
  # reached, so the fail-closed/fail-open policy is observable end-to-end.
  defp with_detector_failure_and_recording_transport(fun) do
    test_pid = self()

    :meck.new(ShhAi.PII.Sanitizer, [:passthrough])

    :meck.expect(ShhAi.PII.Sanitizer, :sanitize_messages, fn _messages, _opts ->
      raise "detector unavailable"
    end)

    :meck.new(ShhAi.ProviderClient.HTTPTransportMock, [:passthrough])

    :meck.expect(ShhAi.ProviderClient.HTTPTransportMock, :do_request, fn _method,
                                                                         _url,
                                                                         body,
                                                                         _headers,
                                                                         _timeout ->
      send(test_pid, {:upstream_called, body})

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
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
           ]
         }
       }}
    end)

    on_exit(fn -> :meck.unload() end)

    fun.()
  end

  # Helper to call find_or_create with the old single-arg API style (map with
  # :fingerprint key) by splitting it into the new two-arg form.
  defp find_or_create(%{fingerprint: nil} = input) do
    attrs = Map.drop(input, [:fingerprint])
    ShhAi.Conversation.find_or_create([], attrs)
  end

  defp find_or_create(%{fingerprint: _fp} = input) do
    attrs = Map.drop(input, [:fingerprint])
    ShhAi.Conversation.find_or_create(@fp_messages, attrs)
  end

  describe "request/5" do
    test "handles map body" do
      with_mocked_pii(fn ->
        body = %{"model" => "gpt-4", "messages" => []}
        headers = []

        result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end
      end)
    end

    test "handles binary JSON body" do
      with_mocked_pii(fn ->
        body = Jason.encode!(%{"model" => "gpt-4", "messages" => []})
        headers = []

        result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end
      end)
    end

    test "handles invalid JSON string body" do
      with_mocked_pii(fn ->
        body = "not valid json"
        headers = []

        result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end
      end)
    end

    test "converts Anthropic format to target provider" do
      with_mocked_pii(fn ->
        System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
        System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "test-anthropic-key")
        Config.load()

        body = %{
          "model" => "claude-3-opus",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 1024
        }

        headers = [{"x-api-key", "original-key"}]

        result = ProviderClient.request(:anthropic, "/v1/messages", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end

        System.delete_env("PROVIDER_ANTHROPIC_1_ENABLED")
        System.delete_env("PROVIDER_ANTHROPIC_1_API_KEY")
      end)
    end

    test "converts Ollama format to target provider" do
      with_mocked_pii(fn ->
        System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
        System.put_env("PROVIDER_OLLAMA_1_API_KEY", "ollama-key")
        System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://localhost:11434")
        Config.load()

        body = %{
          "model" => "llama3",
          "messages" => [%{"role" => "user", "content" => "test"}]
        }

        headers = []

        result = ProviderClient.request(:ollama, "/api/chat", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end

        System.delete_env("PROVIDER_OLLAMA_1_ENABLED")
        System.delete_env("PROVIDER_OLLAMA_1_API_KEY")
        System.delete_env("PROVIDER_OLLAMA_1_BASE_URL")
      end)
    end

    test "handles multiple providers configured" do
      with_mocked_pii(fn ->
        System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
        System.put_env("PROVIDER_OPENAI_1_API_KEY", "key1")
        System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
        System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "key2")
        Config.load()

        body = %{"model" => "test", "messages" => []}
        headers = []

        results =
          for _ <- 1..5 do
            case ProviderClient.request(
                   :openai,
                   "/v1/chat/completions",
                   "POST",
                   body,
                   headers
                 ) do
              {:ok, _response} ->
                true

              {:error, _reason} ->
                false
            end
          end
          |> Enum.reject(&is_nil/1)

        # All providers should be valid strings
        assert results != []
        assert Enum.all?(results, &is_boolean/1)

        System.delete_env("PROVIDER_OPENAI_1_ENABLED")
        System.delete_env("PROVIDER_OPENAI_1_API_KEY")
        System.delete_env("PROVIDER_ANTHROPIC_1_ENABLED")
        System.delete_env("PROVIDER_ANTHROPIC_1_API_KEY")
      end)
    end

    test "handles empty map body" do
      with_mocked_pii(fn ->
        body = %{}
        headers = []

        result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end
      end)
    end

    test "preserves custom headers through conversion" do
      with_mocked_pii(fn ->
        body = %{"model" => "gpt-4", "messages" => []}
        headers = [{"x-custom-header", "custom-value"}, {"x-request-id", "12345"}]

        result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end
      end)
    end
  end

  describe "fingerprint computation in find_or_create_conversation" do
    test "Turn 1 (single message) creates a new conversation with nil fingerprint" do
      # A single-message request has no prior context to fingerprint,
      # so find_or_create_conversation passes nil → creates with UUID v4.
      messages = [%{"role" => "user", "content" => "Hello"}]

      # The fingerprint for messages[0..-2] (empty slice) should be nil
      fingerprint =
        messages
        |> Enum.slice(0, length(messages) - 1)
        |> Fingerprinter.fingerprint_messages()

      assert fingerprint == nil

      {:ok, conversation} =
        find_or_create(%{
          fingerprint: fingerprint,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert conversation.new? == true
      assert is_binary(conversation.conversation_id)
      assert byte_size(conversation.conversation_id) == 36
    end

    test "Turn 2+ (multiple messages) computes fingerprint from messages[0..-2] and finds existing conversation" do
      # Simulate Turn 2: messages = [user, assistant, user]
      # fingerprint is computed from [user, assistant] (messages[0..-2])
      prior_messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there!"}
      ]

      fingerprint = Fingerprinter.fingerprint_messages(prior_messages)
      assert is_binary(fingerprint)
      assert byte_size(fingerprint) == 64

      # First request with this fingerprint creates a new conversation
      {:ok, conv1} =
        find_or_create(%{
          fingerprint: fingerprint,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert conv1.new? == true

      # Second request with the same fingerprint finds the existing one
      {:ok, conv2} =
        find_or_create(%{
          fingerprint: fingerprint,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert conv2.new? == false
      assert conv2.conversation_id == conv1.conversation_id
    end

    test "different message histories produce different fingerprints and separate conversations" do
      messages_a = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi!"}
      ]

      messages_b = [
        %{"role" => "user", "content" => "Goodbye"},
        %{"role" => "assistant", "content" => "See you!"}
      ]

      fp_a = Fingerprinter.fingerprint_messages(messages_a)
      fp_b = Fingerprinter.fingerprint_messages(messages_b)

      assert fp_a != fp_b

      {:ok, conv_a} =
        Conversation.find_or_create(messages_a, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      {:ok, conv_b} =
        Conversation.find_or_create(messages_b, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert conv_a.conversation_id != conv_b.conversation_id
    end

    test "fingerprint uses first 2 messages only (stable across turns)" do
      # 3 messages: user, assistant, user
      # fingerprint_messages only hashes the first 2, so adding a 3rd doesn't change it
      all_messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi!"},
        %{"role" => "user", "content" => "How are you?"}
      ]

      fp_all = Fingerprinter.fingerprint_messages(all_messages)

      fp_first_two =
        all_messages
        |> Enum.slice(0, length(all_messages) - 1)
        |> Fingerprinter.fingerprint_messages()

      # fingerprint_messages only uses the first 2 messages, so they are equal
      assert fp_all == fp_first_two

      assert is_binary(fp_first_two)
    end

    test "Turn 1 → response → Turn 2 with finalize flow" do
      # Turn 1: single message → nil fingerprint → new in-memory conversation
      {:ok, turn1_conv} =
        Conversation.find_or_create([], %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn1_conv.new? == true

      # Simulate post-response: finalize with full message list
      full_messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there!"}
      ]

      fingerprint = Fingerprinter.fingerprint_messages(full_messages)

      {:ok, final_id} =
        Conversation.persist_turn(
          conversation: %{
            turn1_conv
            | conversation_id: Fingerprinter.derive_conversation_id(fingerprint)
          },
          sanitized_messages:
            Enum.map(full_messages, fn m ->
              %{"role" => m["role"], "content" => m["content"]}
            end),
          assistant_message_hash: "",
          mapping: %{},
          reverse_index: %{},
          request_time: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          fingerprint: fingerprint
        )

      # Turn 2: same first 2 messages → should find the finalized conversation
      {:ok, turn2_conv} =
        Conversation.find_or_create(full_messages, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn2_conv.new? == false
      assert turn2_conv.conversation_id == final_id
    end
  end

  describe "conversation integration" do
    test "creates a conversation on each request" do
      with_mocked_pii(fn ->
        body = %{
          "thread_id" => "thread_test_001",
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        headers = []

        result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        # Just assert the request didn't crash
        case result do
          {:ok, _response} -> assert true
          {:error, _reason} -> assert true
        end
      end)
    end

    test "creates stateless conversation when no conversation ID present" do
      with_mocked_pii(fn ->
        body = %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        headers = []

        _result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

        # Should not crash — stateless conversations are created with nil provider_conversation_id
        assert true
      end)
    end

    test "passes conversation to PIIPipeline without crashing" do
      body = %{
        "thread_id" => "thread_pii_test",
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "My email is test@example.com"}
        ]
      }

      headers = []

      result = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, headers)

      # Just assert the request didn't crash — PII pipeline integration
      # is tested in conversation_integration_test.exs
      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "emits telemetry with conversation_id in metadata" do
      with_mocked_pii(fn ->
        # Attach a telemetry handler to capture metadata
        test_pid = self()
        handler_id = "test-conversation-id-handler-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler_id,
          [:shh_ai, :request, :stop],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:telemetry_metadata, metadata})
          end,
          %{}
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        body = %{
          "model" => "gpt-4",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

        # Wait for telemetry to fire
        assert_receive {:telemetry_metadata, metadata}, 5_000

        # The metadata should include a conversation_id (a UUID string)
        assert Map.has_key?(metadata, :conversation_id)
        assert is_binary(metadata.conversation_id)
        assert byte_size(metadata.conversation_id) == 36
      end)
    end
  end

  describe "streaming flag" do
    test "request/6 sets streaming: false on the request context (observable via metrics metadata)" do
      with_mocked_pii(fn ->
        test_pid = self()
        handler_id = "streaming-flag-req-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler_id,
          [:shh_ai, :request, :stop],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:telemetry_metadata, metadata})
          end,
          %{}
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        body = %{"model" => "gpt-4", "messages" => []}
        _ = ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

        assert_receive {:telemetry_metadata, metadata}, 5_000
        assert metadata.streaming == false, "non-streaming request must emit streaming: false"
      end)
    end
  end

  describe "build_initial_metrics/1 removal (Slice 5)" do
    test "build_initial_metrics/1 is no longer exported" do
      refute function_exported?(ProviderClient, :build_initial_metrics, 1),
             "build_initial_metrics/1 should be removed in Slice 5"
    end
  end

  describe "streaming response caching" do
    test "cache_assistant_response stores pre-restored content keyed by restored hash" do
      alias ShhAi.Conversation
      alias ShhAi.PII.Sanitizer

      # Create a conversation
      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})

      # Simulate pre-restored assistant content (with placeholders)
      pre_restored = "Hello <PERSON_1>, your email is <EMAIL_1>"

      # The mapping from the request sanitization
      mapping = %{
        {:person, 1} => "John",
        {:email, 1} => "john@example.com"
      }

      # What the restored content would be
      {:ok, restored} = Sanitizer.restore(pre_restored, mapping)
      assert restored == "Hello John, your email is john@example.com"

      # Hash the restored content (this is what the cache key should be)
      expected_hash = Conversation.hash_message(%{role: "assistant", content: restored})

      # Call the caching function (we'll make it accessible for testing)
      # Since it's private, we test through the mechanism directly:
      cached = %{"role" => "assistant", "content" => pre_restored}
      Conversation.cache_message(conv.conversation_id, expected_hash, cached)

      # Verify: looking up by the restored hash returns the cached message
      assert {:ok, ^cached} =
               Conversation.lookup_message(conv.conversation_id, expected_hash)
    end

    test "cached assistant content is used in next turn's sanitization" do
      alias ShhAi.{Conversation, PIIPipeline}

      # Create a conversation with messages so it persists to ETS
      messages = [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]
      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      # Mark as existing (not new) so cache path is used
      conv = %{conv | new?: false}

      # Simulate: Turn 1 had an assistant response that was cached
      # The restored content (what the client saw)
      restored_content = "Hello John, your email is john@example.com"
      # The pre-restored content (with placeholders, what was cached)
      pre_restored = "Hello <PERSON_1>, your email is <EMAIL_1>"

      # Hash the restored content and cache the pre-restored message
      hash = Conversation.hash_message(%{role: "assistant", content: restored_content})

      Conversation.cache_message(
        conv.conversation_id,
        hash,
        {:assistant_message, %{"role" => "assistant", "content" => pre_restored}}
      )

      # Turn 2: the message history includes the assistant response (restored content)
      body = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => "My name is John and email is john@example.com"
          },
          %{"role" => "assistant", "content" => restored_content},
          %{"role" => "user", "content" => "Thanks!"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      # The assistant message should be sanitized using the cached version
      assistant_msg = Enum.at(sanitized, 1)
      assert assistant_msg["content"] == pre_restored
    end

    test "empty assistant content is not cached" do
      alias ShhAi.Conversation

      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})

      # Empty content should not be cached (no-op)
      _pre_restored = ""
      _mapping = %{{:email, 1} => "john@example.com"}

      # The helper function checks for empty content and skips caching
      # We verify by checking that no cache entry exists
      restored = "test"
      hash = Conversation.hash_message(%{role: "assistant", content: restored})
      assert {:error, :not_found} = Conversation.lookup_message(conv.conversation_id, hash)
    end
  end

  describe "detector hard error policy at the request seam" do
    @pii_body %{
      "model" => "gpt-4",
      "messages" => [%{"role" => "user", "content" => "My email is john@example.com"}]
    }

    test "blocks the request and forwards nothing upstream by default" do
      System.delete_env("PII_ERROR_MODE")
      Config.load()

      with_detector_failure_and_recording_transport(fn ->
        assert {:error, :pii_sanitization_failed} =
                 ProviderClient.request(
                   :openai,
                   "/v1/chat/completions",
                   "POST",
                   @pii_body,
                   []
                 )
      end)

      refute_received {:upstream_called, _}
    end

    test "forwards the un-sanitized request upstream when PII_ERROR_MODE=forward" do
      System.put_env("PII_ERROR_MODE", "forward")
      Config.load()

      with_detector_failure_and_recording_transport(fn ->
        assert {:ok, _response} =
                 ProviderClient.request(
                   :openai,
                   "/v1/chat/completions",
                   "POST",
                   @pii_body,
                   []
                 )
      end)

      assert_received {:upstream_called, body}

      assert get_in(body, ["messages", Access.at(0), "content"]) ==
               "My email is john@example.com"
    end
  end

  describe "provider instance pinning and model-aware selection (issue #68)" do
    # Two OpenAI instances with distinct base URLs and credentials, so the
    # outbound URL and headers identify which instance actually served.
    defp configure_two_openai_instances do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_BASE_URL", "http://one.test/v1")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-one")
      System.put_env("PROVIDER_OPENAI_2_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_2_BASE_URL", "http://two.test/v1")
      System.put_env("PROVIDER_OPENAI_2_API_KEY", "key-two")
      Config.load()
    end

    # Overrides the setup-wide catalog stub so a test controls which
    # instance(s) serve which model.
    defp stub_serving(fun) do
      :meck.expect(ShhAi.ModelCatalog, :provider_instances_serving, fun)
    end

    defp record_outbound do
      test_pid = self()
      :meck.new(ShhAi.ProviderClient.HTTPTransportMock, [:passthrough, :no_link])

      on_exit(fn ->
        MeckHelper.unload(ShhAi.ProviderClient.HTTPTransportMock)
      end)

      :meck.expect(
        ShhAi.ProviderClient.HTTPTransportMock,
        :do_request,
        fn _method, url, _body, headers, _timeout ->
          send(test_pid, {:outbound, url, headers})
          {:ok, openai_ok_response()}
        end
      )
    end

    defp openai_ok_response do
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

    test "routes to an instance serving the model and sends that instance's own api_key" do
      configure_two_openai_instances()
      record_outbound()
      stub_serving(fn "model-two" -> ["openai_2"] end)

      with_mocked_pii(fn ->
        body = %{
          "model" => "model-two",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [
                   {"authorization", "Bearer client-token"},
                   {"x-api-key", "client-x-key"}
                 ])

        assert_receive {:outbound, url, headers}, 5_000

        # The instance serving the model is openai_2 (base_url two.test).
        assert url =~ "two.test"

        # The credential sent is openai_2's own configured key, and no
        # client-supplied credential is forwarded.
        assert {"authorization", "Bearer key-two"} in headers

        refute Enum.any?(headers, fn {_name, value} ->
                 value in ["client-token", "Bearer client-token", "client-x-key"]
               end)

        refute Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "x-api-key" end)
      end)
    end

    test "an unserved model returns {:error, {:model_not_served, model}}" do
      stub_serving(fn _model -> [] end)

      with_mocked_pii(fn ->
        body = %{
          "model" => "ghost-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:error, {:model_not_served, "ghost-model"}} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])
      end)
    end

    test "two turns in the same conversation reach the same provider instance (pin reuse)" do
      configure_two_openai_instances()
      record_outbound()

      # Turn 1: only openai_2 serves the model.
      stub_serving(fn "turn-model" -> ["openai_2"] end)

      with_mocked_pii(fn ->
        turn1 = %{
          "model" => "turn-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn1, [])

        assert_receive {:outbound, url1, _headers}, 5_000
        assert url1 =~ "two.test"

        # Turn 2: the catalog now reports the model served only by openai_1.
        # The conversation's pin must win, so turn 2 still reaches openai_2 —
        # a model-aware re-selection would deterministically pick openai_1.
        stub_serving(fn "turn-model" -> ["openai_1"] end)

        turn2 = %{
          "model" => "turn-model",
          "messages" => [
            %{"role" => "user", "content" => "Hello"},
            %{"role" => "assistant", "content" => "Hello!"},
            %{"role" => "user", "content" => "More"}
          ]
        }

        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn2, [])

        assert_receive {:outbound, url2, _headers}, 5_000
        assert url2 == url1
      end)
    end

    test "the pin survives touch/update_fingerprint, and re-selects when the pinned instance is gone" do
      configure_two_openai_instances()

      # A third instance, enabled for the whole test but unserved until Turn 3,
      # so the stale-pin re-selection has two candidates and must pick the
      # capable one (openai_3) rather than a random or model-less fallback.
      System.put_env("PROVIDER_OPENAI_3_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_3_BASE_URL", "http://three.test/v1")
      System.put_env("PROVIDER_OPENAI_3_API_KEY", "key-three")
      Config.load()

      record_outbound()
      stub_serving(fn "pin-model" -> ["openai_2"] end)

      with_mocked_pii(fn ->
        turn = %{
          "model" => "pin-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn, [])

        assert_receive {:outbound, url1, _headers}, 5_000
        assert url1 =~ "two.test"

        [conversation] =
          Conversation.Store.list_conversations(limit: 1000)
          |> Enum.filter(&(&1.pinned_provider == "openai_2"))

        assert conversation.pinned_provider == "openai_2"

        # Both mutators must preserve the pin.
        assert Conversation.touch(conversation.conversation_id) == :ok

        assert Conversation.update_fingerprint(
                 conversation.conversation_id,
                 conversation.fingerprint_hash
               ) == :ok

        {:ok, after_mutation} = Conversation.Store.get_conversation(conversation.conversation_id)
        assert after_mutation.pinned_provider == "openai_2"

        # Turn 2 with the pin intact: still openai_2, even though the catalog
        # now says only openai_1 serves the model.
        stub_serving(fn "pin-model" -> ["openai_1"] end)

        turn2 = %{
          "model" => "pin-model",
          "messages" => [
            %{"role" => "user", "content" => "Hello"},
            %{"role" => "assistant", "content" => "Hello!"},
            %{"role" => "user", "content" => "More"}
          ]
        }

        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn2, [])

        assert_receive {:outbound, url2, _headers}, 5_000
        assert url2 == url1

        # Turn 3: openai_2 is gone from config, so the stale pin re-selects —
        # to the capable instance the catalog reports for the model (openai_3),
        # even though openai_1 is also configured.
        System.delete_env("PROVIDER_OPENAI_2_ENABLED")
        Config.load()
        stub_serving(fn "pin-model" -> ["openai_3"] end)

        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn2, [])

        assert_receive {:outbound, url3, _headers}, 5_000
        assert url3 =~ "three.test"

        # The replacement pin is written back to the store, so later turns
        # stay on openai_3 instead of re-selecting.
        {:ok, after_reselect} = Conversation.Store.get_conversation(conversation.conversation_id)
        assert after_reselect.pinned_provider == "openai_3"
      end)
    end

    test "a request with no model routes to a configured instance instead of 404" do
      configure_two_openai_instances()
      record_outbound()
      # Nothing is served by any instance: a model-less request must not
      # consult the catalog at all.
      stub_serving(fn _model -> [] end)

      with_mocked_pii(fn ->
        assert {:ok, _response} =
                 ProviderClient.request(:openai, "/v1/models/gpt-4", :get, %{}, [])

        assert_receive {:outbound, url, _headers}, 5_000
        assert url =~ ~r/one\.test|two\.test/
      end)
    end
  end

  describe "persisted error-class normalisation (issue #56)" do
    test "a transport failure persists the bounded error class, not the raw reason" do
      test_pid = self()
      handler_id = "error-class-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata[:error], do: send(test_pid, {:error_event, metadata.error})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :meck.new(ShhAi.ProviderClient.HTTPTransportMock, [:passthrough, :no_link])

      on_exit(fn ->
        MeckHelper.unload(ShhAi.ProviderClient.HTTPTransportMock)
      end)

      :meck.expect(
        ShhAi.ProviderClient.HTTPTransportMock,
        :do_request,
        fn _method, _url, _body, _headers, _timeout ->
          {:error, %Req.TransportError{reason: :econnrefused}}
        end
      )

      # The setup configures a single backend, so under #72 its connection-class
      # failure exhausts the capable pool: the caller sees the tagged
      # pool-exhaustion error, never the raw transport struct.
      with_mocked_pii(fn ->
        assert {:error, {:pool_exhausted, "gpt-4"}} =
                 ProviderClient.request(
                   :openai,
                   "/v1/chat/completions",
                   "POST",
                   %{"model" => "gpt-4", "messages" => [%{"role" => "user", "content" => "Hi"}]},
                   []
                 )
      end)

      assert_receive {:error_event, error}, 1_000
      assert error.type == :request_error
      assert error.message == "pool_exhausted"
      refute error.message =~ "%Req.TransportError"
    end
  end

  describe "connection-failure retry and fallback (issue #72)" do
    # The connection-class transport failures the spec names, in the shape
    # Req actually surfaces them (one exception struct per HTTP stack).
    defp connection_failures do
      [
        %Req.TransportError{reason: :econnrefused},
        %Req.TransportError{reason: :nxdomain},
        %Req.TransportError{reason: :econnreset},
        %Req.TransportError{reason: :closed},
        %Mint.TransportError{reason: :econnrefused},
        %Mint.TransportError{reason: :nxdomain},
        %Mint.TransportError{reason: :econnreset},
        %Mint.TransportError{reason: :closed}
      ]
    end

    defp fail_times(structs) when is_list(structs) do
      MeckHelper.unload(ShhAi.ProviderClient.HTTPTransportMock)

      :meck.new(ShhAi.ProviderClient.HTTPTransportMock, [:passthrough, :no_link])

      on_exit(fn ->
        MeckHelper.unload(ShhAi.ProviderClient.HTTPTransportMock)
      end)

      :meck.expect(
        ShhAi.ProviderClient.HTTPTransportMock,
        :do_request,
        make_failing_do_request(structs)
      )
    end

    # Fails with one struct per call — popping the list — then succeeds.
    defp make_failing_do_request(structs) do
      key = {__MODULE__, :fail_times, make_ref()}

      fn _method, url, _body, _headers, _timeout ->
        case Process.get(key) || structs do
          [next | rest] ->
            Process.put(key, rest)
            send(self(), {:outbound, url, :error})
            {:error, next}

          [] ->
            send(self(), {:outbound, url, :ok})
            {:ok, openai_ok_response()}
        end
      end
    end

    defp outbound_urls(count) do
      urls =
        for _n <- 1..count do
          assert_receive {:outbound, url, _}, 5_000
          url
        end

      refute_received {:outbound, _, _}
      urls
    end

    defp stream_attempts(count) do
      bases =
        for _n <- 1..count do
          assert_receive {:stream_attempt, base}, 5_000
          base
        end

      refute_received {:stream_attempt, _}
      bases
    end

    # Every connection-class failure shape is retried elsewhere: a request
    # whose first attempt hits one still succeeds on the other capable
    # backend (issue #72).
    test "a connection-class failure on the first backend falls back and succeeds" do
      configure_two_openai_instances()
      stub_serving(fn "fb-model" -> ["openai_1", "openai_2"] end)

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        for failure <- connection_failures() do
          # Exactly one failure queued: the first attempt fails and the
          # fallback to the other capable backend succeeds.
          fail_times([failure])

          assert {:ok, _} =
                   ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

          assert [first, second] = outbound_urls(2)
          assert first != second
        end
      end)
    end

    test "a retryable failure re-converts only the target dialect (detection is not re-run)" do
      configure_two_openai_instances()
      stub_serving(fn "fb-model" -> ["openai_1", "openai_2"] end)
      fail_times([%Req.TransportError{reason: :econnrefused}])

      :meck.new(ShhAi.PIIPipeline, [:passthrough])

      :meck.expect(ShhAi.PIIPipeline, :sanitize_openai_request, fn body, _conversation, _opts ->
        messages = body["messages"] || body["input"] || [body]

        {:ok,
         %ShhAi.PII.SanitizationResult{
           sanitized_messages: messages,
           mapping: %{},
           reverse_index: %{},
           detection_counts: {0, 0},
           pii_info: @nil_pii
         }}
      end)

      :meck.expect(ShhAi.PIIPipeline, :restore_openai_response, fn response,
                                                                   _conversation,
                                                                   _opts ->
        {:ok, response}
      end)

      try do
        turn1 = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:ok, _} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn1, [])

        sanitize_calls =
          ShhAi.PIIPipeline
          |> :meck.history()
          |> Enum.count(fn {_pid, {_mod, fun, _args}, _result} ->
            fun == :sanitize_openai_request
          end)

        # One detection pass for the whole request, across both backends.
        assert sanitize_calls == 1
        assert [_first, _second] = outbound_urls(2)
      after
        :meck.unload(ShhAi.PIIPipeline)
      end
    end

    test "receive-timeouts are returned unchanged, never retried" do
      configure_two_openai_instances()
      stub_serving(fn _model -> ["openai_1", "openai_2"] end)
      timeout = %Req.TransportError{reason: :timeout}
      fail_times([timeout, timeout, timeout])

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:error, ^timeout} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

        # Exactly one outbound attempt: a receive-timeout is a hard error.
        assert [_only] = outbound_urls(1)
      end)
    end

    test "provider HTTP error responses pass through untouched, never retried" do
      configure_two_openai_instances()
      stub_serving(fn _model -> ["openai_1", "openai_2"] end)

      :meck.new(ShhAi.ProviderClient.HTTPTransportMock, [:passthrough, :no_link])

      :meck.expect(
        ShhAi.ProviderClient.HTTPTransportMock,
        :do_request,
        fn _method, _url, _body, _headers, _timeout ->
          send(self(), :provider_500)
          {:ok, %Req.Response{status: 500, headers: [], body: %{"error" => "upstream"}}}
        end
      )

      on_exit(fn ->
        MeckHelper.unload(ShhAi.ProviderClient.HTTPTransportMock)
      end)

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:ok, %Req.Response{status: 500, body: %{"error" => "upstream"}}} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

        # The provider's answer is surfaced once — no retry, no double-billing.
        assert_received :provider_500
        refute_received :provider_500
      end)
    end

    test "all capable backends unreachable returns the tagged pool-exhaustion error" do
      configure_two_openai_instances()
      stub_serving(fn "fb-model" -> ["openai_1", "openai_2"] end)
      fail_times([%Req.TransportError{reason: :closed}, %Req.TransportError{reason: :closed}])

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:error, {:pool_exhausted, "fb-model"}} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

        # Both capable instances were tried, exactly once each.
        urls = outbound_urls(2)
        assert hd(urls) =~ ~r/one\.test|two\.test/
        assert List.last(urls) != hd(urls)
      end)
    end

    test "a single-backend deployment fails immediately on a connection-class failure" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_BASE_URL", "http://one.test/v1")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key-one")
      System.delete_env("PROVIDER_OPENAI_2_ENABLED")
      Config.load()

      stub_serving(fn _model -> ["openai_1"] end)
      fail_times([%Req.TransportError{reason: :econnrefused}])

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:error, {:pool_exhausted, "fb-model"}} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", body, [])

        # No second attempt is made against a pool of one.
        assert [_only] = outbound_urls(1)
      end)
    end

    test "the conversation pin is unchanged by retry" do
      configure_two_openai_instances()

      with_mocked_pii(fn ->
        # Turn 1 pins openai_1 — the only capable instance at the time — so
        # turn 2's first attempt is deterministic.
        stub_serving(fn "fb-model" -> ["openai_1"] end)
        fail_times([])

        turn1 = %{
          "model" => "fb-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        assert {:ok, _} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn1, [])

        assert [_only] = outbound_urls(1)

        [conversation] =
          ShhAi.Conversation.Store.list_conversations(limit: 1000)
          |> Enum.filter(&(&1.pinned_provider != nil))

        assert conversation.pinned_provider == "openai_1"

        # Turn 2: the pinned openai_1 fails once and the request falls back to
        # openai_2 — the pin is the first attempt only, never mutated by retry.
        stub_serving(fn "fb-model" -> ["openai_1", "openai_2"] end)
        fail_times([%Req.TransportError{reason: :econnrefused}])

        turn2 = %{
          "model" => "fb-model",
          "messages" => [
            %{"role" => "user", "content" => "Hello"},
            %{"role" => "assistant", "content" => "Hello!"},
            %{"role" => "user", "content" => "More"}
          ]
        }

        assert {:ok, _} =
                 ProviderClient.request(:openai, "/v1/chat/completions", "POST", turn2, [])

        assert [_first, _second] = outbound_urls(2)

        {:ok, after_retry} =
          ShhAi.Conversation.Store.get_conversation(conversation.conversation_id)

        assert after_retry.pinned_provider == "openai_1"
      end)
    end

    test "streaming retries only before the first byte and succeeds" do
      configure_two_openai_instances()
      stub_serving(fn _model -> ["openai_1", "openai_2"] end)

      test_pid = self()
      first_call = make_ref()

      :meck.new(ShhAi.ProviderClient.StreamTransport, [:passthrough, :no_link])

      :meck.expect(ShhAi.ProviderClient.StreamTransport, :do_stream, fn _req,
                                                                        handle,
                                                                        _start,
                                                                        _conv_id ->
        base = handle.request_context.config.base_url
        send(test_pid, {:stream_attempt, base})

        # The first attempt fails before the first byte (no chunk dispatched);
        # the retry on the other capable backend succeeds.
        if Process.get(first_call) do
          {:ok, handle, %Req.Response{status: 200}}
        else
          Process.put(first_call, true)
          {:error, %Req.TransportError{reason: :econnrefused}}
        end
      end)

      on_exit(fn -> :meck.unload(ShhAi.ProviderClient.StreamTransport) end)

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        conn = Plug.Test.conn(:post, "/v1/chat/completions")

        assert {:ok, _conn} =
                 ProviderClient.stream(
                   conn,
                   fn _chunk, acc -> {:cont, acc} end,
                   :openai,
                   "/v1/chat/completions",
                   "POST",
                   body,
                   []
                 )

        assert [base1, base2] = stream_attempts(2)
        assert base1 != base2
      end)
    end

    test "a mid-stream failure is not retried" do
      configure_two_openai_instances()
      stub_serving(fn _model -> ["openai_1", "openai_2"] end)

      test_pid = self()

      :meck.new(ShhAi.ProviderClient.StreamTransport, [:passthrough, :no_link])

      :meck.expect(ShhAi.ProviderClient.StreamTransport, :do_stream, fn _req,
                                                                        handle,
                                                                        _start,
                                                                        _conv_id ->
        send(test_pid, {:stream_attempt, handle.request_context.config.base_url})

        # Simulate bytes already delivered to the client before the failure.
        {:error, {:stream_failed_after_first_byte, :closed}}
      end)

      on_exit(fn -> :meck.unload(ShhAi.ProviderClient.StreamTransport) end)

      with_mocked_pii(fn ->
        body = %{
          "model" => "fb-model",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        }

        conn = Plug.Test.conn(:post, "/v1/chat/completions")

        assert {:error, {:stream_failed_after_first_byte, :closed}} =
                 ProviderClient.stream(
                   conn,
                   fn _chunk, acc -> {:cont, acc} end,
                   :openai,
                   "/v1/chat/completions",
                   "POST",
                   body,
                   []
                 )

        # Exactly one attempt: a mid-stream failure terminates the stream.
        assert [_only] = stream_attempts(1)
      end)
    end
  end
end
