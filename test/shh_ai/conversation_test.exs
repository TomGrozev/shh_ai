defmodule ShhAi.ConversationTest do
  # async: false because the Conversation module reads and writes the
  # shared named ETS tables (:conversations, :conversation_mappings,
  # :conversation_reverse_index) and tests touching them must not race.
  use ExUnit.Case, async: false

  alias ShhAi.Conversation

  setup do
    ShhAi.ConversationCase.setup_ets()
  end

  # Deterministic messages for fingerprint-based (Turn 2+) tests.
  @fp_messages [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]

  # Helper to call find_or_create with the old single-arg API style (map with
  # :fingerprint key) by splitting it into the new two-arg form.
  defp find_or_create(%{fingerprint: nil} = input) do
    attrs = Map.drop(input, [:fingerprint])
    Conversation.find_or_create([], attrs)
  end

  defp find_or_create(%{fingerprint: _fp} = input) do
    attrs = Map.drop(input, [:fingerprint])
    Conversation.find_or_create(@fp_messages, attrs)
  end

  describe "hash_message/1" do
    test "produces a deterministic SHA-256 hex of role + string content" do
      msg = %{role: "user", content: "Hello world"}

      hash = Conversation.hash_message(msg)

      # SHA-256 hex is always 64 lowercase hex characters
      assert is_binary(hash)
      assert byte_size(hash) == 64
      assert hash == String.downcase(hash)
      assert String.match?(hash, ~r/^[0-9a-f]{64}$/)

      # Specific value: SHA-256 of "user" <> "Hello world"
      assert hash ==
               "ac0d95c35a3b6aa59bd3ecc83f1139731a0da4937273005fe33600c390076d00"
    end

    test "concatenates content parts list with part count for differentiability" do
      string_msg = %{role: "assistant", content: "Hello world"}

      parts_msg = %{
        role: "assistant",
        content: [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "text", "text" => " world"}
        ]
      }

      # Parts messages now include part count to differentiate messages with
      # different non-text content (images, tool calls, etc.)
      assert Conversation.hash_message(string_msg) != Conversation.hash_message(parts_msg)

      # Specific value: SHA-256 of "assistant" <> "Hello world"
      assert Conversation.hash_message(string_msg) ==
               "36bc06aa278af058aff42c20d7e26bff4a70be3fdc0f397146d877337975ea3a"

      # Parts messages with same content and part count produce the same hash
      parts_msg2 = %{
        role: "assistant",
        content: [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "text", "text" => " world"}
        ]
      }

      assert Conversation.hash_message(parts_msg) == Conversation.hash_message(parts_msg2)
    end

    test "is deterministic — same input always produces the same hash" do
      msg = %{role: "user", content: "Hello world"}

      assert Conversation.hash_message(msg) == Conversation.hash_message(msg)
      assert Conversation.hash_message(msg) == Conversation.hash_message(msg)
    end

    test "different role produces a different hash for the same content" do
      user_msg = %{role: "user", content: "Hello world"}
      assistant_msg = %{role: "assistant", content: "Hello world"}

      refute Conversation.hash_message(user_msg) == Conversation.hash_message(assistant_msg)
    end

    test "different content produces a different hash for the same role" do
      msg_a = %{role: "user", content: "Hello world"}
      msg_b = %{role: "user", content: "Hello there"}

      refute Conversation.hash_message(msg_a) == Conversation.hash_message(msg_b)
    end
  end

  describe "find_or_create/2" do
    test "returns a %Conversation{} struct with new?: true on basic creation" do
      attrs = %{
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      assert {:ok, %Conversation{new?: true}} = Conversation.find_or_create([], attrs)
    end

    test "generates a UUID for conversation_id" do
      input = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, %{conversation_id: conversation_id}} = find_or_create(input)

      assert is_binary(conversation_id)
      # Standard UUID v4 format: 8-4-4-4-12 hex characters with hyphens
      assert byte_size(conversation_id) == 36

      assert String.match?(
               conversation_id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
             )
    end

    test "generates a unique conversation_id for each call when fingerprint is nil" do
      input1 = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      input2 = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_def456"
      }

      {:ok, %{conversation_id: id1}} = find_or_create(input1)
      {:ok, %{conversation_id: id2}} = find_or_create(input2)

      refute id1 == id2
    end

    test "always creates a new Conversation when fingerprint is nil, even with the same provider_conversation_id" do
      input = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv1} = find_or_create(input)
      {:ok, conv2} = find_or_create(input)

      # Always creates new — different conversation IDs.
      refute conv1.conversation_id == conv2.conversation_id
      assert conv1.new? == true
      assert conv2.new? == true
    end

    test "populates source_provider and provider_conversation_id from input" do
      input = %{
        fingerprint: nil,
        source_provider: :anthropic,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      assert conv.source_provider == :anthropic
      assert conv.provider_conversation_id == "thread_abc123"
    end

    test "initializes mapping, reverse_index, created_at and last_active_at" do
      input = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      assert conv.mapping == %{}
      assert conv.reverse_index == %{}
      assert is_integer(conv.created_at)
      assert is_integer(conv.last_active_at)
      assert conv.created_at == conv.last_active_at
    end

    # ---------------------------------------------------------------------------
    # Fingerprint-based lookup (Turn 2+)
    # ---------------------------------------------------------------------------

    test "Turn 2+ with existing fingerprint returns existing conversation with new?: false" do
      msgs = [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]

      # Turn 1: create a conversation with messages (computes fingerprint internally)
      {:ok, conv1} =
        Conversation.find_or_create(msgs, %{
          source_provider: :openai,
          provider_conversation_id: "thread_fp_001"
        })

      assert conv1.new? == true

      # Turn 2: look up the same messages — should find the existing conversation
      {:ok, conv2} =
        Conversation.find_or_create(msgs, %{
          source_provider: :openai,
          provider_conversation_id: "thread_fp_001"
        })

      assert conv2.new? == false
      assert conv2.conversation_id == conv1.conversation_id
    end

    test "Turn 2+ with new fingerprint creates a new conversation with new?: true" do
      msgs_a = [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi"}]
      msgs_b = [%{role: "user", content: "Goodbye"}, %{role: "assistant", content: "Bye"}]

      {:ok, conv_a} =
        Conversation.find_or_create(msgs_a, %{
          source_provider: :openai,
          provider_conversation_id: "thread_fp_a"
        })

      {:ok, conv_b} =
        Conversation.find_or_create(msgs_b, %{
          source_provider: :openai,
          provider_conversation_id: "thread_fp_b"
        })

      assert conv_a.new? == true
      assert conv_b.new? == true
      refute conv_a.conversation_id == conv_b.conversation_id
    end

    test "Turn 1 with nil fingerprint always creates a new conversation" do
      {:ok, conv1} =
        Conversation.find_or_create([], %{
          source_provider: :openai,
          provider_conversation_id: "thread_nil_001"
        })

      {:ok, conv2} =
        Conversation.find_or_create([], %{
          source_provider: :openai,
          provider_conversation_id: "thread_nil_001"
        })

      assert conv1.new? == true
      assert conv2.new? == true
      refute conv1.conversation_id == conv2.conversation_id
    end
  end

  describe "delegated functions" do
    test "add_mapping/3 returns :ok" do
      # The function no longer validates the conversation exists; for an
      # unknown conv_id with empty maps, the function still returns :ok.
      assert :ok = Conversation.add_mapping("conv_id", %{}, %{})
    end

    test "add_mapping/3 returns :ok for a real conversation" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      assert :ok =
               Conversation.add_mapping(
                 conv.conversation_id,
                 %{"EMAIL_1" => "john@example.com"},
                 %{{"john@example.com", :email} => "EMAIL_1"}
               )
    end

    test "get_mapping/1 returns {:ok, %{}} for a newly-created conversation with no mappings" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)
      assert {:ok, %{}} = Conversation.get_mapping(conv.conversation_id)
    end

    test "get_mapping/1 returns {:ok, mapping} after add_mapping" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      Conversation.add_mapping(
        conv.conversation_id,
        %{"EMAIL_1" => "john@example.com"},
        %{{"john@example.com", :email} => "EMAIL_1"}
      )

      assert {:ok, %{"EMAIL_1" => "john@example.com"}} =
               Conversation.get_mapping(conv.conversation_id)
    end

    test "get_mapping/1 returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = Conversation.get_mapping("nonexistent_uuid")
    end

    test "get_reverse_index/1 returns {:ok, %{}} for a newly-created conversation with no reverse index entries" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)
      assert {:ok, %{}} = Conversation.get_reverse_index(conv.conversation_id)
    end

    test "get_reverse_index/1 returns {:ok, reverse_index} after add_mapping/3" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      Conversation.add_mapping(
        conv.conversation_id,
        %{"EMAIL_1" => "john@example.com"},
        %{{"john@example.com", :email} => "EMAIL_1"}
      )

      assert {:ok, %{{"john@example.com", :email} => "EMAIL_1"}} =
               Conversation.get_reverse_index(conv.conversation_id)
    end

    test "get_reverse_index/1 returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = Conversation.get_reverse_index("nonexistent_uuid")
    end

    # ---------------------------------------------------------------------------
    # Slice 6: lookup_placeholder/3
    # ---------------------------------------------------------------------------

    test "lookup_placeholder/3 returns {:error, :not_found} for a non-existent conversation" do
      assert Conversation.lookup_placeholder("nonexistent_uuid", "value", :email) ==
               {:error, :not_found}
    end

    test "lookup_placeholder/3 returns {:error, :not_found} when the PII value has not been seen" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      assert Conversation.lookup_placeholder(
               conv.conversation_id,
               "jane@example.com",
               :email
             ) == {:error, :not_found}
    end

    test "lookup_placeholder/3 returns {:ok, placeholder} for a previously-seen PII value" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      :ok =
        Conversation.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert Conversation.lookup_placeholder(
               conv.conversation_id,
               "john@example.com",
               :email
             ) == {:ok, "EMAIL_1"}
    end

    test "lookup_placeholder/3 distinguishes by pii_type — same value under a different type is not found" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)

      :ok =
        Conversation.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      # Same original value, different PII type — must be :not_found.
      assert Conversation.lookup_placeholder(
               conv.conversation_id,
               "john@example.com",
               :person
             ) == {:error, :not_found}
    end

    test "lookup_placeholder/3 does not bleed across conversations" do
      input_a = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_a"
      }

      input_b = %{
        fingerprint: nil,
        source_provider: :openai,
        provider_conversation_id: "thread_b"
      }

      {:ok, conv_a} = find_or_create(input_a)
      {:ok, conv_b} = find_or_create(input_b)

      :ok =
        Conversation.add_mapping(
          conv_a.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      # The same original value/type pair in conv_b has not been seen yet.
      assert Conversation.lookup_placeholder(
               conv_b.conversation_id,
               "john@example.com",
               :email
             ) == {:error, :not_found}
    end

    test "touch/1 returns :ok for a real conversation" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)
      assert :ok = Conversation.touch(conv.conversation_id)
    end

    test "touch/1 returns {:error, :not_found} for a non-existent conversation" do
      assert Conversation.touch("nonexistent_uuid") == {:error, :not_found}
    end

    test "delete/1 returns :ok for a non-existent conversation (idempotent)" do
      # Deleting a missing key is a no-op, not an error.
      assert :ok = Conversation.delete("nonexistent_uuid")
    end

    test "delete/1 removes a real conversation" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)
      assert :ok = Conversation.delete(conv.conversation_id)

      # And subsequent lookups return :not_found. (get_reverse_index/1 lives
      # on the Conversation.Store module, not on Conversation — the equivalent
      # end-to-end checks are covered in ets_test.exs.)
      assert Conversation.get_mapping(conv.conversation_id) == {:error, :not_found}
    end

    # ---------------------------------------------------------------------------
    # update_fingerprint/2
    # ---------------------------------------------------------------------------

    test "update_fingerprint/2 returns :ok for a real conversation" do
      # Use a fingerprint so the conversation is persisted to ETS
      fingerprint = "abc123def456"

      input = %{
        fingerprint: fingerprint,
        source_provider: :openai,
        provider_conversation_id: "thread_abc123"
      }

      {:ok, conv} = find_or_create(input)
      assert :ok = Conversation.update_fingerprint(conv.conversation_id, "some_hash")
    end
  end

  describe "message cache" do
    test "cache_message/3 returns :ok for a real conversation" do
      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})
      hash = Conversation.hash_message(%{role: "user", content: "Hello"})
      assert :ok = Conversation.cache_message(conv.conversation_id, hash, "sanitized content")
    end

    test "lookup_message/2 returns {:ok, content} for a cached message" do
      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})
      hash = Conversation.hash_message(%{role: "user", content: "Hello"})

      :ok = Conversation.cache_message(conv.conversation_id, hash, "cached sanitized text")

      assert {:ok, "cached sanitized text"} =
               Conversation.lookup_message(conv.conversation_id, hash)
    end

    test "lookup_message/2 returns {:error, :not_found} for a non-cached message" do
      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})
      hash = Conversation.hash_message(%{role: "user", content: "Never cached"})

      assert {:error, :not_found} = Conversation.lookup_message(conv.conversation_id, hash)
    end

    test "cache_message/3 stores complex terms (tuples)" do
      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})
      hash = Conversation.hash_message(%{role: "user", content: "My email is john@example.com"})

      cached_value =
        {"My email is <EMAIL_1>", %{{:email, 1} => "john@example.com"},
         %{{"john@example.com", :email} => {:email, 1}}, {1, 0}}

      :ok = Conversation.cache_message(conv.conversation_id, hash, cached_value)
      assert {:ok, ^cached_value} = Conversation.lookup_message(conv.conversation_id, hash)
    end

    test "message cache does not bleed across conversations" do
      {:ok, conv_a} = Conversation.find_or_create([], %{source_provider: :openai})
      {:ok, conv_b} = Conversation.find_or_create([], %{source_provider: :openai})

      hash = Conversation.hash_message(%{role: "user", content: "Hello"})
      :ok = Conversation.cache_message(conv_a.conversation_id, hash, "conv_a cached")

      assert {:ok, "conv_a cached"} = Conversation.lookup_message(conv_a.conversation_id, hash)
      assert {:error, :not_found} = Conversation.lookup_message(conv_b.conversation_id, hash)
    end

    test "message cache is cleaned up when conversation is deleted" do
      {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})
      hash = Conversation.hash_message(%{role: "user", content: "Hello"})

      :ok = Conversation.cache_message(conv.conversation_id, hash, "cached")
      assert {:ok, "cached"} = Conversation.lookup_message(conv.conversation_id, hash)

      :ok = Conversation.delete(conv.conversation_id)

      # After deletion, the cache entry should be gone too
      assert {:error, :not_found} = Conversation.lookup_message(conv.conversation_id, hash)
    end
  end
end
