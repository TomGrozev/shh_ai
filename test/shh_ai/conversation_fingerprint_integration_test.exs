defmodule ShhAi.ConversationFingerprintIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for the full fingerprint-based
  conversation lifecycle.

  Exercises the complete flow: Turn 1 (UUID v4) → response → fingerprint
  derivation → UUID v5 migration → Turn 2+ (fingerprint-based lookup) →
  cross-provider continuity → multi-turn fingerprint updates → cleanup.

  Validates that `Conversation.find_or_create/2`, `migrate_id/2`,
  `update_fingerprint/2`, and `ConversationFingerprinter` work together
  correctly across the full request lifecycle.
  """

  use ExUnit.Case, async: false

  alias ShhAi.Conversation
  alias ShhAi.ConversationFingerprinter
  alias ShhAi.ConversationStore.ETS, as: ETSStore

  setup do
    :ok = ETSStore.init()

    :ets.delete_all_objects(:conversations)
    :ets.delete_all_objects(:conversation_mappings)
    :ets.delete_all_objects(:conversation_reverse_index)

    :ok
  end

  # Helper to call find_or_create with the old single-arg API style (map with
  # :fingerprint key) by splitting it into the new two-arg form.
  defp find_or_create(%{fingerprint: fp} = input) do
    attrs = Map.drop(input, [:fingerprint])
    Conversation.find_or_create(fp, attrs)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Simulates the BackendClient's post-response flow: computes a fingerprint
  # from the full message history (including the assistant response), derives
  # a UUID v5, migrates the conversation from old_id to the new UUID v5, and
  # updates the stored fingerprint hash.
  #
  # Returns the new UUID v5 conversation_id and the fingerprint hash.
  defp simulate_response_and_migrate(conversation, messages_including_response) do
    fingerprint = ConversationFingerprinter.fingerprint_messages(messages_including_response)
    new_id = ConversationFingerprinter.derive_conversation_id(fingerprint)

    :ok = Conversation.migrate_id(conversation.conversation_id, new_id)
    :ok = Conversation.update_fingerprint(new_id, fingerprint)

    {new_id, fingerprint}
  end

  # Computes the fingerprint for the *next* turn's lookup, which is
  # messages[0..-2] — i.e., all prior messages except the last user message
  # that hasn't been responded to yet. In the real proxy, the BackendClient
  # sends messages[0..-2] as the fingerprint input because the last message
  # is the current turn's user message.
  #
  # But for Turn 2 lookup, the fingerprint should be based on the messages
  # that existed *before* the current turn's user message — which is exactly
  # the full history from the previous turn (including the assistant response).
  # So `messages[0..-2]` for Turn 2 would be [user_A, assistant_1], which
  # is the same as what we fingerprinted after Turn 1's response.
  #
  # This helper just calls `fingerprint_messages` on the given list.
  defp compute_lookup_fingerprint(messages) do
    ConversationFingerprinter.fingerprint_messages(messages)
  end

  # ---------------------------------------------------------------------------
  # Test 1: Turn 1 → Turn 2 lifecycle
  # ---------------------------------------------------------------------------

  describe "fingerprint-based conversation lifecycle" do
    test "Turn 1 creates conversation with UUID v4, Turn 2 finds it by fingerprint" do
      # --- Turn 1: no fingerprint yet ---
      {:ok, turn1} =
        find_or_create(%{
          fingerprint: nil,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn1.new? == true
      # UUID v4: 36 chars with dashes, version nibble is '4'
      assert is_binary(turn1.conversation_id)
      assert byte_size(turn1.conversation_id) == 36
      assert String.at(turn1.conversation_id, 14) == "4"

      # Simulate adding a PII mapping during Turn 1
      :ok =
        Conversation.add_mapping(
          turn1.conversation_id,
          %{{:email, 1} => "john@example.com"},
          %{{"john@example.com", :email} => {:email, 1}}
        )

      # Simulate the response: compute fingerprint from [user_A, assistant_1]
      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Got it, I'll note your email."}

      {v5_id, fp_hash} =
        simulate_response_and_migrate(turn1, [user_a, assistant_1])

      # The new ID should be a UUID v5 (deterministic from fingerprint)
      assert is_binary(v5_id)
      assert byte_size(v5_id) == 36
      assert v5_id != turn1.conversation_id

      # --- Turn 2: find by fingerprint ---
      # The fingerprint for Turn 2 lookup is based on the messages that
      # existed before the current user message — i.e., [user_A, assistant_1].
      lookup_fp = compute_lookup_fingerprint([user_a, assistant_1])
      assert lookup_fp == fp_hash

      {:ok, turn2} =
        find_or_create(%{
          fingerprint: lookup_fp,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn2.new? == false
      assert turn2.conversation_id == v5_id

      # The mapping from Turn 1 is still present after migration
      {:ok, mapping} = Conversation.get_mapping(turn2.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
    end

    # ---------------------------------------------------------------------------
    # Test 2: Modified message history starts a new conversation
    # ---------------------------------------------------------------------------

    test "modified message history starts a new conversation" do
      # --- Turn 1: create and migrate ---
      {:ok, turn1} =
        find_or_create(%{
          fingerprint: nil,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      :ok =
        Conversation.add_mapping(
          turn1.conversation_id,
          %{{:email, 1} => "john@example.com"},
          %{{"john@example.com", :email} => {:email, 1}}
        )

      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Noted."}

      {original_v5_id, original_fp} =
        simulate_response_and_migrate(turn1, [user_a, assistant_1])

      # --- Turn 2: modified prior message ---
      # The user changed their original message (e.g., fixed a typo),
      # so the fingerprint is different.
      modified_user_a = %{"role" => "user", "content" => "My email is jane@example.org"}
      # The lookup fingerprint is based on the modified history
      modified_fp = compute_lookup_fingerprint([modified_user_a, assistant_1])
      assert modified_fp != original_fp

      {:ok, turn2} =
        find_or_create(%{
          fingerprint: modified_fp,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      # New conversation — different fingerprint means different UUID v5
      assert turn2.new? == true
      assert turn2.conversation_id != original_v5_id

      # The old conversation still exists with its mapping
      {:ok, old_mapping} = Conversation.get_mapping(original_v5_id)
      assert old_mapping[{:email, 1}] == "john@example.com"

      # The new conversation has no mapping yet
      {:ok, new_mapping} = Conversation.get_mapping(turn2.conversation_id)
      assert new_mapping == %{}
    end

    # ---------------------------------------------------------------------------
    # Test 3: Cross-provider continuity
    # ---------------------------------------------------------------------------

    test "cross-provider continuity — same fingerprint finds same conversation" do
      # --- Turn 1 via :openai ---
      {:ok, turn1} =
        find_or_create(%{
          fingerprint: nil,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      :ok =
        Conversation.add_mapping(
          turn1.conversation_id,
          %{{:email, 1} => "john@example.com"},
          %{{"john@example.com", :email} => {:email, 1}}
        )

      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Noted."}

      {v5_id, _fp} =
        simulate_response_and_migrate(turn1, [user_a, assistant_1])

      # --- Turn 2 via :anthropic with the same fingerprint ---
      lookup_fp = compute_lookup_fingerprint([user_a, assistant_1])

      {:ok, turn2} =
        find_or_create(%{
          fingerprint: lookup_fp,
          source_provider: :anthropic,
          provider_conversation_id: nil
        })

      # Same conversation found — fingerprint-based lookup is provider-agnostic
      assert turn2.new? == false
      assert turn2.conversation_id == v5_id

      # The source_provider in the returned struct reflects the lookup —
      # get_conversation returns whatever was stored (openai, since that's
      # what created it), but the conversation_id is the same.
      # Note: find_or_create returns the stored conversation as-is for
      # existing conversations (new?: false), so source_provider is :openai.
      assert turn2.source_provider == :openai

      # The mapping is reused across providers
      {:ok, mapping} = Conversation.get_mapping(turn2.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
    end

    # ---------------------------------------------------------------------------
    # Test 4: Turn 3+ updates fingerprint after each response
    # ---------------------------------------------------------------------------

    test "Turn 3+ updates fingerprint after each response" do
      # --- Turn 1: user message A ---
      user_a = %{"role" => "user", "content" => "Hello, I need help"}

      {:ok, turn1} =
        find_or_create(%{
          fingerprint: nil,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      :ok =
        Conversation.add_mapping(
          turn1.conversation_id,
          %{{:email, 1} => "john@example.com"},
          %{{"john@example.com", :email} => {:email, 1}}
        )

      # Simulate Turn 1 response: assistant_1
      # After response, the full message history is [user_a, assistant_1].
      # Migrate to UUID v5 derived from fingerprint([user_a, assistant_1]).
      assistant_1 = %{"role" => "assistant", "content" => "Sure, how can I help?"}
      {v5_id_turn1, fp_after_turn1} =
        simulate_response_and_migrate(turn1, [user_a, assistant_1])

      # --- Turn 2: add user message C ---
      # The full message list sent to the backend is [user_a, assistant_1, user_c].
      # The lookup fingerprint is messages[0..-2] = [user_a, assistant_1],
      # which matches the fingerprint used for Turn 1 migration.
      user_c = %{"role" => "user", "content" => "My email is john@example.com"}

      lookup_fp_turn2 = compute_lookup_fingerprint([user_a, assistant_1])
      assert lookup_fp_turn2 == fp_after_turn1

      {:ok, turn2} =
        find_or_create(%{
          fingerprint: lookup_fp_turn2,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn2.new? == false
      assert turn2.conversation_id == v5_id_turn1

      # Simulate Turn 2 response: assistant_2
      # After response, the full history is [user_a, assistant_1, user_c, assistant_2].
      # Migrate to UUID v5 derived from fingerprint of this new full history.
      assistant_2 = %{"role" => "assistant", "content" => "Got it, john@example.com noted."}

      {v5_id_turn2, fp_after_turn2} =
        simulate_response_and_migrate(turn2, [user_a, assistant_1, user_c, assistant_2])

      # The conversation ID changed — the fingerprint now covers more messages,
      # producing a different UUID v5.
      assert v5_id_turn2 != v5_id_turn1

      # --- Turn 3: add user message D ---
      # The full message list is [user_a, assistant_1, user_c, assistant_2, user_d].
      # The lookup fingerprint is messages[0..-2] = [user_a, assistant_1, user_c, assistant_2],
      # which matches the fingerprint used for Turn 2 migration.
      _user_d = %{"role" => "user", "content" => "Also add jane@example.org"}

      lookup_fp_turn3 =
        compute_lookup_fingerprint([user_a, assistant_1, user_c, assistant_2])

      assert lookup_fp_turn3 == fp_after_turn2

      {:ok, turn3} =
        find_or_create(%{
          fingerprint: lookup_fp_turn3,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert turn3.new? == false
      assert turn3.conversation_id == v5_id_turn2

      # The mapping from Turn 1 is still present after two migrations
      {:ok, mapping} = Conversation.get_mapping(turn3.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
    end

    # ---------------------------------------------------------------------------
    # Test 5: Cleanup removes expired conversations and their fingerprints
    # ---------------------------------------------------------------------------

    test "cleanup removes expired conversations and their fingerprints" do
      # Create a conversation and migrate it to UUID v5
      {:ok, turn1} =
        find_or_create(%{
          fingerprint: nil,
          source_provider: :openai,
          provider_conversation_id: nil
        })

      :ok =
        Conversation.add_mapping(
          turn1.conversation_id,
          %{{:email, 1} => "john@example.com"},
          %{{"john@example.com", :email} => {:email, 1}}
        )

      user_a = %{"role" => "user", "content" => "My email is john@example.com"}
      assistant_1 = %{"role" => "assistant", "content" => "Noted."}

      {v5_id, _fp} =
        simulate_response_and_migrate(turn1, [user_a, assistant_1])

      # Verify the conversation exists
      assert {:ok, _} = Conversation.get_mapping(v5_id)

      # Backdate last_active_at to a very negative value so cleanup_expired(0)
      # evicts it. Monotonic time can be negative on some systems, so we use
      # a value that's guaranteed to be in the far past.
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
        find_or_create(%{
          fingerprint: lookup_fp,
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
