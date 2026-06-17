defmodule ShhAi.Conversation.Store.RedisTest do
  # async: false — these tests share a single Redis connection.
  use ExUnit.Case, async: false

  @moduletag :redis

  alias ShhAi.Conversation
  alias ShhAi.Conversation.Store.Redis, as: RedisStore

  @redis_url System.get_env("REDIS_URL", "redis://localhost:6379")

  setup do
    # Ensure Config has a redis_url set so init/0 can start Redix.
    System.put_env("REDIS_URL", @redis_url)
    Application.put_env(:shh_ai, :redis_url, @redis_url)

    # Store the redis_url in persistent_term for Config.redis_url/0
    :persistent_term.put({ShhAi.Config, :redis_url}, @redis_url)

    # Start or connect to Redix
    case Redix.start_link(@redis_url, name: ShhAi.Redis) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clean up any test keys before each test
    cleanup_test_keys()

    on_exit(fn ->
      cleanup_test_keys()
    end)

    :ok
  end

  defp cleanup_test_keys do
    case Redix.command(ShhAi.Redis, ["KEYS", "shh_ai:conversation:*"]) do
      {:ok, keys} when is_list(keys) and keys != [] ->
        Redix.command(ShhAi.Redis, ["DEL" | keys])

      _ ->
        :ok
    end
  end

  defp build_conversation(opts \\ []) do
    %Conversation{
      conversation_id: Keyword.get(opts, :conversation_id, UUID.uuid4()),
      source_provider: Keyword.get(opts, :source_provider, :openai),
      provider_conversation_id: Keyword.get(opts, :provider_conversation_id, "thread_abc123"),
      mapping: Keyword.get(opts, :mapping, %{}),
      reverse_index: Keyword.get(opts, :reverse_index, %{}),
      created_at: Keyword.get(opts, :created_at, System.monotonic_time(:millisecond)),
      last_active_at: Keyword.get(opts, :last_active_at, System.monotonic_time(:millisecond)),
      fingerprint_hash: Keyword.get(opts, :fingerprint_hash, nil),
      new?: Keyword.get(opts, :new?, true)
    }
  end

  # ---------------------------------------------------------------------------
  # init/0
  # ---------------------------------------------------------------------------

  describe "init/0" do
    test "returns :ok when Redix is already started" do
      assert :ok = RedisStore.init()
    end

    test "is idempotent — running twice does not error" do
      assert :ok = RedisStore.init()
      assert :ok = RedisStore.init()
    end
  end

  # ---------------------------------------------------------------------------
  # create/1
  # ---------------------------------------------------------------------------

  describe "create/1" do
    test "returns :ok and stores the conversation in Redis" do
      conv = build_conversation()
      assert :ok = RedisStore.create(conv)

      key = "shh_ai:conversation:#{conv.conversation_id}"
      assert {:ok, fields} = Redix.command(ShhAi.Redis, ["HGETALL", key])
      assert fields != []
    end

    test "stores source_provider and provider_conversation_id" do
      conv = build_conversation(source_provider: :anthropic, provider_conversation_id: "conv_456")
      :ok = RedisStore.create(conv)

      key = "shh_ai:conversation:#{conv.conversation_id}"
      assert {:ok, "anthropic"} = Redix.command(ShhAi.Redis, ["HGET", key, "source_provider"])

      assert {:ok, "conv_456"} =
               Redix.command(ShhAi.Redis, ["HGET", key, "provider_conversation_id"])
    end

    test "stores timestamps" do
      now = System.monotonic_time(:millisecond)
      conv = build_conversation(created_at: now, last_active_at: now)
      :ok = RedisStore.create(conv)

      key = "shh_ai:conversation:#{conv.conversation_id}"
      assert {:ok, created_str} = Redix.command(ShhAi.Redis, ["HGET", key, "created_at"])
      assert String.to_integer(created_str) == now
    end

    test "works with a nil provider_conversation_id" do
      conv = build_conversation(provider_conversation_id: nil)
      assert :ok = RedisStore.create(conv)

      key = "shh_ai:conversation:#{conv.conversation_id}"
      assert {:ok, ""} = Redix.command(ShhAi.Redis, ["HGET", key, "provider_conversation_id"])
    end
  end

  # ---------------------------------------------------------------------------
  # add_mapping/3 + get_mapping/1
  # ---------------------------------------------------------------------------

  describe "add_mapping/3 + get_mapping/1" do
    test "stores a mapping and retrieves it" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      mapping = %{"EMAIL_1" => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => "EMAIL_1"}

      assert :ok = RedisStore.add_mapping(conv.conversation_id, mapping, reverse_index)

      assert {:ok, %{"EMAIL_1" => "john@example.com"}} =
               RedisStore.get_mapping(conv.conversation_id)
    end

    test "multiple add_mapping calls accumulate entries" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"PERSON_1" => "John"},
          %{{"John", :person} => "PERSON_1"}
        )

      assert {:ok, accumulated} = RedisStore.get_mapping(conv.conversation_id)
      assert accumulated["EMAIL_1"] == "john@example.com"
      assert accumulated["PERSON_1"] == "John"
    end

    test "add_mapping is atomic — existing placeholder keys are NOT overwritten" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "jane@example.com"},
          %{{"jane@example.com", :email} => "EMAIL_1"}
        )

      assert {:ok, %{"EMAIL_1" => "john@example.com"}} =
               RedisStore.get_mapping(conv.conversation_id)
    end

    test "get_mapping/1 returns {:error, :not_found} for a nonexistent conversation_id" do
      assert {:error, :not_found} = RedisStore.get_mapping("nonexistent_uuid")
    end

    test "get_mapping/1 returns {:ok, %{}} for an existing conversation with no mapping entries" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      assert {:ok, %{}} = RedisStore.get_mapping(conv.conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # add_mapping/3 + get_reverse_index/1
  # ---------------------------------------------------------------------------

  describe "add_mapping/3 + get_reverse_index/1" do
    test "stores a reverse index and retrieves it" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      reverse_index = %{{"john@example.com", :email} => "EMAIL_1"}

      assert :ok = RedisStore.add_mapping(conv.conversation_id, %{}, reverse_index)

      assert {:ok, %{{"john@example.com", :email} => "EMAIL_1"}} =
               RedisStore.get_reverse_index(conv.conversation_id)
    end

    test "multiple add_mapping calls accumulate reverse-index entries" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      RedisStore.add_mapping(conv.conversation_id, %{}, %{
        {"john@example.com", :email} => "EMAIL_1"
      })

      RedisStore.add_mapping(conv.conversation_id, %{}, %{{"John", :person} => "PERSON_1"})

      assert {:ok, ri} = RedisStore.get_reverse_index(conv.conversation_id)
      assert ri[{"john@example.com", :email}] == "EMAIL_1"
      assert ri[{"John", :person}] == "PERSON_1"
    end

    test "reverse index entries are also atomic — existing keys are not overwritten" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      RedisStore.add_mapping(
        conv.conversation_id,
        %{},
        %{{"john@example.com", :email} => "EMAIL_1"}
      )

      RedisStore.add_mapping(
        conv.conversation_id,
        %{},
        %{{"john@example.com", :email} => "EMAIL_99"}
      )

      assert {:ok, %{{"john@example.com", :email} => "EMAIL_1"}} =
               RedisStore.get_reverse_index(conv.conversation_id)
    end

    test "get_reverse_index/1 returns {:error, :not_found} for a nonexistent conversation_id" do
      assert {:error, :not_found} = RedisStore.get_reverse_index("nonexistent_uuid")
    end

    test "get_reverse_index/1 returns {:ok, %{}} for an existing conversation with no reverse index" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      assert {:ok, %{}} = RedisStore.get_reverse_index(conv.conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # lookup_placeholder/3
  # ---------------------------------------------------------------------------

  describe "lookup_placeholder/3" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} =
               RedisStore.lookup_placeholder("nonexistent_uuid", "value", :email)
    end

    test "returns {:error, :not_found} for an existing conversation where the PII has not been seen" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      assert {:error, :not_found} =
               RedisStore.lookup_placeholder(
                 conv.conversation_id,
                 "jane@example.com",
                 :email
               )
    end

    test "returns {:ok, placeholder_key} for a previously-seen {original_value, pii_type}" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert {:ok, "EMAIL_1"} =
               RedisStore.lookup_placeholder(
                 conv.conversation_id,
                 "john@example.com",
                 :email
               )
    end

    test "matches on pii_type — same original_value under a different type is not found" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert {:error, :not_found} =
               RedisStore.lookup_placeholder(
                 conv.conversation_id,
                 "john@example.com",
                 :person
               )
    end

    test "does not bleed across conversations" do
      conv_a = build_conversation(provider_conversation_id: "thread_a")
      conv_b = build_conversation(provider_conversation_id: "thread_b")
      :ok = RedisStore.create(conv_a)
      :ok = RedisStore.create(conv_b)

      :ok =
        RedisStore.add_mapping(
          conv_a.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert {:error, :not_found} =
               RedisStore.lookup_placeholder(
                 conv_b.conversation_id,
                 "john@example.com",
                 :email
               )
    end
  end

  # ---------------------------------------------------------------------------
  # touch/1
  # ---------------------------------------------------------------------------

  describe "touch/1" do
    test "returns :ok for an existing conversation" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      assert :ok = RedisStore.touch(conv.conversation_id)
    end

    test "updates last_active_at in Redis" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      Process.sleep(2)
      assert :ok = RedisStore.touch(conv.conversation_id)

      key = "shh_ai:conversation:#{conv.conversation_id}"
      {:ok, last_active_str} = Redix.command(ShhAi.Redis, ["HGET", key, "last_active_at"])
      last_active = String.to_integer(last_active_str)

      assert last_active > conv.last_active_at
    end

    test "returns {:error, :not_found} for a non-existent conversation_id" do
      assert {:error, :not_found} = RedisStore.touch("nonexistent_uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  describe "update_fingerprint/2" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = RedisStore.update_fingerprint("nonexistent_uuid", "new_hash")
    end

    test "updates the fingerprint_hash for an existing conversation" do
      conv = build_conversation(fingerprint_hash: "original_hash")
      :ok = RedisStore.create(conv)

      assert :ok = RedisStore.update_fingerprint(conv.conversation_id, "updated_hash")

      assert {:ok, loaded} = RedisStore.get_conversation(conv.conversation_id)
      assert loaded.fingerprint_hash == "updated_hash"
    end
  end

  describe "delete/1" do
    test "removes the conversation and all its associated state" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      # Verify keys exist before delete
      assert {:ok, fields} =
               Redix.command(ShhAi.Redis, [
                 "HGETALL",
                 "shh_ai:conversation:#{conv.conversation_id}"
               ])

      assert fields != []

      assert :ok = RedisStore.delete(conv.conversation_id)

      # Verify keys are gone after delete
      assert {:ok, []} =
               Redix.command(ShhAi.Redis, [
                 "HGETALL",
                 "shh_ai:conversation:#{conv.conversation_id}"
               ])

      assert {:ok, []} =
               Redix.command(ShhAi.Redis, [
                 "HGETALL",
                 "shh_ai:conversation:#{conv.conversation_id}:mapping"
               ])

      assert {:ok, []} =
               Redix.command(ShhAi.Redis, [
                 "HGETALL",
                 "shh_ai:conversation:#{conv.conversation_id}:reverse_index"
               ])
    end

    test "is idempotent — deleting a non-existent conversation returns :ok" do
      assert :ok = RedisStore.delete("nonexistent_uuid")
    end

    test "after delete, get_mapping/1 returns {:error, :not_found}" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok = RedisStore.delete(conv.conversation_id)

      assert {:error, :not_found} = RedisStore.get_mapping(conv.conversation_id)
    end

    test "after delete, get_reverse_index/1 returns {:error, :not_found}" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      :ok =
        RedisStore.add_mapping(
          conv.conversation_id,
          %{},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok = RedisStore.delete(conv.conversation_id)

      assert {:error, :not_found} = RedisStore.get_reverse_index(conv.conversation_id)
    end

    test "does not affect other conversations" do
      conv_a = build_conversation(provider_conversation_id: "thread_a")
      conv_b = build_conversation(provider_conversation_id: "thread_b")
      :ok = RedisStore.create(conv_a)
      :ok = RedisStore.create(conv_b)

      :ok =
        RedisStore.add_mapping(
          conv_a.conversation_id,
          %{"EMAIL_1" => "a@example.com"},
          %{{"a@example.com", :email} => "EMAIL_1"}
        )

      :ok =
        RedisStore.add_mapping(
          conv_b.conversation_id,
          %{"EMAIL_1" => "b@example.com"},
          %{{"b@example.com", :email} => "EMAIL_1"}
        )

      :ok = RedisStore.delete(conv_a.conversation_id)

      # conv_a is gone.
      assert {:error, :not_found} = RedisStore.get_mapping(conv_a.conversation_id)

      # conv_b remains intact.
      assert {:ok, %{"EMAIL_1" => "b@example.com"}} =
               RedisStore.get_mapping(conv_b.conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_conversation/1
  # ---------------------------------------------------------------------------

  describe "get_conversation/1" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = RedisStore.get_conversation("nonexistent_uuid")
    end

    test "returns a Conversation struct for an existing conversation" do
      now = System.monotonic_time(:millisecond)

      conv =
        build_conversation(
          source_provider: :anthropic,
          provider_conversation_id: "thread_xyz",
          created_at: now,
          last_active_at: now,
          fingerprint_hash: "abc123"
        )

      :ok = RedisStore.create(conv)

      assert {:ok, %Conversation{} = loaded} = RedisStore.get_conversation(conv.conversation_id)

      assert loaded.conversation_id == conv.conversation_id
      assert loaded.source_provider == :anthropic
      assert loaded.created_at == now
      assert loaded.last_active_at == now
      assert loaded.provider_conversation_id == "thread_xyz"
      assert loaded.fingerprint_hash == "abc123"
      assert loaded.mapping == %{}
      assert loaded.reverse_index == %{}
      assert loaded.new? == false
    end

    test "returns the correct mapping and reverse_index" do
      conv = build_conversation()
      :ok = RedisStore.create(conv)

      mapping = %{"EMAIL_1" => "john@example.com", "PERSON_1" => "John"}

      reverse_index = %{
        {"john@example.com", :email} => "EMAIL_1",
        {"John", :person} => "PERSON_1"
      }

      :ok = RedisStore.add_mapping(conv.conversation_id, mapping, reverse_index)

      assert {:ok, %Conversation{} = loaded} = RedisStore.get_conversation(conv.conversation_id)

      assert loaded.mapping == mapping
      assert loaded.reverse_index == reverse_index
    end
  end

  # ---------------------------------------------------------------------------
  # cleanup_expired/0
  # ---------------------------------------------------------------------------

  describe "cleanup_expired/0" do
    test "returns 0 since Redis handles TTL natively" do
      assert 0 = RedisStore.cleanup_expired()
    end
  end
end
