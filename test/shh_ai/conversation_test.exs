defmodule ShhAi.ConversationTest do
  # async: false because the Conversation module reads and writes the
  # shared named ETS tables (:conversations, :conversation_mappings,
  # :conversation_reverse_index) and tests touching them must not race.
  use ExUnit.Case, async: false

  alias ShhAi.Conversation
  alias ShhAi.ConversationStore.ETS, as: ETSStore

  setup do
    # The ETS backend must be initialised so the named tables exist before
    # find_or_create/1 (which calls :ets.match_object under the hood) runs.
    ETSStore.init()

    # Wipe rows so each test starts from a clean slate — the tables are
    # node-global and shared with other test files.
    :ets.delete_all_objects(:conversations)
    :ets.delete_all_objects(:conversation_mappings)
    :ets.delete_all_objects(:conversation_reverse_index)

    :ok
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

    test "concatenates content parts list to the same hash as the equivalent string" do
      string_msg = %{role: "assistant", content: "Hello world"}

      parts_msg = %{
        role: "assistant",
        content: [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "text", "text" => " world"}
        ]
      }

      assert Conversation.hash_message(string_msg) == Conversation.hash_message(parts_msg)

      # Specific value: SHA-256 of "assistant" <> "Hello world"
      assert Conversation.hash_message(string_msg) ==
               "36bc06aa278af058aff42c20d7e26bff4a70be3fdc0f397146d877337975ea3a"
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

  describe "find_or_create/1" do
    test "returns a %Conversation{} struct with new?: true on basic creation" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      assert %Conversation{new?: true} = Conversation.find_or_create(input)
    end

    test "generates a UUID for conversation_id" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      %{conversation_id: conversation_id} = Conversation.find_or_create(input)

      assert is_binary(conversation_id)
      # Standard UUID v4 format: 8-4-4-4-12 hex characters with hyphens
      assert byte_size(conversation_id) == 36

      assert String.match?(
               conversation_id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
             )
    end

    test "generates a unique conversation_id for each call when provider_conversation_id differs" do
      input1 = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      input2 = %{
        fingerprint_result: {:stateful, "thread_def456"},
        source_provider: :openai
      }

      %{conversation_id: id1} = Conversation.find_or_create(input1)
      %{conversation_id: id2} = Conversation.find_or_create(input2)

      refute id1 == id2
    end

    test "always creates a new Conversation even with the same provider_conversation_id" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv1 = Conversation.find_or_create(input)
      conv2 = Conversation.find_or_create(input)

      # Always creates new — different conversation IDs.
      refute conv1.conversation_id == conv2.conversation_id
      assert conv1.new? == true
      assert conv2.new? == true
    end

    test "populates source_provider and provider_conversation_id from input" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :anthropic
      }

      conv = Conversation.find_or_create(input)

      assert conv.source_provider == :anthropic
      assert conv.provider_conversation_id == "thread_abc123"
    end

    test "initializes mapping, reverse_index, created_at and last_active_at" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)

      assert conv.mapping == %{}
      assert conv.reverse_index == %{}
      assert is_integer(conv.created_at)
      assert is_integer(conv.last_active_at)
      assert conv.created_at == conv.last_active_at
    end
  end

  describe "delegated functions" do
    test "add_mapping/3 returns :ok" do
      # The function no longer validates the conversation exists; for an
      # unknown conv_id with empty maps, the function still returns :ok.
      assert :ok = Conversation.add_mapping("conv_id", %{}, %{})
    end

    test "add_mapping/3 returns :ok for a real conversation" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)

      assert :ok =
               Conversation.add_mapping(
                 conv.conversation_id,
                 %{"EMAIL_1" => "john@example.com"},
                 %{{"john@example.com", :email} => "EMAIL_1"}
               )
    end

    test "get_mapping/1 returns {:ok, %{}} for a newly-created conversation with no mappings" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)
      assert {:ok, %{}} = Conversation.get_mapping(conv.conversation_id)
    end

    test "get_mapping/1 returns {:ok, mapping} after add_mapping" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)

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

    # ---------------------------------------------------------------------------
    # Slice 6: lookup_placeholder/3
    # ---------------------------------------------------------------------------

    test "lookup_placeholder/3 returns {:error, :not_found} for a non-existent conversation" do
      assert Conversation.lookup_placeholder("nonexistent_uuid", "value", :email) ==
               {:error, :not_found}
    end

    test "lookup_placeholder/3 returns {:error, :not_found} when the PII value has not been seen" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)

      assert Conversation.lookup_placeholder(
               conv.conversation_id,
               "jane@example.com",
               :email
             ) == {:error, :not_found}
    end

    test "lookup_placeholder/3 returns {:ok, placeholder} for a previously-seen PII value" do
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)

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
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)

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
        fingerprint_result: {:stateful, "thread_a"},
        source_provider: :openai
      }

      input_b = %{
        fingerprint_result: {:stateful, "thread_b"},
        source_provider: :openai
      }

      conv_a = Conversation.find_or_create(input_a)
      conv_b = Conversation.find_or_create(input_b)

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
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)
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
      input = %{
        fingerprint_result: {:stateful, "thread_abc123"},
        source_provider: :openai
      }

      conv = Conversation.find_or_create(input)
      assert :ok = Conversation.delete(conv.conversation_id)

      # And subsequent lookups return :not_found. (get_reverse_index/1 lives
      # on the ConversationStore module, not on Conversation — the equivalent
      # end-to-end checks are covered in ets_test.exs.)
      assert Conversation.get_mapping(conv.conversation_id) == {:error, :not_found}
    end
  end
end
