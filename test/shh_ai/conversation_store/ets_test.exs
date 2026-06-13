defmodule ShhAi.ConversationStore.ETSTest do
  # async: false — these tests touch the shared named ETS tables
  # (:conversations, :conversation_mappings, :conversation_reverse_index)
  # and must not race with each other or with ConversationStoreTest.
  use ExUnit.Case, async: false

  alias ShhAi.Conversation
  alias ShhAi.ConversationStore.ETS, as: ETSStore

  setup do
    ShhAi.ConversationCase.setup_ets()
  end

  # ---------------------------------------------------------------------------
  # Helper: build a %Conversation{} struct ready for ETSStore.create/1
  # ---------------------------------------------------------------------------

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
    test "creates the three named ETS tables" do
      assert is_list(:ets.info(:conversations))
      assert is_list(:ets.info(:conversation_mappings))
      assert is_list(:ets.info(:conversation_reverse_index))
    end

    test "is idempotent — running twice does not error" do
      assert :ok = ETSStore.init()
      assert :ok = ETSStore.init()
    end

    test "returns :ok" do
      assert :ok = ETSStore.init()
    end
  end

  # ---------------------------------------------------------------------------
  # create/1
  # ---------------------------------------------------------------------------

  describe "create/1" do
    test "returns :ok and stores the conversation in the ETS table" do
      conv = build_conversation()
      assert :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      assert [{^conversation_id, :openai, _, _, "thread_abc123", nil}] =
               :ets.lookup(:conversations, conversation_id)
    end

    test "populates source_provider and provider_conversation_id from struct" do
      conv = build_conversation(source_provider: :anthropic, provider_conversation_id: "conv_456")
      :ok = ETSStore.create(conv)

      assert [{_, :anthropic, _, _, "conv_456", nil}] =
               :ets.lookup(:conversations, conv.conversation_id)
    end

    test "stores timestamps from the struct" do
      now = System.monotonic_time(:millisecond)
      conv = build_conversation(created_at: now, last_active_at: now)
      :ok = ETSStore.create(conv)

      assert [{_, _, created_at, last_active_at, _, nil}] =
               :ets.lookup(:conversations, conv.conversation_id)

      assert created_at == now
      assert last_active_at == now
    end

    test "stores the row in the :conversations ETS table" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      assert [{^conversation_id, :openai, created_at, last_active_at, "thread_abc123", nil}] =
               :ets.lookup(:conversations, conversation_id)

      assert created_at == conv.created_at
      assert last_active_at == conv.last_active_at
    end

    test "works with a nil provider_conversation_id" do
      conv = build_conversation(provider_conversation_id: nil)
      assert :ok = ETSStore.create(conv)

      assert [{_, :openai, _, _, nil, nil}] =
               :ets.lookup(:conversations, conv.conversation_id)
    end

    test "generates a unique conversation_id for each struct" do
      c1 = build_conversation()
      c2 = build_conversation()
      :ok = ETSStore.create(c1)
      :ok = ETSStore.create(c2)
      refute c1.conversation_id == c2.conversation_id
    end
  end

  # ---------------------------------------------------------------------------
  # add_mapping/3, get_mapping/1, get_reverse_index/1
  # ---------------------------------------------------------------------------

  describe "add_mapping/3 + get_mapping/1" do
    test "stores a mapping and retrieves it" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      mapping = %{"EMAIL_1" => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => "EMAIL_1"}

      assert :ok = ETSStore.add_mapping(conv.conversation_id, mapping, reverse_index)

      assert {:ok, %{"EMAIL_1" => "john@example.com"}} =
               ETSStore.get_mapping(conv.conversation_id)
    end

    test "multiple add_mapping calls accumulate entries across calls" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      :ok =
        ETSStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok =
        ETSStore.add_mapping(
          conv.conversation_id,
          %{"PERSON_1" => "John"},
          %{{"John", :person} => "PERSON_1"}
        )

      assert {:ok, accumulated} = ETSStore.get_mapping(conv.conversation_id)
      assert accumulated["EMAIL_1"] == "john@example.com"
      assert accumulated["PERSON_1"] == "John"
    end

    test "add_mapping is atomic — existing placeholder keys are NOT overwritten" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      :ok =
        ETSStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      # Attempt to overwrite the binding for EMAIL_1 with a different value.
      # This must NOT take effect because of `:ets.insert_new/2`'s
      # first-writer-wins semantics.
      :ok =
        ETSStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "jane@example.com"},
          %{{"jane@example.com", :email} => "EMAIL_1"}
        )

      assert {:ok, %{"EMAIL_1" => "john@example.com"}} =
               ETSStore.get_mapping(conv.conversation_id)
    end

    test "get_mapping/1 returns {:error, :not_found} for a nonexistent conversation_id" do
      assert {:error, :not_found} = ETSStore.get_mapping("nonexistent_uuid")
    end

    test "get_mapping/1 returns {:ok, %{}} for an existing conversation with no mapping entries" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      assert {:ok, %{}} = ETSStore.get_mapping(conv.conversation_id)
    end
  end

  describe "add_mapping/3 + get_reverse_index/1" do
    test "stores a reverse index and retrieves it" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      reverse_index = %{{"john@example.com", :email} => "EMAIL_1"}

      assert :ok = ETSStore.add_mapping(conv.conversation_id, %{}, reverse_index)

      assert {:ok, %{{"john@example.com", :email} => "EMAIL_1"}} =
               ETSStore.get_reverse_index(conv.conversation_id)
    end

    test "multiple add_mapping calls accumulate reverse-index entries" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      ETSStore.add_mapping(conv.conversation_id, %{}, %{{"john@example.com", :email} => "EMAIL_1"})
      ETSStore.add_mapping(conv.conversation_id, %{}, %{{"John", :person} => "PERSON_1"})

      assert {:ok, ri} = ETSStore.get_reverse_index(conv.conversation_id)
      assert ri[{"john@example.com", :email}] == "EMAIL_1"
      assert ri[{"John", :person}] == "PERSON_1"
    end

    test "reverse index entries are also atomic — existing keys are not overwritten" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      ETSStore.add_mapping(
        conv.conversation_id,
        %{},
        %{{"john@example.com", :email} => "EMAIL_1"}
      )

      ETSStore.add_mapping(
        conv.conversation_id,
        %{},
        %{{"john@example.com", :email} => "EMAIL_99"}
      )

      assert {:ok, %{{"john@example.com", :email} => "EMAIL_1"}} =
               ETSStore.get_reverse_index(conv.conversation_id)
    end

    test "get_reverse_index/1 returns {:error, :not_found} for a nonexistent conversation_id" do
      assert {:error, :not_found} = ETSStore.get_reverse_index("nonexistent_uuid")
    end

    test "get_reverse_index/1 returns {:ok, %{}} for an existing conversation with no reverse index" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      assert {:ok, %{}} = ETSStore.get_reverse_index(conv.conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # lookup_placeholder/3
  # ---------------------------------------------------------------------------

  describe "lookup_placeholder/3" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} =
               ETSStore.lookup_placeholder("nonexistent_uuid", "value", :email)
    end

    test "returns {:error, :not_found} for an existing conversation where the PII has not been seen" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      assert {:error, :not_found} =
               ETSStore.lookup_placeholder(
                 conv.conversation_id,
                 "jane@example.com",
                 :email
               )
    end

    test "returns {:ok, placeholder_key} for a previously-seen {original_value, pii_type}" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      :ok =
        ETSStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert {:ok, "EMAIL_1"} =
               ETSStore.lookup_placeholder(
                 conv.conversation_id,
                 "john@example.com",
                 :email
               )
    end

    test "matches on pii_type — same original_value under a different type is not found" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      :ok =
        ETSStore.add_mapping(
          conv.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert {:error, :not_found} =
               ETSStore.lookup_placeholder(
                 conv.conversation_id,
                 "john@example.com",
                 :person
               )
    end

    test "does not bleed across conversations — the same key in a different conversation is not found" do
      conv_a = build_conversation(provider_conversation_id: "thread_a")
      conv_b = build_conversation(provider_conversation_id: "thread_b")
      :ok = ETSStore.create(conv_a)
      :ok = ETSStore.create(conv_b)

      :ok =
        ETSStore.add_mapping(
          conv_a.conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert {:error, :not_found} =
               ETSStore.lookup_placeholder(
                 conv_b.conversation_id,
                 "john@example.com",
                 :email
               )
    end
  end

  # ---------------------------------------------------------------------------
  # touch/1 and cleanup_expired/0 — sliding TTL
  # ---------------------------------------------------------------------------

  describe "touch/1" do
    test "updates last_active_at to the current monotonic time" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id
      original_last_active = conv.last_active_at
      before_touch = System.monotonic_time(:millisecond)

      # Sleep to ensure the monotonic clock advances by at least 1ms. On busy
      # CI runners, `System.monotonic_time(:millisecond)` can return the
      # same value across tightly-spaced calls; the small sleep makes the
      # assertion robust without slowing tests meaningfully.
      Process.sleep(2)

      assert :ok = ETSStore.touch(conversation_id)

      after_touch = System.monotonic_time(:millisecond)

      [{^conversation_id, :openai, created_at, new_last_active, "thread_abc123", nil}] =
        :ets.lookup(:conversations, conversation_id)

      assert new_last_active > original_last_active
      assert new_last_active >= before_touch
      assert new_last_active <= after_touch + 1_000

      # created_at must be unchanged by touch.
      assert created_at == conv.created_at
    end

    test "does NOT change created_at" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id
      assert :ok = ETSStore.touch(conversation_id)

      [{^conversation_id, :openai, created_at, _, "thread_abc123", nil}] =
        :ets.lookup(:conversations, conversation_id)

      assert created_at == conv.created_at
    end

    test "returns {:error, :not_found} for a non-existent conversation_id" do
      assert {:error, :not_found} = ETSStore.touch("nonexistent_uuid")
    end
  end

  describe "cleanup_expired/0" do
    test "removes conversations whose last_active_at is older than the default TTL" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      # Backdate last_active_at to well past the default 1h TTL.
      past = System.monotonic_time(:millisecond) - 7_200_000
      :ets.insert(:conversations, {conversation_id, :openai, past, past, "thread_abc123", nil})

      assert 1 = ETSStore.cleanup_expired()

      assert [] = :ets.lookup(:conversations, conversation_id)
    end

    test "also removes associated mappings and reverse-index entries for expired conversations" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      :ok =
        ETSStore.add_mapping(
          conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      # Sanity: rows are present before cleanup.
      assert [_] = :ets.match_object(:conversation_mappings, {{conversation_id, :_}, :_})
      assert [_] = :ets.match_object(:conversation_reverse_index, {{conversation_id, :_, :_}, :_})

      # Backdate and clean up.
      past = System.monotonic_time(:millisecond) - 7_200_000
      :ets.insert(:conversations, {conversation_id, :openai, past, past, "thread_abc123", nil})

      assert 1 = ETSStore.cleanup_expired()

      assert [] = :ets.match_object(:conversation_mappings, {{conversation_id, :_}, :_})
      assert [] = :ets.match_object(:conversation_reverse_index, {{conversation_id, :_, :_}, :_})
    end

    test "leaves non-expired conversations alone" do
      active = build_conversation(provider_conversation_id: "active")
      :ok = ETSStore.create(active)

      active_id = active.conversation_id

      # `active` is brand new (last_active_at = now) and is well within the
      # default 1h TTL. The cleanup must not touch it.
      assert 0 = ETSStore.cleanup_expired()

      assert [_] = :ets.lookup(:conversations, active_id)
    end

    test "returns the count of expired conversations removed" do
      c1 = build_conversation(provider_conversation_id: "c1")
      c2 = build_conversation(provider_conversation_id: "c2")
      c3 = build_conversation(provider_conversation_id: "c3")
      :ok = ETSStore.create(c1)
      :ok = ETSStore.create(c2)
      :ok = ETSStore.create(c3)

      # Backdate c1 and c2 to past the default TTL; leave c3 fresh.
      past = System.monotonic_time(:millisecond) - 7_200_000
      :ets.insert(:conversations, {c1.conversation_id, :openai, past, past, "c1", nil})
      :ets.insert(:conversations, {c2.conversation_id, :openai, past, past, "c2", nil})

      assert 2 = ETSStore.cleanup_expired()

      # c3 remains.
      assert [_] = :ets.lookup(:conversations, c3.conversation_id)

      # Second call removes nothing — the expired ones are already gone.
      assert 0 = ETSStore.cleanup_expired()
    end
  end

  describe "cleanup_expired/1 (testable TTL variant)" do
    test "evicts conversations whose last_active_at is older than the given ttl_ms" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      # Backdate by 10 seconds.
      ten_seconds_ago = System.monotonic_time(:millisecond) - 10_000
      :ets.insert(:conversations, {conversation_id, :openai, ten_seconds_ago, ten_seconds_ago, "thread_abc123", nil})

      # 5-second TTL — 10s in the past is expired.
      assert 1 = ETSStore.cleanup_expired(5_000)
      assert [] = :ets.lookup(:conversations, conversation_id)
    end

    test "leaves conversations alone when the TTL is generous" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      # 10 seconds in the past is NOT expired under a 1-hour TTL.
      ten_seconds_ago = System.monotonic_time(:millisecond) - 10_000
      :ets.insert(:conversations, {conv.conversation_id, :openai, ten_seconds_ago, ten_seconds_ago, "thread_abc123", nil})

      assert 0 = ETSStore.cleanup_expired(3_600_000)
      assert [_] = :ets.lookup(:conversations, conv.conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # migrate_id/2
  # ---------------------------------------------------------------------------

  describe "migrate_id/2" do
    test "returns {:error, :not_found} for a non-existent old conversation" do
      assert {:error, :not_found} = ETSStore.migrate_id("nonexistent_old", "new_id")
    end

    test "migrates conversation metadata to the new id" do
      conv = build_conversation(source_provider: :anthropic, provider_conversation_id: "thread_xyz")
      :ok = ETSStore.create(conv)

      old_id = conv.conversation_id
      new_id = UUID.uuid4()

      assert :ok = ETSStore.migrate_id(old_id, new_id)

      # Old is gone.
      assert {:error, :not_found} = ETSStore.get_conversation(old_id)

      # New has the same metadata.
      assert {:ok, loaded} = ETSStore.get_conversation(new_id)
      assert loaded.conversation_id == new_id
      assert loaded.source_provider == :anthropic
      assert loaded.provider_conversation_id == "thread_xyz"
    end

    test "migrates mappings and reverse_index" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      old_id = conv.conversation_id
      new_id = UUID.uuid4()

      mapping = %{"EMAIL_1" => "john@example.com", "PERSON_1" => "John"}
      reverse_index = %{{"john@example.com", :email} => "EMAIL_1", {"John", :person} => "PERSON_1"}

      :ok = ETSStore.add_mapping(old_id, mapping, reverse_index)

      assert :ok = ETSStore.migrate_id(old_id, new_id)

      assert {:ok, migrated_mapping} = ETSStore.get_mapping(new_id)
      assert migrated_mapping == mapping

      assert {:ok, migrated_ri} = ETSStore.get_reverse_index(new_id)
      assert migrated_ri == reverse_index
    end

    test "old conversation is deleted after migration" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      old_id = conv.conversation_id
      new_id = UUID.uuid4()

      :ok =
        ETSStore.add_mapping(
          old_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok = ETSStore.migrate_id(old_id, new_id)

      # Old conversation, mappings, and reverse_index are all gone.
      assert [] = :ets.lookup(:conversations, old_id)
      assert [] = :ets.match_object(:conversation_mappings, {{old_id, :_}, :_})
      assert [] = :ets.match_object(:conversation_reverse_index, {{old_id, :_, :_}, :_})
    end

    test "idempotent — migrating to the same id is a no-op" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      old_id = conv.conversation_id

      :ok =
        ETSStore.add_mapping(
          old_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      assert :ok = ETSStore.migrate_id(old_id, old_id)

      # Conversation still exists with all data intact.
      assert {:ok, loaded} = ETSStore.get_conversation(old_id)
      assert loaded.mapping == %{"EMAIL_1" => "john@example.com"}
    end
  end

  # ---------------------------------------------------------------------------
  # get_conversation/1
  # ---------------------------------------------------------------------------

  describe "get_conversation/1" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = ETSStore.get_conversation("nonexistent_uuid")
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

      :ok = ETSStore.create(conv)

      assert {:ok, %Conversation{} = loaded} = ETSStore.get_conversation(conv.conversation_id)

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
      :ok = ETSStore.create(conv)

      mapping = %{"EMAIL_1" => "john@example.com", "PERSON_1" => "John"}
      reverse_index = %{{"john@example.com", :email} => "EMAIL_1", {"John", :person} => "PERSON_1"}

      :ok = ETSStore.add_mapping(conv.conversation_id, mapping, reverse_index)

      assert {:ok, %Conversation{} = loaded} = ETSStore.get_conversation(conv.conversation_id)

      assert loaded.mapping == mapping
      assert loaded.reverse_index == reverse_index
    end
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  describe "update_fingerprint/2" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = ETSStore.update_fingerprint("nonexistent_uuid", "new_hash")
    end

    test "updates the fingerprint_hash for an existing conversation" do
      conv = build_conversation(fingerprint_hash: "original_hash")
      :ok = ETSStore.create(conv)

      assert :ok = ETSStore.update_fingerprint(conv.conversation_id, "updated_hash")

      assert {:ok, loaded} = ETSStore.get_conversation(conv.conversation_id)
      assert loaded.fingerprint_hash == "updated_hash"
    end
  end

  describe "delete/1" do
    test "removes the conversation and all its associated state (mappings + reverse index)" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      :ok =
        ETSStore.add_mapping(
          conversation_id,
          %{"EMAIL_1" => "john@example.com", "PERSON_1" => "John"},
          %{
            {"john@example.com", :email} => "EMAIL_1",
            {"John", :person} => "PERSON_1"
          }
        )

      # Sanity: rows exist before delete.
      assert [_] = :ets.lookup(:conversations, conversation_id)
      assert [_ | _] = :ets.match_object(:conversation_mappings, {{conversation_id, :_}, :_})
      assert [_ | _] = :ets.match_object(:conversation_reverse_index, {{conversation_id, :_, :_}, :_})

      assert :ok = ETSStore.delete(conversation_id)

      assert [] = :ets.lookup(:conversations, conversation_id)
      assert [] = :ets.match_object(:conversation_mappings, {{conversation_id, :_}, :_})
      assert [] = :ets.match_object(:conversation_reverse_index, {{conversation_id, :_, :_}, :_})
    end

    test "is idempotent — deleting a non-existent conversation returns :ok" do
      # Deleting a non-existent conversation is idempotent — returns :ok.
      # This makes `delete` safe to call from cleanup passes and from retry
      # logic.
      assert :ok = ETSStore.delete("nonexistent_uuid")
    end

    test "after delete, get_mapping/1 returns {:error, :not_found}" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      :ok =
        ETSStore.add_mapping(
          conversation_id,
          %{"EMAIL_1" => "john@example.com"},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok = ETSStore.delete(conversation_id)

      assert {:error, :not_found} = ETSStore.get_mapping(conversation_id)
    end

    test "after delete, get_reverse_index/1 returns {:error, :not_found}" do
      conv = build_conversation()
      :ok = ETSStore.create(conv)

      conversation_id = conv.conversation_id

      :ok =
        ETSStore.add_mapping(
          conversation_id,
          %{},
          %{{"john@example.com", :email} => "EMAIL_1"}
        )

      :ok = ETSStore.delete(conversation_id)

      assert {:error, :not_found} = ETSStore.get_reverse_index(conversation_id)
    end

    test "does not affect other conversations" do
      conv_a = build_conversation(provider_conversation_id: "thread_a")
      conv_b = build_conversation(provider_conversation_id: "thread_b")
      :ok = ETSStore.create(conv_a)
      :ok = ETSStore.create(conv_b)

      :ok =
        ETSStore.add_mapping(
          conv_a.conversation_id,
          %{"EMAIL_1" => "a@example.com"},
          %{{"a@example.com", :email} => "EMAIL_1"}
        )

      :ok =
        ETSStore.add_mapping(
          conv_b.conversation_id,
          %{"EMAIL_1" => "b@example.com"},
          %{{"b@example.com", :email} => "EMAIL_1"}
        )

      :ok = ETSStore.delete(conv_a.conversation_id)

      # conv_a is gone.
      assert [] = :ets.lookup(:conversations, conv_a.conversation_id)

      # conv_b remains intact.
      assert [_] = :ets.lookup(:conversations, conv_b.conversation_id)

      assert {:ok, %{"EMAIL_1" => "b@example.com"}} =
               ETSStore.get_mapping(conv_b.conversation_id)
    end
  end
end
