defmodule ShhAi.Conversation.Store.RebuildReverseIndexTest do
  @moduledoc """
  Tests for `ShhAi.Conversation.Store.ETS.rebuild_reverse_index/1`.

  This function rebuilds the reverse index for a conversation from its
  forward mapping entries in ETS. The reverse index enables O(1) lookup
  from `{original_value, pii_type}` to placeholder key.

  This is the "red" step of TDD — the tests define the expected behaviour
  before the function is implemented.
  """
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.Conversation.Store.ETS

  setup do
    System.delete_env("CONVERSATION_STORE_BACKEND")
    Config.load()
    :ok = ETS.init()
    :ok
  end

  defp create_conversation(conversation_id) do
    now = System.monotonic_time(:millisecond)

    conv = %ShhAi.Conversation{
      conversation_id: conversation_id,
      source_provider: :openai,
      provider_conversation_id: "provider-conv-#{conversation_id}",
      mapping: %{},
      reverse_index: %{},
      created_at: now,
      last_active_at: now,
      fingerprint_hash: nil,
      new?: true
    }

    :ok = ETS.create(conv)
    conv
  end

  defp insert_mapping(conversation_id, placeholder_key, original_value) do
    :ets.insert(:conversation_mappings, {{conversation_id, placeholder_key}, original_value})
  end

  describe "rebuild_reverse_index/1" do
    test "populates reverse index from forward mapping entries" do
      _conv = create_conversation("rebuild-1")

      # Insert forward mapping entries directly into ETS
      insert_mapping("rebuild-1", {:email, 1}, "john@example.com")
      insert_mapping("rebuild-1", {:phone, 1}, "+1-555-1234")

      # Verify reverse index is empty before rebuild
      assert [] = :ets.match_object(:conversation_reverse_index, {{"rebuild-1", :_, :_}, :_})

      # Rebuild the reverse index
      assert :ok = ETS.rebuild_reverse_index("rebuild-1")

      # Verify reverse index entries were created
      reverse_entries =
        :ets.match_object(:conversation_reverse_index, {{"rebuild-1", :_, :_}, :_})
        |> Map.new(fn {{_conv_id, original_value, pii_type}, placeholder_key} ->
          {{original_value, pii_type}, placeholder_key}
        end)

      assert reverse_entries == %{
               {"john@example.com", :email} => {:email, 1},
               {"+1-555-1234", :phone} => {:phone, 1}
             }
    end

    test "derives reverse index entries correctly from mapping shape" do
      _conv = create_conversation("rebuild-2")

      # Mapping: placeholder_key => original_value
      # For ETS: {{conversation_id, {:email, 1}}, "john@example.com"}
      insert_mapping("rebuild-2", {:email, 1}, "john@example.com")

      assert :ok = ETS.rebuild_reverse_index("rebuild-2")

      # The reverse index should be:
      # {{conversation_id, "john@example.com", :email}, {:email, 1}}
      reverse_entries =
        :ets.match_object(:conversation_reverse_index, {{"rebuild-2", :_, :_}, :_})

      assert [
               {{"rebuild-2", "john@example.com", :email}, {:email, 1}}
             ] = reverse_entries
    end

    test "overwrites existing reverse index entries (idempotent)" do
      _conv = create_conversation("rebuild-3")

      # Insert forward mapping
      insert_mapping("rebuild-3", {:email, 1}, "jane@example.com")

      # Manually insert a WRONG reverse index entry first
      :ets.insert(
        :conversation_reverse_index,
        {{"rebuild-3", "jane@example.com", :email}, {:email, 99}}
      )

      # Verify the wrong entry exists
      assert [
               {{"rebuild-3", "jane@example.com", :email}, {:email, 99}}
             ] = :ets.match_object(:conversation_reverse_index, {{"rebuild-3", :_, :_}, :_})

      # Rebuild should overwrite with the correct entry
      assert :ok = ETS.rebuild_reverse_index("rebuild-3")

      # Verify the correct entry replaced the wrong one
      reverse_entries =
        :ets.match_object(:conversation_reverse_index, {{"rebuild-3", :_, :_}, :_})

      assert [
               {{"rebuild-3", "jane@example.com", :email}, {:email, 1}}
             ] = reverse_entries
    end

    test "is a no-op when conversation has no mapping" do
      _conv = create_conversation("rebuild-4")

      # No mapping entries — reverse index should stay empty
      assert [] = :ets.match_object(:conversation_reverse_index, {{"rebuild-4", :_, :_}, :_})

      assert :ok = ETS.rebuild_reverse_index("rebuild-4")

      # Still empty
      assert [] = :ets.match_object(:conversation_reverse_index, {{"rebuild-4", :_, :_}, :_})
    end

    test "returns {:error, :not_found} when conversation doesn't exist" do
      assert {:error, :not_found} = ETS.rebuild_reverse_index("nonexistent-conversation")
    end
  end
end
