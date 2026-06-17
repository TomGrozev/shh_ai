defmodule ShhAi.ConversationFingerprinterTest do
  use ExUnit.Case, async: true

  alias ShhAi.Conversation.Fingerprinter

  describe "fingerprint_messages/1" do
    test "returns nil for an empty message list" do
      assert Fingerprinter.fingerprint_messages([]) == nil
    end

    test "returns nil for a single message" do
      messages = [%{role: "user", content: "Hello"}]
      assert Fingerprinter.fingerprint_messages(messages) == nil
    end

    test "returns a 64-char hex hash for two messages" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      result = Fingerprinter.fingerprint_messages(messages)

      assert is_binary(result)
      assert byte_size(result) == 64
      assert result =~ ~r/^[0-9a-f]{64}$/
    end

    test "is deterministic for the same message list" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      assert Fingerprinter.fingerprint_messages(messages) ==
               Fingerprinter.fingerprint_messages(messages)
    end

    test "different message lists produce different hashes" do
      messages_a = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      messages_b = [
        %{role: "user", content: "Goodbye"},
        %{role: "assistant", content: "See you!"}
      ]

      assert Fingerprinter.fingerprint_messages(messages_a) !=
               Fingerprinter.fingerprint_messages(messages_b)
    end

    test "order matters — same messages in different order produce different hashes" do
      a_then_b = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      b_then_a = [
        %{role: "assistant", content: "Hi there!"},
        %{role: "user", content: "Hello"}
      ]

      assert Fingerprinter.fingerprint_messages(a_then_b) !=
               Fingerprinter.fingerprint_messages(b_then_a)
    end
  end

  describe "derive_conversation_id/1" do
    @sample_fingerprint "ac0d95c35a3b6aa59bd3ecc83f1139731a0da4937273005fe33600c390076d00"

    test "returns nil for nil fingerprint" do
      assert Fingerprinter.derive_conversation_id(nil) == nil
    end

    test "returns a valid UUID v5" do
      result = Fingerprinter.derive_conversation_id(@sample_fingerprint)

      assert is_binary(result)
      assert byte_size(result) == 36
      assert result =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "is deterministic for the same fingerprint" do
      first = Fingerprinter.derive_conversation_id(@sample_fingerprint)
      second = Fingerprinter.derive_conversation_id(@sample_fingerprint)

      assert first == second
    end

    test "different fingerprints produce different UUIDs" do
      other_fingerprint = "b1e2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"

      uuid_a = Fingerprinter.derive_conversation_id(@sample_fingerprint)
      uuid_b = Fingerprinter.derive_conversation_id(other_fingerprint)

      assert uuid_a != uuid_b
    end

    test "same fingerprint produces same UUID regardless of how many times called" do
      results =
        Enum.map(1..10, fn _ ->
          Fingerprinter.derive_conversation_id(@sample_fingerprint)
        end)

      assert Enum.all?(results, &(&1 == hd(results)))
    end
  end
end
