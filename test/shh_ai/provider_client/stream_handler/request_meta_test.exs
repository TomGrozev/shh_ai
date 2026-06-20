defmodule ShhAi.ProviderClient.StreamHandler.RequestMetaTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient.StreamHandler.RequestMeta

  describe "struct fields" do
    test "holds the six per-finalization fields" do
      metrics_opts = %{
        source_provider: :openai,
        target_provider: "gpt-4",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      }

      pii_info = %{detected_count: 1, sanitized_count: 1, preserved_count: 0, types: [:email]}
      pre_stream_timings = %{pii_duration: 10, source_conversion_duration: 5, target_conversion_duration: 5}

      meta = %RequestMeta{
        start_time: 1_700_000_000_000,
        started_at: 1_700_000_000_001,
        backend_start: 1_700_000_000_002,
        metrics_opts: metrics_opts,
        pii_info: pii_info,
        pre_stream_timings: pre_stream_timings
      }

      assert meta.start_time == 1_700_000_000_000
      assert meta.started_at == 1_700_000_000_001
      assert meta.backend_start == 1_700_000_000_002
      assert meta.metrics_opts == metrics_opts
      assert meta.pii_info == pii_info
      assert meta.pre_stream_timings == pre_stream_timings
    end

    test "does NOT have a conversation_id field" do
      meta = %RequestMeta{
        start_time: 1,
        started_at: 2,
        backend_start: 3,
        metrics_opts: %{},
        pii_info: %{},
        pre_stream_timings: %{}
      }

      # conversation_id lives separately (passed as 4th arg to Metrics.emit_stream_stop)
      refute Map.has_key?(meta, :conversation_id)
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("""
        %ShhAi.ProviderClient.StreamHandler.RequestMeta{start_time: 0}
        """)
      end
    end
  end

  describe "new/1" do
    test "builds struct from keyword list" do
      metrics_opts = %{
        source_provider: :openai,
        target_provider: "gpt-4",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      }

      pii_info = %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}
      pre_stream_timings = %{pii_duration: 10, source_conversion_duration: 5, target_conversion_duration: 5}

      meta =
        RequestMeta.new(
          start_time: 1_700_000_000_000,
          started_at: 1_700_000_000_001,
          backend_start: 1_700_000_000_002,
          metrics_opts: metrics_opts,
          pii_info: pii_info,
          pre_stream_timings: pre_stream_timings
        )

      assert %RequestMeta{} = meta
      assert meta.start_time == 1_700_000_000_000
      assert meta.started_at == 1_700_000_000_001
      assert meta.backend_start == 1_700_000_000_002
      assert meta.metrics_opts == metrics_opts
      assert meta.pii_info == pii_info
      assert meta.pre_stream_timings == pre_stream_timings
    end

    test "raises when required key is missing" do
      assert_raise KeyError, fn ->
        # pii_info is missing
        RequestMeta.new(
          start_time: 0,
          started_at: 1,
          backend_start: 2,
          metrics_opts: %{},
          pre_stream_timings: %{}
        )
      end
    end
  end
end
