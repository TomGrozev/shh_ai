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
      created_at: now,
      last_active_at: now,
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
          :get_mapping,
          :get_reverse_index,
          :lookup_placeholder,
          :touch,
          :delete,
          :cleanup_expired
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
      assert arities[:get_mapping] == 1
      assert arities[:get_reverse_index] == 1
      assert arities[:lookup_placeholder] == 3
      assert arities[:touch] == 1
      assert arities[:delete] == 1
      assert arities[:cleanup_expired] == 0
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
      conv = build_conversation(provider_conversation_id: "delete-test-#{System.unique_integer()}")
      :ok = ConversationStore.create(conv)

      assert :ok = ConversationStore.delete(conv.conversation_id)

      assert {:error, :not_found} = ConversationStore.get_mapping(conv.conversation_id)
    end
  end
end
