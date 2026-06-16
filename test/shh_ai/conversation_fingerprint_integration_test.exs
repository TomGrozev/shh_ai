defmodule ShhAi.ConversationFingerprintIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for the full fingerprint-based
  conversation lifecycle.

  Exercises the complete flow: Turn 1 (in-memory) → finalization →
  fingerprint derivation → UUID v5 persistence → Turn 2+ (fingerprint-based
  lookup) → cross-provider continuity → stable multi-turn conversation
  identity → cleanup.

  Key invariant: `fingerprint_for_lookup/1` derives from the first exchange
  only (first user + first assistant), so the conversation ID is stable after
  Turn 1 finalization — no ETS key migration each turn.
  """

  use ExUnit.Case, async: false

  alias ShhAi.Conversation
  alias ShhAi.ConversationFingerprinter
  alias ShhAi.ConversationStore
  alias ShhAi.ConversationStore.ETS, as: ETSStore
  alias ShhAi.BackendClient.FingerprintFinalizer

  setup do
    :ok = ETSStore.init()

    :ets.delete_all_objects(:conversations)
    :ets.delete_all_objects(:conversation_mappings)
    :ets.delete_all_objects(:conversation_reverse_index)
    :ets.delete_all_objects(:conversation_message_cache)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Simulates the full Turn 1 flow: create in-memory conversation,
  # finalize with FingerprintFinalizer, return the final ID.
  defp finalize_turn1(messages) do
    {:ok, conversation} = Conversation.find_or_create(nil, %{source_provider: :openai})
    mapping = %{{:email, 1} => "john@example.com"}
    reverse_index = %{{"john@example.com", :email} => {:email, 1}}
    final_id = FingerprintFinalizer.finalize_turn_1(conversation, messages, mapping, reverse_index)
    {final_id, mapping}
  end

  # Computes the lookup fingerprint for a message list.
  defp compute_lookup_fingerprint(messages) do
    ConversationFingerprinter.fingerprint_for_lookup(messages)
  end

  # ---------------------------------------------------------------------------
  # Test 1: Turn 1 deferred storage
  # ---------------------------------------------------------------------------

  describe "Turn 1 deferred storage" do
    test "Turn 1 find_or_create returns in-memory struct without ETS persistence" do
      attrs = %{source_provider: :openai}
      {:ok, conversation} = Conversation.find_or_create(nil, attrs)

      assert conversation.new? == true
      assert conversation.conversation_id != nil

      # Verify NOT in ETS
      assert ConversationStore.get_conversation(conversation.conversation_id) ==
               {:error, :not_found}
    end

    test "Turn 1 finalization persists conversation with UUID v5 from first-exchange fingerprint" do
      # Simulate Turn 1: create in-memory conversation
      attrs = %{source_provider: :openai}
      {:ok, conversation} = Conversation.find_or_create(nil, attrs)

      # Simulate response with user + assistant messages
      user_msg = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_msg = %{"role" => "assistant", "content" => "Got it"}
      messages = [user_msg, assistant_msg]

      mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      # Finalize Turn 1
      final_id =
        FingerprintFinalizer.finalize_turn_1(conversation, messages, mapping, reverse_index)

      # Verify persisted with UUID v5
      assert final_id != conversation.conversation_id
      assert ConversationStore.get_conversation(final_id) != {:error, :not_found}

      # Verify fingerprint is from first exchange (first 2 messages)
      expected_fingerprint = ConversationFingerprinter.fingerprint_for_lookup(messages)
      expected_id = ConversationFingerprinter.derive_conversation_id(expected_fingerprint)
      assert final_id == expected_id

      # Verify mapping was persisted
      {:ok, stored_mapping} = ConversationStore.get_mapping(final_id)
      assert stored_mapping[{:email, 1}] == "john@example.com"
    end

    test "Turn 1 restore uses mapping from opts, not ETS" do
      # Create in-memory conversation (not in ETS)
      {:ok, conversation} = Conversation.find_or_create(nil, %{source_provider: :openai})

      mapping = %{"EMAIL_1" => "john@example.com"}

      # Restore with mapping in opts (placeholder must have angle brackets)
      response = %{"choices" => [%{"message" => %{"content" => "Your email is <EMAIL_1>"}}]}

      {:ok, restored} =
        ShhAi.PIIPipeline.restore_openai_response(response, conversation, mapping: mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) ==
               "Your email is john@example.com"
    end

    test "Turn 1 sanitize skips message cache and ETS writes" do
      # Create in-memory conversation (not in ETS)
      {:ok, conversation} = Conversation.find_or_create(nil, %{source_provider: :openai})
      messages = [%{"role" => "user", "content" => "My email is john@example.com"}]

      {:ok, sanitized, _mapping, _reverse_index, pii_info} =
        ShhAi.PIIPipeline.sanitize_openai_request(%{"messages" => messages}, conversation)

      # Verify sanitized
      assert hd(sanitized["messages"])["content"] =~ "EMAIL_"

      # Verify PII was detected
      assert pii_info.detected_count >= 1
    end

    test "Turn 2+ finds conversation by fingerprint" do
      # Turn 1: finalize
      {:ok, conversation} = Conversation.find_or_create(nil, %{source_provider: :openai})
      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"},
        %{"role" => "assistant", "content" => "Got it"}
      ]

      mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}
      final_id = FingerprintFinalizer.finalize_turn_1(conversation, messages, mapping, reverse_index)

      # Turn 2: lookup by fingerprint
      turn2_messages =
        messages ++ [%{"role" => "user", "content" => "What's my email?"}]

      turn2_fp = ConversationFingerprinter.fingerprint_for_lookup(turn2_messages)

      {:ok, turn2_conversation} =
        Conversation.find_or_create(turn2_fp, %{source_provider: :openai})

      assert turn2_conversation.conversation_id == final_id
      assert turn2_conversation.new? == false
    end

    test "3+ turns keep single ETS row (no migration)" do
      # Turn 1
      {:ok, conversation} = Conversation.find_or_create(nil, %{source_provider: :openai})

      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"},
        %{"role" => "assistant", "content" => "Got it"}
      ]

      final_id = FingerprintFinalizer.finalize_turn_1(conversation, messages, %{}, %{})

      # Turn 2
      turn2_messages =
        messages ++
          [
            %{"role" => "user", "content" => "What's my email?"},
            %{"role" => "assistant", "content" => "It's EMAIL_1"}
          ]

      turn2_fp = ConversationFingerprinter.fingerprint_for_lookup(turn2_messages)

      {:ok, turn2_conversation} =
        Conversation.find_or_create(turn2_fp, %{source_provider: :openai})

      FingerprintFinalizer.update_existing(turn2_conversation, turn2_messages)

      # Turn 3
      turn3_messages =
        turn2_messages ++
          [
            %{"role" => "user", "content" => "Thanks"},
            %{"role" => "assistant", "content" => "You're welcome"}
          ]

      turn3_fp = ConversationFingerprinter.fingerprint_for_lookup(turn3_messages)

      {:ok, turn3_conversation} =
        Conversation.find_or_create(turn3_fp, %{source_provider: :openai})

      FingerprintFinalizer.update_existing(turn3_conversation, turn3_messages)

      # Verify single ETS row
      assert turn3_conversation.conversation_id == final_id

      assert ConversationStore.get_conversation(final_id) != {:error, :not_found}
    end

    test "Turn 1 streaming finalization persists with UUID v5" do
      {:ok, conversation} = Conversation.find_or_create(nil, %{source_provider: :openai})

      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"},
        %{"role" => "assistant", "content" => "Got it"}
      ]

      mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      final_id =
        FingerprintFinalizer.finalize_turn_1(conversation, messages, mapping, reverse_index)

      assert ConversationStore.get_conversation(final_id) != {:error, :not_found}

      # Verify mapping was persisted
      {:ok, stored_mapping} = ConversationStore.get_mapping(final_id)
      assert stored_mapping[{:email, 1}] == "john@example.com"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2: Turn 1 → Turn 2 lifecycle
  # ---------------------------------------------------------------------------

  describe "fingerprint-based conversation lifecycle" do
    test "Turn 1 finalizes to UUID v5, Turn 2 finds it by fingerprint" do
      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Got it, I'll note your email."}

      # Turn 1: create in-memory and finalize
      {v5_id, _mapping} = finalize_turn1([user_a, assistant_1])

      # The ID should be a UUID v5 (deterministic from fingerprint)
      assert is_binary(v5_id)
      assert byte_size(v5_id) == 36

      # Verify persisted in ETS
      assert {:ok, _} = Conversation.get_mapping(v5_id)

      # --- Turn 2: find by fingerprint ---
      lookup_fp = compute_lookup_fingerprint([user_a, assistant_1])

      {:ok, turn2} =
        Conversation.find_or_create(lookup_fp, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn2.new? == false
      assert turn2.conversation_id == v5_id

      # The mapping from Turn 1 is still present
      {:ok, mapping} = Conversation.get_mapping(turn2.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
    end

    test "modified message history starts a new conversation" do
      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Noted."}

      # Turn 1: create and finalize
      {original_v5_id, _mapping} = finalize_turn1([user_a, assistant_1])

      # --- Turn 2: modified prior message ---
      modified_user_a = %{"role" => "user", "content" => "My email is jane@example.org"}
      modified_fp = compute_lookup_fingerprint([modified_user_a, assistant_1])

      {:ok, turn2} =
        Conversation.find_or_create(modified_fp, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      # New conversation — different fingerprint means different UUID v5
      assert turn2.new? == true
      assert turn2.conversation_id != original_v5_id

      # The old conversation still exists with its mapping
      {:ok, old_mapping} = Conversation.get_mapping(original_v5_id)
      assert old_mapping[{:email, 1}] == "john@example.com"
    end

    test "cross-provider continuity — same fingerprint finds same conversation" do
      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Noted."}

      # Turn 1 via :openai
      {v5_id, _mapping} = finalize_turn1([user_a, assistant_1])

      # --- Turn 2 via :anthropic with the same fingerprint ---
      lookup_fp = compute_lookup_fingerprint([user_a, assistant_1])

      {:ok, turn2} =
        Conversation.find_or_create(lookup_fp, %{
          source_provider: :anthropic,
          provider_conversation_id: nil
        })

      # Same conversation found — fingerprint-based lookup is provider-agnostic
      assert turn2.new? == false
      assert turn2.conversation_id == v5_id

      # The mapping is reused across providers
      {:ok, mapping} = Conversation.get_mapping(turn2.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
    end

    test "Turn 3+ maintains stable conversation ID via first-exchange fingerprint" do
      # --- Turn 1: user message A ---
      user_a = %{"role" => "user", "content" => "Hello, I need help"}
      assistant_1 = %{"role" => "assistant", "content" => "Sure, how can I help?"}

      {v5_id_turn1, _mapping} = finalize_turn1([user_a, assistant_1])

      # --- Turn 2: add user message C ---
      user_c = %{"role" => "user", "content" => "My email is john@example.com"}
      lookup_fp_turn2 = compute_lookup_fingerprint([user_a, assistant_1])

      {:ok, turn2} =
        Conversation.find_or_create(lookup_fp_turn2, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn2.new? == false
      assert turn2.conversation_id == v5_id_turn1

      # Simulate Turn 2 response
      assistant_2 = %{"role" => "assistant", "content" => "Got it, john@example.com noted."}
      FingerprintFinalizer.update_existing(turn2, [user_a, assistant_1, user_c, assistant_2])

      # --- Turn 3: add user message D ---
      _user_d = %{"role" => "user", "content" => "Also add jane@example.org"}
      lookup_fp_turn3 = compute_lookup_fingerprint([user_a, assistant_1, user_c, assistant_2])

      {:ok, turn3} =
        Conversation.find_or_create(lookup_fp_turn3, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn3.new? == false
      assert turn3.conversation_id == v5_id_turn1

      # The mapping from Turn 1 is still present
      {:ok, mapping} = Conversation.get_mapping(turn3.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
    end

    test "cleanup removes expired conversations and their fingerprints" do
      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Noted."}

      # Turn 1: create and finalize
      {v5_id, _mapping} = finalize_turn1([user_a, assistant_1])

      # Verify the conversation exists
      assert {:ok, _} = Conversation.get_mapping(v5_id)

      # Backdate last_active_at to a very negative value so cleanup_expired(0)
      # evicts it.
      past_time = System.monotonic_time(:millisecond) - 999_999_999_999

      case :ets.lookup(:conversations, v5_id) do
        [{^v5_id, sp, created_at, _old_laa, pci, fp_hash}] ->
          :ets.insert(:conversations, {v5_id, sp, created_at, past_time, pci, fp_hash})

        [] ->
          flunk("Conversation #{v5_id} not found in ETS before backdating")
      end

      # Cleanup with TTL of 0ms — the backdated conversation is expired
      evicted = ETSStore.cleanup_expired(0)
      assert evicted >= 1

      # The conversation is gone
      assert {:error, :not_found} = Conversation.get_mapping(v5_id)

      # A new find_or_create with the same fingerprint creates a new conversation
      lookup_fp = compute_lookup_fingerprint([user_a, assistant_1])

      {:ok, new_turn} =
        Conversation.find_or_create(lookup_fp, %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      # It's a fresh conversation (new?: true) with the same deterministic ID
      # (because the fingerprint is the same, UUID v5 is deterministic)
      assert new_turn.new? == true
      assert new_turn.conversation_id == v5_id

      # But it has no mapping — the old mapping was evicted
      {:ok, empty_mapping} = Conversation.get_mapping(new_turn.conversation_id)
      assert empty_mapping == %{}
    end
  end
end
