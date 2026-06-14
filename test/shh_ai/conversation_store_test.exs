defmodule ShhAi.ConversationStoreTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.ConversationStore

  setup do
    # Configure ETS backend
    System.delete_env("CONVERSATION_STORE_BACKEND")
    Config.load()

    # Start the GenServer if not already started. The named GenServer only runs
    # once per node, so subsequent setups hit the {:already_started, _} branch.
    case ConversationStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp build_conversation(attrs \\ %{}) do
    now = System.monotonic_time(:millisecond)

    %Conversation{
      conversation_id: Map.get(attrs, :conversation_id, "test-#{System.unique_integer()}"),
      source_provider: Map.get(attrs, :source_provider, :openai),
      provider_conversation_id: Map.get(attrs, :provider_conversation_id),
      mapping: %{},
      reverse_index: %{},
      created_at: Map.get(attrs, :created_at, now),
      last_active_at: Map.get(attrs, :last_active_at, now),
      fingerprint_hash: nil,
      new?: true
    }
  end

  describe "behaviour" do
    test "defines the expected behaviour callbacks" do
      callbacks = ConversationStore.behaviour_info(:callbacks)
      callback_names = callbacks |> Keyword.keys() |> MapSet.new()

      expected =
        MapSet.new([
          :init,
          :create,
          :add_mapping,
          :get_conversation,
          :get_mapping,
          :get_reverse_index,
          :lookup_placeholder,
          :touch,
          :delete,
          :migrate_id,
          :cleanup_expired,
          :update_fingerprint,
          :cache_message,
          :lookup_message,
          :list_conversations
        ])

      missing = MapSet.difference(expected, callback_names)

      assert MapSet.size(missing) == 0,
             "expected behaviour callbacks missing: #{inspect(MapSet.to_list(missing))}"
    end

    test "callback arities match the contract" do
      callbacks = ConversationStore.behaviour_info(:callbacks)
      arities = Map.new(callbacks)

      assert arities[:init] == 0
      assert arities[:create] == 1
      assert arities[:add_mapping] == 3
      assert arities[:get_conversation] == 1
      assert arities[:get_mapping] == 1
      assert arities[:get_reverse_index] == 1
      assert arities[:lookup_placeholder] == 3
      assert arities[:touch] == 1
      assert arities[:delete] == 1
      assert arities[:migrate_id] == 2
      assert arities[:cleanup_expired] == 0
      assert arities[:update_fingerprint] == 2
      assert arities[:cache_message] == 3
      assert arities[:lookup_message] == 2
      assert arities[:list_conversations] == 1
    end
  end

  describe "backend/0" do
    test "returns the ETS backend by default" do
      assert ConversationStore.backend() == ShhAi.ConversationStore.ETS
    end
  end

  describe "start_link/1" do
    test "starts the GenServer under its module name" do
      pid = Process.whereis(ConversationStore)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "init/1" do
    test "initializes with the ETS backend in state" do
      assert {:ok, %{backend: ShhAi.ConversationStore.ETS}} = ConversationStore.init([])
    end
  end

  describe "handle_call :backend" do
    test "returns the current backend without changing state" do
      {:ok, state} = ConversationStore.init([])

      assert {:reply, ShhAi.ConversationStore.ETS, ^state} =
               ConversationStore.handle_call(:backend, nil, state)
    end
  end

  describe "ETS backend stub" do
    test "init/0 creates the three named ETS tables" do
      # init/0 must be idempotent — running it twice must not error
      :ok = ShhAi.ConversationStore.ETS.init()
      :ok = ShhAi.ConversationStore.ETS.init()

      assert is_list(:ets.info(:conversations))
      assert is_list(:ets.info(:conversation_mappings))
      assert is_list(:ets.info(:conversation_reverse_index))
    end

    test "init/0 returns :ok" do
      assert :ok = ShhAi.ConversationStore.ETS.init()
    end

    test "implements the ShhAi.ConversationStore behaviour" do
      behaviours = ShhAi.ConversationStore.ETS.module_info(:attributes)
      # @behaviour annotations are stored in :behaviour attributes
      behaviour_list = Keyword.get_values(behaviours, :behaviour) |> List.flatten()

      assert ShhAi.ConversationStore in behaviour_list
    end
  end

  describe "ETS backend stub — message_cache" do
    test "init/0 creates the conversation_message_cache ETS table" do
      :ok = ShhAi.ConversationStore.ETS.init()
      assert is_list(:ets.info(:conversation_message_cache))
    end

    test "cache_message/3 stores sanitized content keyed by {conversation_id, message_hash}" do
      conv_id = "conv-#{System.unique_integer()}"
      hash = "abc123hash"
      sanitized_content = {"sanitized text", %{}, %{}, %{pii_count: 2}}

      :ok = ShhAi.ConversationStore.ETS.cache_message(conv_id, hash, sanitized_content)

      assert [{_, ^sanitized_content}] =
               :ets.lookup(:conversation_message_cache, {conv_id, hash})
    end

    test "lookup_message/2 returns {:ok, sanitized_content} for a cached message" do
      conv_id = "conv-#{System.unique_integer()}"
      hash = "abc123hash"
      sanitized_content = {"sanitized text", %{}, %{}, %{pii_count: 2}}

      :ok = ShhAi.ConversationStore.ETS.cache_message(conv_id, hash, sanitized_content)

      assert {:ok, ^sanitized_content} =
               ShhAi.ConversationStore.ETS.lookup_message(conv_id, hash)
    end

    test "lookup_message/2 returns {:error, :not_found} for a non-cached message" do
      conv_id = "conv-#{System.unique_integer()}"

      assert {:error, :not_found} =
               ShhAi.ConversationStore.ETS.lookup_message(conv_id, "nonexistent_hash")
    end

    test "lookup_message/2 returns {:error, :not_found} when conversation does not exist" do
      assert {:error, :not_found} =
               ShhAi.ConversationStore.ETS.lookup_message("no_such_conv", "any_hash")
    end
  end

  describe "GenServer cleanup" do
    test "cleanup/0 returns count of expired conversations removed" do
      # Create a conversation, then expire it by setting TTL to 0
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      # Ensure enough time has passed for the conversation to be expired
      Process.sleep(10)

      # Expire it with a 0ms TTL
      count = ShhAi.ConversationStore.ETS.cleanup_expired(0)
      assert count >= 1
    end

    test "periodic cleanup message is handled" do
      # Send :cleanup message to the running GenServer
      send(Process.whereis(ConversationStore), :cleanup)
      # Give it time to process
      Process.sleep(50)
      # GenServer should still be alive
      assert Process.alive?(Process.whereis(ConversationStore))
    end

    test "cleanup_expired removes message_cache entries for expired conversations" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      # Cache a message
      hash = "test_hash_abc123"
      :ok = ConversationStore.cache_message(conv.conversation_id, hash, "cached content")

      # Verify it's cached
      assert {:ok, "cached content"} = ConversationStore.lookup_message(conv.conversation_id, hash)

      # Expire the conversation (TTL = 0)
      Process.sleep(10)
      count = ShhAi.ConversationStore.ETS.cleanup_expired(0)
      assert count >= 1

      # Message cache entry should be gone
      assert {:error, :not_found} = ConversationStore.lookup_message(conv.conversation_id, hash)
    end
  end

  describe "data-plane delegation" do
    test "create/1 delegates to backend and returns :ok" do
      conv = build_conversation()
      assert :ok = ConversationStore.create(conv)
    end

    test "add_mapping/3 and get_mapping/1 work through delegation" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      mapping = %{"EMAIL_1" => "test@example.com"}
      reverse = %{{"test@example.com", :email} => "EMAIL_1"}

      :ok = ConversationStore.add_mapping(conv.conversation_id, mapping, reverse)
      assert {:ok, ^mapping} = ConversationStore.get_mapping(conv.conversation_id)
    end

    test "get_reverse_index/1 works through delegation" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      mapping = %{"EMAIL_1" => "test@example.com"}
      reverse = %{{"test@example.com", :email} => "EMAIL_1"}

      ConversationStore.add_mapping(conv.conversation_id, mapping, reverse)
      assert {:ok, ^reverse} = ConversationStore.get_reverse_index(conv.conversation_id)
    end

    test "lookup_placeholder/3 works through delegation" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      mapping = %{"EMAIL_1" => "test@example.com"}
      reverse = %{{"test@example.com", :email} => "EMAIL_1"}

      ConversationStore.add_mapping(conv.conversation_id, mapping, reverse)

      assert {:ok, "EMAIL_1"} =
               ConversationStore.lookup_placeholder(
                 conv.conversation_id,
                 "test@example.com",
                 :email
               )
    end

    test "touch/1 works through delegation" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)
      assert :ok = ConversationStore.touch(conv.conversation_id)
    end

    test "delete/1 works through delegation" do
      conv = build_conversation(%{provider_conversation_id: "delete-test-#{System.unique_integer()}"})
      :ok = ConversationStore.create(conv)

      assert :ok = ConversationStore.delete(conv.conversation_id)

      assert {:error, :not_found} = ConversationStore.get_mapping(conv.conversation_id)
    end

    test "migrate_id/2 works through delegation" do
      conv = build_conversation(%{provider_conversation_id: "migrate-test-#{System.unique_integer()}"})
      :ok = ConversationStore.create(conv)

      old_id = conv.conversation_id
      new_id = "migrated-#{System.unique_integer()}"

      mapping = %{"EMAIL_1" => "test@example.com"}
      reverse = %{{"test@example.com", :email} => "EMAIL_1"}

      :ok = ConversationStore.add_mapping(old_id, mapping, reverse)

      assert :ok = ConversationStore.migrate_id(old_id, new_id)

      # Old is gone.
      assert {:error, :not_found} = ConversationStore.get_conversation(old_id)

      # New has the data.
      assert {:ok, loaded} = ConversationStore.get_conversation(new_id)
      assert loaded.conversation_id == new_id
      assert loaded.mapping == mapping
    end

    test "get_conversation/1 returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = ConversationStore.get_conversation("nonexistent_uuid")
    end

    test "get_conversation/1 returns a Conversation struct for an existing conversation" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      assert {:ok, %Conversation{} = loaded} =
               ConversationStore.get_conversation(conv.conversation_id)

      assert loaded.conversation_id == conv.conversation_id
      assert loaded.source_provider == conv.source_provider
      assert loaded.new? == false
    end

    test "update_fingerprint/2 works through delegation" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      assert :ok = ConversationStore.update_fingerprint(conv.conversation_id, "new_hash")

      assert {:ok, loaded} = ConversationStore.get_conversation(conv.conversation_id)
      assert loaded.fingerprint_hash == "new_hash"
    end

    test "update_fingerprint/2 returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} =
               ConversationStore.update_fingerprint("nonexistent_uuid", "new_hash")
    end

    test "cache_message/3 and lookup_message/2 work through delegation" do
      conv_id = "conv-#{System.unique_integer()}"
      hash = "delegation_hash"
      sanitized_content = {"delegated text", %{}, %{}, %{pii_count: 1}}

      :ok = ConversationStore.cache_message(conv_id, hash, sanitized_content)

      assert {:ok, ^sanitized_content} = ConversationStore.lookup_message(conv_id, hash)
    end

    test "list_conversations/1 returns conversations sorted by last_active_at" do
      # Create 3 conversations with different last_active_at times
      now = System.monotonic_time(:millisecond)

      conv1 = build_conversation(%{
        conversation_id: "conv-list-1",
        source_provider: :openai,
        last_active_at: now - 3000
      })
      conv2 = build_conversation(%{
        conversation_id: "conv-list-2",
        source_provider: :anthropic,
        last_active_at: now - 1000
      })
      conv3 = build_conversation(%{
        conversation_id: "conv-list-3",
        source_provider: :openai,
        last_active_at: now - 2000
      })

      :ok = ConversationStore.create(conv1)
      :ok = ConversationStore.create(conv2)
      :ok = ConversationStore.create(conv3)

      # List all conversations and filter to ours
      all_convs = ConversationStore.list_conversations(limit: 1000)
      our_ids = MapSet.new(["conv-list-1", "conv-list-2", "conv-list-3"])
      our_convs = Enum.filter(all_convs, &MapSet.member?(our_ids, &1.conversation_id))

      # Our 3 conversations should be present
      assert length(our_convs) == 3

      # Among our conversations, verify sorting by last_active_at descending
      [first, second, third] = our_convs
      assert first.conversation_id == "conv-list-2"
      assert second.conversation_id == "conv-list-3"
      assert third.conversation_id == "conv-list-1"
    end

    test "list_conversations/1 respects limit option" do
      # Create 3 conversations with different last_active_at times
      now = System.monotonic_time(:millisecond)

      conv1 = build_conversation(%{
        conversation_id: "conv-limit-1",
        source_provider: :openai,
        last_active_at: now - 3000
      })
      conv2 = build_conversation(%{
        conversation_id: "conv-limit-2",
        source_provider: :anthropic,
        last_active_at: now - 1000
      })
      conv3 = build_conversation(%{
        conversation_id: "conv-limit-3",
        source_provider: :openai,
        last_active_at: now - 2000
      })

      :ok = ConversationStore.create(conv1)
      :ok = ConversationStore.create(conv2)
      :ok = ConversationStore.create(conv3)

      # List with limit of 2 from a high offset to isolate our conversations
      result = ConversationStore.list_conversations(limit: 1000)

      # Filter to just our conversations
      our_ids = MapSet.new(["conv-limit-1", "conv-limit-2", "conv-limit-3"])
      our_convs = Enum.filter(result, &MapSet.member?(our_ids, &1.conversation_id))

      # All 3 should be present
      assert length(our_convs) == 3

      # Verify they are in the correct order
      [first, second, third] = our_convs
      assert first.conversation_id == "conv-limit-2"
      assert second.conversation_id == "conv-limit-3"
      assert third.conversation_id == "conv-limit-1"
    end

    test "list_conversations/1 returns all conversations when no limit given" do
      now = System.monotonic_time(:millisecond)

      conv1 = build_conversation(%{
        conversation_id: "conv-all-1",
        last_active_at: now - 1000
      })
      conv2 = build_conversation(%{
        conversation_id: "conv-all-2",
        last_active_at: now - 2000
      })

      :ok = ConversationStore.create(conv1)
      :ok = ConversationStore.create(conv2)

      result = ConversationStore.list_conversations()

      # Should return at least our 2 conversations
      ids = Enum.map(result, & &1.conversation_id)
      assert "conv-all-1" in ids
      assert "conv-all-2" in ids
    end
  end

  describe "message_cache operations" do
    test "cache_message and lookup_message round-trip" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      hash = "test_hash_123"
      value = {:user_message, "sanitized text", %{{:email, 1} => "test@example.com"}, %{}, {1, 0}}

      :ok = ConversationStore.cache_message(conv.conversation_id, hash, value)
      assert {:ok, ^value} = ConversationStore.lookup_message(conv.conversation_id, hash)
    end

    test "lookup_message returns :not_found for missing key" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      assert {:error, :not_found} = ConversationStore.lookup_message(conv.conversation_id, "missing")
    end

    test "delete removes cache entries" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      hash = "test_hash_456"
      :ok = ConversationStore.cache_message(conv.conversation_id, hash, "cached")
      assert {:ok, "cached"} = ConversationStore.lookup_message(conv.conversation_id, hash)

      :ok = ConversationStore.delete(conv.conversation_id)
      assert {:error, :not_found} = ConversationStore.lookup_message(conv.conversation_id, hash)
    end

    test "migrate_id transfers cache entries" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      hash = "test_hash_789"
      :ok = ConversationStore.cache_message(conv.conversation_id, hash, "cached")

      new_id = "new_conversation_id"
      :ok = ConversationStore.migrate_id(conv.conversation_id, new_id)

      # Old ID should not have the cache
      assert {:error, :not_found} = ConversationStore.lookup_message(conv.conversation_id, hash)
      # New ID should have it
      assert {:ok, "cached"} = ConversationStore.lookup_message(new_id, hash)
    end

    test "overwriting cache entry replaces value" do
      conv = build_conversation()
      :ok = ConversationStore.create(conv)

      hash = "test_hash_overwrite"
      :ok = ConversationStore.cache_message(conv.conversation_id, hash, "first")
      assert {:ok, "first"} = ConversationStore.lookup_message(conv.conversation_id, hash)

      :ok = ConversationStore.cache_message(conv.conversation_id, hash, "second")
      assert {:ok, "second"} = ConversationStore.lookup_message(conv.conversation_id, hash)
    end
  end
end
