defmodule ShhAi.Metrics.StreamStopTest do
  use ExUnit.Case, async: false

  alias ShhAi.Metrics
  alias ShhAi.ProviderClient.StreamContext
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.RequestMeta

  # Build a minimal StreamContext with all 17 enforced keys.
  # Only the fields accessed by emit_stream_stop need real values;
  # the rest are set to nil or sensible defaults.
  defp build_stream_context(overrides \\ []) do
    defaults = %StreamContext{
      conn: nil,
      stream_fun: nil,
      source_provider: :openai,
      source_path: "/v1/chat/completions",
      method: "POST",
      conversation: nil,
      start_time: System.monotonic_time(:microsecond),
      started_at: System.system_time(:microsecond),
      backend_start: System.monotonic_time(:microsecond),
      metrics_opts: %{
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      },
      pii_info: %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []},
      pre_stream_timings: %{
        pii_duration: 100,
        source_conversion_duration: 50,
        target_conversion_duration: 50
      },
      openai_body: %{},
      source_converter: nil,
      target_converter: nil,
      mapping: %{},
      reverse_index: %{}
    }

    Enum.reduce(overrides, defaults, fn {key, value}, ctx ->
      Map.put(ctx, key, value)
    end)
  end

  defp build_request_meta(overrides \\ []) do
    defaults = [
      start_time: System.monotonic_time(:microsecond) - 10_000,
      metrics_opts: %{
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      },
      conversation_id: "conv-default"
    ]

    RequestMeta.new(Keyword.merge(defaults, overrides))
  end

  describe "emit_stream_stop/4" do
    setup do
      test_pid = self()

      handler_id = "stream-stop-#{System.unique_integer([:positive])}"

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

      :ok
    end

    test "emits telemetry with empty accumulator and request meta" do
      acc = Accumulator.new()
      meta = build_request_meta(conversation_id: "conv-empty")
      ctx = build_stream_context()

      Metrics.emit_stream_stop(200, acc, meta, ctx)

      assert_receive {:telemetry_received, measurements, metadata}
      assert measurements.restore_duration == 0
      assert measurements.pii_detected_count == 0
      assert measurements.pii_sanitized_count == 0
      assert metadata.source_provider == :openai
      assert metadata.target_provider == "anthropic"
      assert metadata.request_path == "/v1/chat/completions"
      assert metadata.method == "POST"
      assert metadata.streaming == true
      assert metadata.status == 200
      assert metadata.conversation_id == "conv-empty"
      assert is_binary(metadata.id)
    end

    test "propagates accumulated restore_duration" do
      acc = %Accumulator{restore_duration: 1_000_000, assistant_content_chunks: []}
      meta = build_request_meta()
      ctx = build_stream_context()

      Metrics.emit_stream_stop(200, acc, meta, ctx)

      assert_receive {:telemetry_received, measurements, _metadata}
      assert measurements.restore_duration == 1_000_000
    end

    test "propagates accumulated assistant_content_chunks as joined assistant_content" do
      # Chunks are stored newest-first (prepend), so reverse gives chronological order
      acc = %Accumulator{restore_duration: 0, assistant_content_chunks: [" world", "hello"]}
      meta = build_request_meta()
      ctx = build_stream_context()

      Metrics.emit_stream_stop(200, acc, meta, ctx)

      assert_receive {:telemetry_received, _measurements, metadata}
      assert metadata.assistant_content == "hello world"
    end

    test "propagates request meta fields (source_provider, target_provider, request_path, method, streaming, conversation_id)" do
      acc = Accumulator.new()

      meta =
        build_request_meta(
          start_time: System.monotonic_time(:microsecond) - 50_000,
          metrics_opts: %{
            source_provider: :anthropic,
            target_provider: "ollama-local",
            request_path: "/api/chat",
            method: "PUT",
            streaming: true
          },
          conversation_id: "conv-meta-123"
        )

      ctx = build_stream_context()

      Metrics.emit_stream_stop(201, acc, meta, ctx)

      assert_receive {:telemetry_received, _measurements, metadata}
      assert metadata.source_provider == :anthropic
      assert metadata.target_provider == "ollama-local"
      assert metadata.request_path == "/api/chat"
      assert metadata.method == "PUT"
      assert metadata.streaming == true
      assert metadata.conversation_id == "conv-meta-123"
      assert metadata.status == 201
    end
  end
end
