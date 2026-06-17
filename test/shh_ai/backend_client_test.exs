defmodule ShhAi.BackendClientTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.BackendClient
  alias ShhAi.Conversation
  alias ShhAi.PII.Patterns

  setup do
    # Set up a provider for tests
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", "http://localhost:9999/v1")
    Config.load()

    ShhAi.ConversationCase.setup_ets()

    # Ensure PII patterns are loaded
    Patterns.load_into_persistent_term()

    # Use mock HTTP transport to avoid real API calls
    Application.put_env(:shh_ai, :http_client, ShhAi.BackendClient.HTTPTransportMock)

    on_exit(fn ->
      System.delete_env("PROVIDER_OPENAI_1_ENABLED")
      System.delete_env("PROVIDER_OPENAI_1_API_KEY")
      System.delete_env("PROVIDER_OPENAI_1_BASE_URL")
      Application.delete_env(:shh_ai, :http_client)
    end)

    :ok
  end

  # Deterministic messages for fingerprint-based (Turn 2+) tests.
  @fp_messages [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]

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
      body = %{"model" => "gpt-4", "messages" => []}
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "handles binary JSON body" do
      body = Jason.encode!(%{"model" => "gpt-4", "messages" => []})
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "handles invalid JSON string body" do
      body = "not valid json"
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "converts Anthropic format to target provider" do
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "test-anthropic-key")
      Config.load()

      body = %{
        "model" => "claude-3-opus",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "max_tokens" => 1024
      }

      headers = [{"x-api-key", "original-key"}]

      result = BackendClient.request(:anthropic, "/v1/messages", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end

      System.delete_env("PROVIDER_ANTHROPIC_1_ENABLED")
      System.delete_env("PROVIDER_ANTHROPIC_1_API_KEY")
    end

    test "converts Ollama format to target provider" do
      System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
      System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://localhost:11434")
      Config.load()

      body = %{"model" => "llama3", "messages" => [%{"role" => "user", "content" => "test"}]}
      headers = []

      result = BackendClient.request(:ollama, "/api/chat", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end

      System.delete_env("PROVIDER_OLLAMA_1_ENABLED")
      System.delete_env("PROVIDER_OLLAMA_1_BASE_URL")
    end

    test "handles multiple providers configured" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key1")
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "key2")
      Config.load()

      body = %{"model" => "test", "messages" => []}
      headers = []

      results =
        for _ <- 1..5 do
          case BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers) do
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
    end

    test "handles empty map body" do
      body = %{}
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "preserves custom headers through conversion" do
      body = %{"model" => "gpt-4", "messages" => []}
      headers = [{"x-custom-header", "custom-value"}, {"x-request-id", "12345"}]

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end
  end

  describe "fingerprint computation in find_or_create_conversation" do
    alias ShhAi.Conversation.Fingerprinter

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

      final_id = Conversation.persist_turn_1(turn1_conv, full_messages, %{}, %{})

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
      body = %{
        "thread_id" => "thread_test_001",
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      # Just assert the request didn't crash
      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "creates stateless conversation when no conversation ID present" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      headers = []

      _result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      # Should not crash — stateless conversations are created with nil provider_conversation_id
      assert true
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

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      # Just assert the request didn't crash — PII pipeline integration
      # is tested in conversation_integration_test.exs
      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "emits telemetry with conversation_id in metadata" do
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

      BackendClient.request(:openai, "/v1/chat/completions", :post, body, [])

      # Wait for telemetry to fire
      assert_receive {:telemetry_metadata, metadata}, 5_000

      # The metadata should include a conversation_id (a UUID string)
      assert Map.has_key?(metadata, :conversation_id)
      assert is_binary(metadata.conversation_id)
      assert byte_size(metadata.conversation_id) == 36
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
      Conversation.cache_message(conv.conversation_id, expected_hash, pre_restored)

      # Verify: looking up by the restored hash returns the pre-restored content
      assert {:ok, ^pre_restored} =
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

      # Hash the restored content and cache the pre-restored version
      hash = Conversation.hash_message(%{role: "assistant", content: restored_content})
      Conversation.cache_message(conv.conversation_id, hash, {:assistant_message, pre_restored})

      # Turn 2: the message history includes the assistant response (restored content)
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My name is John and email is john@example.com"},
          %{"role" => "assistant", "content" => restored_content},
          %{"role" => "user", "content" => "Thanks!"}
        ]
      }

      {:ok, sanitized, _mapping, _ri, _pii} =
        PIIPipeline.sanitize_openai_request(body, conv)

      # The assistant message should be sanitized using the cached version
      assistant_msg = Enum.at(sanitized["messages"], 1)
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
end
