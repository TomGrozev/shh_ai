defmodule ShhAi.Metrics.EmitStreamStopTest do
  @moduledoc """
  Tests for the RequestContext-based signature of Metrics.emit_stream_stop/6.
  """
  use ExUnit.Case, async: false

  alias ShhAi.ApiConverter
  alias ShhAi.Metrics
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.StreamHandler.Accumulator

  setup do
    test_pid = self()
    handler_id = "emit-stream-stop-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:shh_ai, :request, :stop],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_received, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, test_pid: test_pid}
  end

  # Builds a RequestContext with deterministic values for assertions.
  # Accepts overrides as either a map (`%{...}`) or a keyword list
  # (`key: value, ...`) — the latter is convenient when only one or
  # two fields are being patched in a test.
  defp build_ctx(overrides \\ %{}) do
    # Capture real `started` values via the same helper production code
    # uses (`Metrics.capture_started/0`). Hardcoding tiny integers like
    # `%{monotonic: 1_000, system: 2_000}` would break duration math on
    # platforms where `System.monotonic_time(:microsecond)` is negative
    # (e.g. macOS), since `backend_end - ctx.started.monotonic` would
    # yield a large negative number. Real callers capture started
    # shortly before passing the context through, so capturing here at
    # build time is faithful to the production call pattern.
    started = ShhAi.Metrics.capture_started()

    defaults = %RequestContext{
      source_provider: :openai,
      target_provider: :anthropic,
      source_path: "/v1/chat/completions",
      target_path: "/v1/messages",
      method: :post,
      config: %{name: "anthropic-1", base_url: "https://api.anthropic.com", timeout: 60_000},
      source_converter: ApiConverter.get_converter(:openai),
      target_converter: ApiConverter.get_converter(:anthropic),
      conversation: %{conversation_id: "conv-1", source_provider: :openai, new?: false},
      openai_body: %{},
      mapping: %{},
      reverse_index: %{},
      pii_info: %{detected_count: 1, sanitized_count: 1, preserved_count: 0, types: [:email]},
      timings: %{
        pii_duration: 100,
        source_conversion_duration: 50,
        target_conversion_duration: 25
      },
      target_headers: [],
      final_headers: [],
      target_body: %{},
      streaming: true,
      started: started
    }

    overrides = if is_list(overrides), do: Map.new(overrides), else: overrides
    Map.merge(defaults, overrides)
  end

  test "emits telemetry with all fields derived from RequestContext" do
    ctx = build_ctx()
    acc = %Accumulator{restore_duration: 1_000, assistant_content_chunks: []}
    # `backend_start` must be a real monotonic time captured just before
    # the call so `backend_end - backend_start` stays small and non-negative
    # (monotonic time on macOS is large and negative; hardcoded tiny
    # integers would make the delta huge and negative).
    backend_start = System.monotonic_time(:microsecond)

    Metrics.emit_stream_stop(200, ctx, backend_start, acc, "conv-1", "hello world")

    assert_receive {:telemetry_received, measurements, metadata}
    # `duration` is the wall-clock delta between `build_ctx/1`'s call to
    # `Metrics.capture_started/0` and the start of `emit_stream_stop/6`.
    # On a fast machine that can be 0 microseconds, so we accept
    # `>= 0` rather than `> 0`. (The semantics — that the field is
    # computed from `ctx.started.monotonic` — are what matter; the
    # specific value isn't.)
    assert measurements.duration >= 0
    assert measurements.pii_duration == 100
    assert measurements.source_conversion_duration == 50
    assert measurements.target_conversion_duration == 25
    assert measurements.restore_duration == 1_000

    assert metadata.source_provider == :openai
    # from ctx.config.name
    assert metadata.target_provider == "anthropic-1"
    assert metadata.request_path == "/v1/chat/completions"
    assert metadata.method == :post
    assert metadata.streaming == true
    # `started_at` is propagated from `ctx.started.system` (captured by
    # `build_ctx/1`); we just verify it's the same integer the helper
    # captured, not a hardcoded marker — production callers pass through
    # whatever `capture_started/0` returned.
    assert metadata.started_at == ctx.started.system
    assert metadata.status == 200
    assert metadata.conversation_id == "conv-1"
    assert metadata.assistant_content == "hello world"
  end

  test "target_provider comes from ctx.config.name (instance name), not ctx.target_provider (type atom)" do
    # ctx.target_provider is the type atom (:anthropic)
    # ctx.config.name is the instance name (e.g., "anthropic-1")
    # The metrics path should emit the instance name.
    ctx = build_ctx(config: %{name: "gpt-4-custom", base_url: "x", timeout: 60_000})
    acc = Accumulator.new()
    backend_start = System.monotonic_time(:microsecond)

    Metrics.emit_stream_stop(200, ctx, backend_start, acc, "conv-2", "")

    assert_receive {:telemetry_received, _measurements, metadata}
    assert metadata.target_provider == "gpt-4-custom"
  end

  test "computes backend_duration as now - backend_start" do
    ctx = build_ctx()
    acc = Accumulator.new()
    backend_start = System.monotonic_time(:microsecond)

    before = System.monotonic_time(:microsecond)
    Metrics.emit_stream_stop(200, ctx, backend_start, acc, "conv-3", "")
    after_call = System.monotonic_time(:microsecond)

    assert_receive {:telemetry_received, measurements, _metadata}
    # backend_duration = (now_at_call) - backend_start
    # Sanity bounds: should be a small non-negative number
    assert measurements.backend_duration >= 0
    assert measurements.backend_duration <= after_call - before + 1_000
  end
end
