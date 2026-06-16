defmodule ShhAi.FingerprintMigrationTest do
  @moduledoc """
  Regression tests for FingerprintMigration.migrate_or_update/3.

  The key invariant is: after each turn, the ETS row key must equal
  `derive_conversation_id(lookup_fingerprint)` where lookup_fingerprint
  is derived from only the first 2 messages. This ensures the conversation
  ID is stable after Turn 1.

  The full fingerprint (all messages) is stored as metadata but does not
  drive ID derivation.

  These tests exercise both code paths:
    - Non-streaming: ConversationHelpers.update_fingerprint/3
    - Streaming: FingerprintMigration.migrate_or_update/3
  """

  use ExUnit.Case, async: false

  alias ShhAi.ConversationStore.ETS, as: ETSStore
  alias ShhAi.BackendClient.ConversationHelpers
  alias ShhAi.BackendClient.FingerprintMigration
  alias ShhAi.ConversationFingerprinter

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

  defp count_conversations, do: :ets.info(:conversations, :size)

  defp get_stored_fingerprint_hash(conversation_id) do
    case :ets.lookup(:conversations, conversation_id) do
      [{^conversation_id, _, _, _, _, fp_hash}] -> fp_hash
      [] -> nil
    end
  end

  defp build_body(messages) do
    %{"model" => "gpt-4", "messages" => messages}
  end

  defp build_response(content) do
    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}}
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Non-streaming path: find_or_create + update_fingerprint
  # ---------------------------------------------------------------------------

  describe "non-streaming: 3+ turn conversation keeps a single ETS row" do
    test "3+ turn conversation keeps a single ETS row across find_or_create + update_fingerprint" do
      # === TURN 1 ===
      t1_msgs = [%{"role" => "user", "content" => "Hello"}]
      t1_body = build_body(t1_msgs)

      {:ok, t1_conv} = ConversationHelpers.find_or_create(t1_body, :openai)
      assert t1_conv.new? == true
      assert count_conversations() == 1

      t1_resp = build_response("Hi there!")
      t1_final = ConversationHelpers.update_fingerprint(t1_conv, t1_body, t1_resp)

      # Turn 1 migrates from UUID v4 to UUID v5, so final != original
      assert t1_final != t1_conv.conversation_id
      assert count_conversations() == 1

      # === TURN 2 ===
      t2_msgs = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there!"},
        %{"role" => "user", "content" => "How are you?"}
      ]
      t2_body = build_body(t2_msgs)

      {:ok, t2_conv} = ConversationHelpers.find_or_create(t2_body, :openai)
      assert t2_conv.new? == false
      assert t2_conv.conversation_id == t1_final
      assert count_conversations() == 1

      t2_resp = build_response("I am doing well!")
      _t2_final = ConversationHelpers.update_fingerprint(t2_conv, t2_body, t2_resp)

      # After the fix, the row is migrated so key == derive(stored_fp) is maintained
      assert count_conversations() == 1

      # === TURN 3 ===
      t3_msgs = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there!"},
        %{"role" => "user", "content" => "How are you?"},
        %{"role" => "assistant", "content" => "I am doing well!"},
        %{"role" => "user", "content" => "Tell me a joke"}
      ]
      t3_body = build_body(t3_msgs)

      {:ok, t3_conv} = ConversationHelpers.find_or_create(t3_body, :openai)
      # KEY ASSERTION: Turn 3 finds the existing conversation (new?: false)
      # Before the fix, this was new?: true because the row key was stale.
      assert t3_conv.new? == false
      assert count_conversations() == 1

      t3_resp = build_response("Why did the chicken cross the road?")
      t3_final = ConversationHelpers.update_fingerprint(t3_conv, t3_body, t3_resp)

      assert count_conversations() == 1

      # After Turn 3's response, the stored fingerprint hash should be
      # fingerprint_messages([user1, asst1, user2, asst2, user3, asst3]) — i.e.
      # the full 6-message history including the Turn 3 assistant response.
      expected_fp =
        ConversationFingerprinter.fingerprint_messages([
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there!"},
          %{"role" => "user", "content" => "How are you?"},
          %{"role" => "assistant", "content" => "I am doing well!"},
          %{"role" => "user", "content" => "Tell me a joke"},
          %{"role" => "assistant", "content" => "Why did the chicken cross the road?"}
        ])

      stored_hash = get_stored_fingerprint_hash(t3_final)
      assert stored_hash == expected_fp,
             "Expected stored fingerprint to match fingerprint_messages of 5 messages," <>
               " got: #{inspect(stored_hash)} vs #{inspect(expected_fp)}"

      # === TURN 4 (bonus: confirm the pattern holds) ===
      t4_msgs = t3_msgs ++ [
        %{"role" => "assistant", "content" => "Why did the chicken cross the road?"},
        %{"role" => "user", "content" => "That was terrible"}
      ]
      t4_body = build_body(t4_msgs)

      {:ok, t4_conv} = ConversationHelpers.find_or_create(t4_body, :openai)
      assert t4_conv.new? == false
      assert count_conversations() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming path: find_or_create + FingerprintMigration.migrate_or_update
  # ---------------------------------------------------------------------------

  describe "streaming: 3+ turn conversation keeps a single ETS row" do
    test "3+ turn streaming conversation keeps a single ETS row via migrate_or_update" do
      # === TURN 1 (streaming) ===
      s1_msgs = [%{"role" => "user", "content" => "Hello"}]
      s1_body = build_body(s1_msgs)

      {:ok, s1_conv} = ConversationHelpers.find_or_create(s1_body, :openai)
      assert s1_conv.new? == true
      assert count_conversations() == 1

      # Simulate finalize_stream: compute full + lookup fingerprints and call migrate_or_update
      s1_asst = %{"role" => "assistant", "content" => "Hi there!"}
      s1_all = s1_msgs ++ [s1_asst]
      s1_fp = ConversationFingerprinter.fingerprint_messages(s1_all)
      s1_lookup_fp = ConversationFingerprinter.fingerprint_for_lookup(s1_all)
      s1_final = FingerprintMigration.migrate_or_update(s1_conv, s1_fp, s1_lookup_fp)

      assert s1_final != s1_conv.conversation_id
      assert count_conversations() == 1

      # === TURN 2 (streaming) ===
      s2_msgs = s1_msgs ++ [s1_asst, %{"role" => "user", "content" => "How are you?"}]
      s2_body = build_body(s2_msgs)

      {:ok, s2_conv} = ConversationHelpers.find_or_create(s2_body, :openai)
      assert s2_conv.new? == false
      assert s2_conv.conversation_id == s1_final
      assert count_conversations() == 1

      s2_asst = %{"role" => "assistant", "content" => "I am fine!"}
      s2_all = s2_msgs ++ [s2_asst]
      s2_fp = ConversationFingerprinter.fingerprint_messages(s2_all)
      s2_lookup_fp = ConversationFingerprinter.fingerprint_for_lookup(s2_all)
      _s2_final = FingerprintMigration.migrate_or_update(s2_conv, s2_fp, s2_lookup_fp)

      assert count_conversations() == 1

      # === TURN 3 (streaming) ===
      s3_msgs = s2_msgs ++ [s2_asst, %{"role" => "user", "content" => "Tell me a joke"}]
      s3_body = build_body(s3_msgs)

      {:ok, s3_conv} = ConversationHelpers.find_or_create(s3_body, :openai)
      # KEY ASSERTION: Turn 3 finds the existing conversation
      assert s3_conv.new? == false
      assert count_conversations() == 1

      s3_asst = %{"role" => "assistant", "content" => "Why so serious?"}
      s3_all = s3_msgs ++ [s3_asst]
      s3_fp = ConversationFingerprinter.fingerprint_messages(s3_all)
      s3_lookup_fp = ConversationFingerprinter.fingerprint_for_lookup(s3_all)
      s3_final = FingerprintMigration.migrate_or_update(s3_conv, s3_fp, s3_lookup_fp)

      assert count_conversations() == 1

      # Verify the stored fingerprint matches the full message history including
      # the Turn 3 assistant response (6 messages total).
      expected_fp =
        ConversationFingerprinter.fingerprint_messages([
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there!"},
          %{"role" => "user", "content" => "How are you?"},
          %{"role" => "assistant", "content" => "I am fine!"},
          %{"role" => "user", "content" => "Tell me a joke"},
          %{"role" => "assistant", "content" => "Why so serious?"}
        ])

      stored_hash = get_stored_fingerprint_hash(s3_final)
      assert stored_hash == expected_fp
    end
  end
end
