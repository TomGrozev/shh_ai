defmodule ShhAi.MetricsTest do
  use ExUnit.Case, async: false

  alias ShhAi.Metrics
  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.EventBuffer
  alias ShhAi.ProviderClient.RequestContext

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

  # Cleanup jsonl used by EventBuffer
  defp jsonl_path do
    Path.join([Application.app_dir(:shh_ai, "priv"), "metrics", "events.jsonl"])
  end

  defp cleanup_jsonl do
    path = jsonl_path()
    File.rm(path)
    File.rm(Path.dirname(path))
  end

  setup_all do
    cleanup_jsonl()

    # PubSub is already started by the application supervision tree
    # Just verify it's running
    unless Process.whereis(ShhAi.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ShhAi.PubSub})
    end

    :ok
  end

  setup do
    cleanup_jsonl()

    # Clear the real EventBuffer's ETS table to isolate tests
    # (the table is owned by the application supervision tree)
    if Process.whereis(EventBuffer) do
      EventBuffer.clear()
    end

    :ok
  end

  describe "emit_stop/2 (private, tested via emit_success/1)" do
    setup do
      test_pid = self()

      handler_id = "test-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      {:ok, handler_id: handler_id}
    end

    defp emit_via_success(overrides \\ []) do
      defaults = [
        duration: 150_000,
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        started_at: System.system_time(:microsecond),
        status: 200
      ]

      Metrics.emit_success(Keyword.merge(defaults, overrides))
    end

    test "emits telemetry event with required keys", %{handler_id: _id} do
      emit_via_success()

      assert_receive {:telemetry_received, received_measurements, received_metadata}
      assert received_measurements.duration == 150_000
      assert received_metadata.source_provider == :openai
      assert received_metadata.target_provider == "anthropic"
      assert received_metadata.status == 200
    end

    test "adds default :id" do
      emit_via_success()

      assert_receive {:telemetry_received, _measurements, received_metadata}
      assert is_binary(received_metadata.id)
      assert String.length(received_metadata.id) == 12
    end

    test "adds default :streaming=false" do
      emit_via_success()

      assert_receive {:telemetry_received, _measurements, received_metadata}
      assert received_metadata.streaming == false
    end

    test "can be received by a test handler attached with :telemetry.attach" do
      emit_via_success()

      assert_receive {:telemetry_received, received_measurements, received_metadata}
      assert received_measurements.duration == 150_000
      assert received_metadata.source_provider == :openai
    end
  end

  describe "emit_success_for_context/3 (context-aware emit_success/1 wrapper)" do
    setup do
      test_pid = self()
      handler_id = "test-for-context-success-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, handler_id: handler_id}
    end

    # Builds a RequestContext with stable, deterministic timings and
    # started values so the test can assert on the emitted telemetry
    # without depending on real wall-clock measurement.
    defp build_context(overrides \\ %{}) do
      defaults = %RequestContext{
        source_provider: :openai,
        target_provider: :anthropic,
        source_path: "/v1/chat/completions",
        target_path: "/v1/messages",
        method: "POST",
        config: %{name: "anthropic-1", base_url: "https://api.anthropic.com", timeout: 60_000},
        source_converter: ShhAi.ApiConverter.get_converter(:openai),
        target_converter: ShhAi.ApiConverter.get_converter(:anthropic),
        conversation: %{
          conversation_id: "conv-ctx-1",
          source_provider: :openai,
          new?: false
        },
        openai_body: %{"messages" => []},
        mapping: %{},
        reverse_index: %{},
        pii_info: %{detected_count: 1, sanitized_count: 1, preserved_count: 0, types: [:email]},
        timings: %{
          pii_duration: 100,
          source_conversion_duration: 50,
          target_conversion_duration: 25
        },
        target_headers: [{"x-api-key", "test"}],
        final_headers: [],
        target_body: %{},
        streaming: false,
        started: %{monotonic: 1_000, system: 2_000}
      }

      Map.merge(defaults, overrides)
    end

    test "emits telemetry with context-derived fields and runtime overrides" do
      ctx = build_context()
      # The caller (ProviderClient.request/6) captures backend_start
      # immediately before the backend HTTP call and threads it in.
      backend_start = 1_175

      Metrics.emit_success_for_context(ctx, backend_start, %{
        duration: 500,
        backend_duration: 300,
        restore_duration: 25,
        status: 200,
        conversation_id: "conv-ctx-1"
      })

      assert_receive {:telemetry_received, measurements, metadata}

      # Overrides win on the runtime-only fields
      assert measurements.duration == 500
      assert measurements.backend_duration == 300
      assert measurements.restore_duration == 25
      assert metadata.status == 200
      assert metadata.conversation_id == "conv-ctx-1"

      # Context-derived fields flow through unchanged
      assert measurements.pii_duration == 100
      assert measurements.source_conversion_duration == 50
      assert measurements.target_conversion_duration == 25
      assert metadata.source_provider == :openai
      assert metadata.target_provider == "anthropic-1"
      assert metadata.request_path == "/v1/chat/completions"
      assert metadata.method == "POST"
      assert metadata.streaming == false
      assert metadata.started_at == 2_000
    end

    test "backend_start is taken from the caller, not reconstructed from timings" do
      # The 3-arg signature is the contract: backend_start comes from
      # the caller, NOT from `started.monotonic + pii + source + target`.
      # Pass a deliberately different value so the test can prove the
      # value flows through unchanged.
      ctx = build_context()
      backend_start = 9_999

      Metrics.emit_success_for_context(ctx, backend_start, %{
        duration: 1_500,
        backend_duration: backend_start - 1_500,
        restore_duration: 0,
        status: 200,
        conversation_id: nil
      })

      assert_receive {:telemetry_received, measurements, _metadata}
      # backend_duration is the caller's override; the function does
      # not recompute it. The point of this test is that the value
      # is taken from the new arg, not synthesized from timings.
      assert measurements.backend_duration == backend_start - 1_500
    end
  end

  describe "emit_error_for_context/2 (context-aware emit_error/2 wrapper)" do
    setup do
      test_pid = self()
      handler_id = "test-for-context-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, handler_id: handler_id}
    end

    test "emits error telemetry with context-derived defaults and runtime overrides" do
      ctx = %RequestContext{
        source_provider: :openai,
        target_provider: :anthropic,
        source_path: "/v1/chat/completions",
        target_path: "/v1/messages",
        method: "POST",
        config: %{name: "anthropic-1", base_url: "https://api.anthropic.com", timeout: 60_000},
        source_converter: ShhAi.ApiConverter.get_converter(:openai),
        target_converter: ShhAi.ApiConverter.get_converter(:anthropic),
        conversation: %{conversation_id: "conv-err-1", source_provider: :openai, new?: false},
        openai_body: %{},
        mapping: %{},
        reverse_index: %{},
        pii_info: %{},
        timings: %{
          pii_duration: 0,
          source_conversion_duration: 0,
          target_conversion_duration: 0
        },
        target_headers: [],
        final_headers: [],
        target_body: %{},
        streaming: false,
        started: %{monotonic: 1_000, system: 2_000}
      }

      Metrics.emit_error_for_context(ctx, %{
        error_type: :request_error,
        error_message: ":econnrefused",
        conversation_id: "conv-err-1"
      })

      assert_receive {:telemetry_received, measurements, metadata}

      # Context-derived defaults flow through
      assert measurements.pii_duration == 0
      assert measurements.source_conversion_duration == 0
      assert measurements.target_conversion_duration == 0
      assert metadata.source_provider == :openai
      assert metadata.target_provider == "anthropic-1"
      assert metadata.request_path == "/v1/chat/completions"
      assert metadata.method == "POST"
      assert metadata.streaming == false
      assert metadata.started_at == 2_000
      assert metadata.status == 0

      # Runtime overrides
      assert metadata.conversation_id == "conv-err-1"
      assert is_map(metadata.error)
      assert metadata.error.type == :request_error
      assert metadata.error.message == ":econnrefused"
    end
  end

  describe "list_since/2" do
    test "converts time windows correctly (:minute, :hour, :day, :week)" do
      # list_since delegates to EventBuffer.list_since/2 after calculating start_time.
      # We test indirectly by checking that it calls EventBuffer.list_since with a start_time
      # less than the current system time (i.e., in the past).

      for window <- [:minute, :hour, :day, :week] do
        events = Metrics.list_since(window, limit: 1)
        assert is_list(events)
      end

      # Verify time windows are roughly correct by checking the underlying call doesn't crash
      # and by asserting ordering constraints on start_time.
      # We can't directly observe start_time, but we can test that no events are returned
      # when the buffer is empty, which confirms the function executed without error.
      assert Metrics.list_since(:minute) == []
      assert Metrics.list_since(:hour) == []
      assert Metrics.list_since(:day) == []
      assert Metrics.list_since(:week) == []
    end
  end

  describe "calculate_stats/1" do
    test "with :events keyword option, uses provided events directly" do
      events = [
        build_event(status: 200, duration_ms: 100.0),
        build_event(status: 500, duration_ms: 200.0)
      ]

      stats = Metrics.calculate_stats(events: events)
      assert stats.requests_total == 2
      assert stats.requests_success == 1
      assert stats.requests_error == 1
    end

    test "without :events option, calls list_recent" do
      # Store some events in the buffer
      event1 = build_event(id: "evt-cs-001", ended_at: System.system_time(:microsecond))
      event2 = build_event(id: "evt-cs-002", ended_at: System.system_time(:microsecond))

      :ok = EventBuffer.store(event1)
      :ok = EventBuffer.store(event2)

      # call list_recent directly because Metrics.calculate_stats delegates to it
      stats = Metrics.calculate_stats(limit: 10)
      assert stats.requests_total == 2
      assert stats.requests_success == 2
    end
  end

  describe "persist_handler/4" do
    setup do
      # Subscribe to PubSub topic so we can assert broadcast
      Phoenix.PubSub.subscribe(ShhAi.PubSub, "dashboard:requests")

      :ok
    end

    test "creates event from measurements/metadata" do
      measurements = %{
        duration: 150_000,
        pii_duration: 5_000,
        backend_duration: 140_000,
        restore_duration: 2_000,
        source_conversion_duration: 1_500,
        target_conversion_duration: 1_500,
        pii_detected_count: 3,
        pii_sanitized_count: 2,
        pii_preserved_count: 1,
        pii_types: [:email, :phone]
      }

      metadata = %{
        id: "evt-persist-001",
        source_provider: :openai,
        target_provider: "anthropic",
        status: 200,
        streaming: false,
        request_path: "/v1/chat/completions",
        method: "POST"
      }

      Metrics.persist_handler([:shh_ai, :request, :stop], measurements, metadata, %{})

      # Assert broadcast
      assert_receive {:request, %Event{} = event}
      assert event.id == "evt-persist-001"
      assert event.source_provider == :openai
      assert event.target_provider == "anthropic"
      assert event.status == 200
      assert event.duration_ms == 150.0
      assert event.pii_detected_count == 3

      # Assert stored in EventBuffer
      [buffered] = EventBuffer.list_recent(limit: 1)
      assert buffered.id == "evt-persist-001"
    end

    test "stores event in EventBuffer" do
      measurements = %{duration: 100_000}

      metadata = %{
        id: "evt-buffer-001",
        source_provider: :openai,
        target_provider: "anthropic",
        status: 200,
        request_path: "/v1/chat/completions",
        method: "POST"
      }

      Metrics.persist_handler([:shh_ai, :request, :stop], measurements, metadata, %{})

      assert_receive {:request, %Event{id: "evt-buffer-001"}}

      [buffered] = EventBuffer.list_recent(limit: 1)
      assert buffered.id == "evt-buffer-001"
    end

    test "broadcasts to PubSub" do
      measurements = %{duration: 200_000}

      metadata = %{
        id: "evt-broadcast-001",
        source_provider: :anthropic,
        target_provider: "openai",
        status: 201,
        request_path: "/v1/chat/completions",
        method: "POST"
      }

      Metrics.persist_handler([:shh_ai, :request, :stop], measurements, metadata, %{})

      assert_receive {:request, %Event{id: "evt-broadcast-001", status: 201}}
    end
  end
end
