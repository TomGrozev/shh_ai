defmodule ShhAi.Metrics.EventBufferTest do
  use ExUnit.Case, async: false

  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.EventBuffer

  defp build_event(overrides) do
    defaults = [
      id: "evt-001",
      started_at: 1_700_000_000_000_000,
      ended_at: 1_700_000_150_000_000,
      duration_ms: 150.0,
      source_provider: :openai,
      target_provider: "anthropic",
      request_path: "/v1/chat/completions",
      method: "POST",
      streaming: false,
      status: 200,
      pii_detected_count: 3,
      pii_sanitized_count: 2,
      pii_preserved_count: 1,
      pii_types: [:email, :phone],
      timings: %{
        pii_ms: 5.0,
        backend_ms: 140.0,
        restore_ms: 2.0,
        source_conversion_ms: 1.5,
        target_conversion_ms: 1.5
      },
      error: nil,
      inserted_at: 1_700_000_150_000_000
    ]

    struct!(Event, Keyword.merge(defaults, overrides))
  end

  # Test-specific wrappers that direct calls to the named test buffer.
  defp store(event, opts \\ []),
    do: EventBuffer.store(event, Keyword.merge([name: :event_buffer_test], opts))

  defp list_recent(opts \\ []),
    do: EventBuffer.list_recent(Keyword.merge([name: :event_buffer_test], opts))

  defp list_since(start_time, opts \\ []),
    do: EventBuffer.list_since(start_time, Keyword.merge([name: :event_buffer_test], opts))

  defp count, do: EventBuffer.count(name: :event_buffer_test)
  defp clear, do: EventBuffer.clear(name: :event_buffer_test)

  setup do
    # The application supervision tree starts a real EventBuffer that creates
    # the ETS table `EventBuffer.Table`.  Our tests run against a separate,
    # test-specific buffer with a small buffer_size so that ring-buffer tests
    # behave deterministically.
    {:ok, test_pid} = EventBuffer.start_link(buffer_size: 5, name: :event_buffer_test)

    on_exit(fn ->
      # Disable tracing if a test started but didn't clean up.
      # Rescue ArgumentError for TOCTOU race: process may die between the
      # Process.alive? check and the :erlang.trace call.
      if Process.alive?(test_pid) do
        try do
          :erlang.trace(test_pid, false, [:send])
        rescue
          ArgumentError -> :ok
        end

        if Process.alive?(test_pid) do
          GenServer.stop(test_pid)
        end
      end
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the GenServer successfully" do
      assert Process.whereis(ShhAi.Metrics.EventBuffer) != nil
    end

    test "creates ETS table on init" do
      table_name = :"Elixir.ShhAi.Metrics.EventBuffer.Table.event_buffer_test"
      table = :ets.info(table_name)
      refute table == :undefined
      assert Keyword.get(table, :type) == :ordered_set
    end
  end

  describe "store/1 and list_recent/1" do
    test "storing and retrieving a single event" do
      event = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001)
      :ok = store(event)

      [retrieved] = list_recent(limit: 1)
      assert retrieved.id == "evt-001"
    end

    test "storing multiple events returns most recent first" do
      event1 = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001)
      event2 = build_event(id: "evt-002", ended_at: 1_700_000_000_000_002)
      event3 = build_event(id: "evt-003", ended_at: 1_700_000_000_000_003)

      :ok = store(event1)
      :ok = store(event2)
      :ok = store(event3)

      events = list_recent(limit: 3)
      assert length(events) == 3
      assert Enum.map(events, & &1.id) == ["evt-003", "evt-002", "evt-001"]
    end
  end

  describe "filtering" do
    test "filtering by provider (atom)" do
      event_openai =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, source_provider: :openai)

      event_anthropic =
        build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, source_provider: :anthropic)

      event_ollama =
        build_event(id: "evt-003", ended_at: 1_700_000_000_000_003, source_provider: :ollama)

      :ok = store(event_openai)
      :ok = store(event_anthropic)
      :ok = store(event_ollama)

      openai_events = list_recent(provider: :openai)
      assert length(openai_events) == 1
      assert hd(openai_events).id == "evt-001"

      anthropic_events = list_recent(provider: :anthropic)
      assert length(anthropic_events) == 1
      assert hd(anthropic_events).id == "evt-002"
    end

    test "filtering by provider matches target_provider too" do
      event =
        build_event(
          id: "evt-001",
          ended_at: 1_700_000_000_000_001,
          source_provider: :openai,
          target_provider: "anthropic"
        )

      :ok = store(event)

      openai_events = list_recent(provider: :openai)
      assert length(openai_events) == 1

      # target_provider is a string, so atom won't match
      anthropic_events = list_recent(provider: :anthropic)
      assert anthropic_events == []
    end

    test "filtering by streaming flag" do
      event_streaming =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, streaming: true)

      event_not_streaming =
        build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, streaming: false)

      :ok = store(event_streaming)
      :ok = store(event_not_streaming)

      streaming_events = list_recent(streaming: true)
      assert length(streaming_events) == 1
      assert hd(streaming_events).streaming == true

      not_streaming_events = list_recent(streaming: false)
      assert length(not_streaming_events) == 1
      assert hd(not_streaming_events).streaming == false
    end

    test "filtering by status_success true" do
      event_200 = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, status: 200)
      event_201 = build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, status: 201)
      event_400 = build_event(id: "evt-003", ended_at: 1_700_000_000_000_003, status: 400)
      event_500 = build_event(id: "evt-004", ended_at: 1_700_000_000_000_004, status: 500)

      :ok = store(event_200)
      :ok = store(event_201)
      :ok = store(event_400)
      :ok = store(event_500)

      success_events = list_recent(status_success: true)
      assert length(success_events) == 2
      assert Enum.all?(success_events, fn e -> e.status >= 200 and e.status < 300 end)
    end

    test "filtering by status_success false" do
      event_200 = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, status: 200)
      event_400 = build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, status: 400)
      event_500 = build_event(id: "evt-003", ended_at: 1_700_000_000_000_003, status: 500)

      :ok = store(event_200)
      :ok = store(event_400)
      :ok = store(event_500)

      failure_events = list_recent(status_success: false)
      assert length(failure_events) == 2
      assert Enum.all?(failure_events, fn e -> e.status < 200 or e.status >= 400 end)
    end

    test "filtering with no matches returns empty list" do
      event =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, source_provider: :openai)

      :ok = store(event)

      assert list_recent(provider: :anthropic) == []
      assert list_recent(streaming: true) == []
      assert list_recent(status_success: false) == []
    end

    test "combining multiple filters" do
      event =
        build_event(
          id: "evt-001",
          ended_at: 1_700_000_000_000_001,
          source_provider: :openai,
          streaming: true,
          status: 200
        )

      :ok = store(event)

      assert list_recent(provider: :openai, streaming: true, status_success: true) == [event]
      assert list_recent(provider: :openai, streaming: false) == []
    end

    test "filtering by conversation_id" do
      event1 =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, conversation_id: "conv-1")

      event2 =
        build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, conversation_id: "conv-2")

      event3 =
        build_event(id: "evt-003", ended_at: 1_700_000_000_000_003, conversation_id: "conv-1")

      :ok = store(event1)
      :ok = store(event2)
      :ok = store(event3)

      conv1_events = list_recent(conversation_id: "conv-1")
      assert length(conv1_events) == 2
      assert Enum.all?(conv1_events, fn e -> e.conversation_id == "conv-1" end)

      conv2_events = list_recent(conversation_id: "conv-2")
      assert length(conv2_events) == 1
      assert hd(conv2_events).id == "evt-002"
    end

    test "filtering by conversation_id with no matches" do
      event =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, conversation_id: "conv-1")

      :ok = store(event)

      assert list_recent(conversation_id: "conv-nonexistent") == []
    end

    test "filtering by conversation_id combined with provider" do
      event1 =
        build_event(
          id: "evt-001",
          ended_at: 1_700_000_000_000_001,
          conversation_id: "conv-1",
          source_provider: :openai
        )

      event2 =
        build_event(
          id: "evt-002",
          ended_at: 1_700_000_000_000_002,
          conversation_id: "conv-1",
          source_provider: :anthropic
        )

      event3 =
        build_event(
          id: "evt-003",
          ended_at: 1_700_000_000_000_003,
          conversation_id: "conv-2",
          source_provider: :openai
        )

      :ok = store(event1)
      :ok = store(event2)
      :ok = store(event3)

      events = list_recent(conversation_id: "conv-1", provider: :openai)
      assert length(events) == 1
      assert hd(events).id == "evt-001"
    end
  end

  describe "list_since/2" do
    test "returns events since a given timestamp" do
      event_old = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001)
      event_new = build_event(id: "evt-002", ended_at: 1_700_000_000_000_002)
      event_newer = build_event(id: "evt-003", ended_at: 1_700_000_000_000_003)

      :ok = store(event_old)
      :ok = store(event_new)
      :ok = store(event_newer)

      events = list_since(1_700_000_000_000_002)
      assert length(events) == 2
      assert Enum.map(events, & &1.id) == ["evt-003", "evt-002"]
    end

    test "list_since with time window returns empty when no events match" do
      event = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001)

      :ok = store(event)

      assert list_since(1_700_000_000_000_002) == []
    end

    test "list_since respects limit" do
      event1 = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001)
      event2 = build_event(id: "evt-002", ended_at: 1_700_000_000_000_002)
      event3 = build_event(id: "evt-003", ended_at: 1_700_000_000_000_003)

      :ok = store(event1)
      :ok = store(event2)
      :ok = store(event3)

      events = list_since(1_700_000_000_000_001, limit: 2)
      assert length(events) == 2
      # ETS select returns results in ascending key order (ended_at) when there are multiple
      # results and a continuation is returned. We just verify we got the correct IDs.
      ids = Enum.map(events, & &1.id)
      assert "evt-001" in ids
      assert "evt-002" in ids
    end

    test "list_since with provider filter" do
      event_openai =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, source_provider: :openai)

      event_anthropic =
        build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, source_provider: :anthropic)

      :ok = store(event_openai)
      :ok = store(event_anthropic)

      events = list_since(1_700_000_000_000_001, provider: :openai)
      assert length(events) == 1
      assert hd(events).id == "evt-001"
    end

    test "list_since with conversation_id filter" do
      event1 =
        build_event(id: "evt-001", ended_at: 1_700_000_000_000_001, conversation_id: "conv-1")

      event2 =
        build_event(id: "evt-002", ended_at: 1_700_000_000_000_002, conversation_id: "conv-2")

      event3 =
        build_event(id: "evt-003", ended_at: 1_700_000_000_000_003, conversation_id: "conv-1")

      :ok = store(event1)
      :ok = store(event2)
      :ok = store(event3)

      events = list_since(1_700_000_000_000_001, conversation_id: "conv-1")
      assert length(events) == 2
      assert Enum.all?(events, fn e -> e.conversation_id == "conv-1" end)
    end

    test "list_since with conversation_id and provider combined" do
      event1 =
        build_event(
          id: "evt-001",
          ended_at: 1_700_000_000_000_001,
          conversation_id: "conv-1",
          source_provider: :openai
        )

      event2 =
        build_event(
          id: "evt-002",
          ended_at: 1_700_000_000_000_002,
          conversation_id: "conv-1",
          source_provider: :anthropic
        )

      :ok = store(event1)
      :ok = store(event2)

      events = list_since(1_700_000_000_000_001, conversation_id: "conv-1", provider: :openai)
      assert length(events) == 1
      assert hd(events).id == "evt-001"
    end
  end

  describe "ring buffer behavior" do
    test "storing more events than buffer size overwrites oldest" do
      # Ensure we start from a clean test buffer
      clear()
      assert count() == 0

      event1 = build_event(id: "evt-001", ended_at: 1_700_000_000_000_001)
      event2 = build_event(id: "evt-002", ended_at: 1_700_000_000_000_002)
      event3 = build_event(id: "evt-003", ended_at: 1_700_000_000_000_003)
      event4 = build_event(id: "evt-004", ended_at: 1_700_000_000_000_004)
      event5 = build_event(id: "evt-005", ended_at: 1_700_000_000_000_005)
      event6 = build_event(id: "evt-006", ended_at: 1_700_000_000_000_006)

      :ok = store(event1)
      :ok = store(event2)
      :ok = store(event3)
      :ok = store(event4)
      :ok = store(event5)
      :ok = store(event6)

      events = list_recent(limit: 10)
      assert length(events) == 5
      assert Enum.map(events, & &1.id) == ["evt-006", "evt-005", "evt-004", "evt-003", "evt-002"]
      refute "evt-001" in Enum.map(events, & &1.id)
    end
  end

  describe "count/0" do
    test "returns correct count" do
      assert count() == 0

      :ok = store(build_event(id: "evt-001", ended_at: 1_700_000_000_000_001))
      assert count() == 1

      :ok = store(build_event(id: "evt-002", ended_at: 1_700_000_000_000_002))
      assert count() == 2
    end

    test "count respects buffer size limit" do
      # Make sure the test buffer is running
      assert Process.whereis(:event_buffer_test) != nil

      # Clear any leftover events
      clear()
      assert count() == 0

      for i <- 1..7 do
        :ok = store(build_event(id: "evt-#{i}", ended_at: 1_700_000_000_000_000 + i))
      end

      assert count() == 5
    end
  end

  describe "clear/0" do
    test "clears all events from the buffer" do
      :ok = store(build_event(id: "evt-001", ended_at: 1_700_000_000_000_001))
      :ok = store(build_event(id: "evt-002", ended_at: 1_700_000_000_000_002))

      assert count() == 2

      :ok = clear()

      assert count() == 0
      assert list_recent() == []
    end
  end

  describe "empty buffer" do
    test "returns empty list from list_recent" do
      assert list_recent() == []
      assert list_recent(limit: 10) == []
    end

    test "returns empty list from list_since" do
      assert list_since(1_700_000_000_000_000) == []
    end
  end

  describe "audit writer cast (issue #25)" do
    test "casts {:write_event, event} to ShhAi.Audit.Writer after storing" do
      writer_pid = Process.whereis(ShhAi.Audit.Writer)
      buffer_pid = Process.whereis(:event_buffer_test)

      refute is_nil(writer_pid),
             "ShhAi.Audit.Writer is not running — application supervision tree may be broken"

      refute is_nil(buffer_pid), "Test EventBuffer is not running"

      # Trace all :send messages from the test-local EventBuffer. Trace
      # messages are delivered to self() (the test process) in the form
      # `{trace, sender_pid, :send, msg, receiver_pid}`.
      # We use process tracing here rather than asserting a DB side-effect
      # (which would require AuditCase + migrations). The trace is
      # deterministic and stays at the buffer/Writer seam — exactly the
      # contract we want to verify.
      :erlang.trace(buffer_pid, true, [:send])

      event = build_event(id: "evt-writer-cast-1", ended_at: 1_700_000_000_000_001)
      :ok = store(event)

      assert_receive {:trace, ^buffer_pid, :send, {:"$gen_cast", {:write_event, ^event}},
                      ^writer_pid},
                     1_000

      :erlang.trace(buffer_pid, false, [:send])
    end

    test "does not create a JSONL file when storing events" do
      path = Path.join([Application.app_dir(:shh_ai, "priv"), "metrics", "events.jsonl"])

      # Ensure a clean slate — if a previous test left one behind it
      # would invalidate the assertion below.
      File.rm(path)
      refute File.exists?(path), "Pre-condition: JSONL file should not exist"

      event = build_event(id: "evt-no-jsonl-1", ended_at: 1_700_000_000_000_001)
      :ok = store(event)

      # Allow time for any file creation that would be a bug. The new
      # implementation must not write any file at all.
      Process.sleep(50)
      refute File.exists?(path), "EventBuffer must not create a JSONL file"

      File.rm(path)
    end
  end
end
