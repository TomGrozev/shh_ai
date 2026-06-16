defmodule ShhAi.Metrics.StatsTest do
  use ExUnit.Case, async: true

  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.Stats

  defp build_event(overrides \\ []) do
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

  describe "calculate/1" do
    test "with empty list returns empty_stats" do
      assert Stats.calculate([]) == %{
               requests_total: 0,
               requests_success: 0,
               requests_error: 0,
               client_errors: 0,
               server_errors: 0,
               avg_latency_ms: 0.0,
               p95_latency_ms: 0.0,
               p99_latency_ms: 0.0,
               min_latency_ms: 0.0,
               max_latency_ms: 0.0,
               pii_total_detected: 0,
               pii_total_sanitized: 0,
               pii_total_preserved: 0,
               pii_by_type: %{},
               provider_usage: %{},
               streaming_count: 0,
               error_rate: 0.0
             }
    end

    test "with single successful event" do
      event = build_event()
      stats = Stats.calculate([event])

      assert stats.requests_total == 1
      assert stats.requests_success == 1
      assert stats.requests_error == 0
      assert stats.client_errors == 0
      assert stats.server_errors == 0
      assert stats.avg_latency_ms == 150.0
      assert stats.p95_latency_ms == 150.0
      assert stats.p99_latency_ms == 150.0
      assert stats.min_latency_ms == 150.0
      assert stats.max_latency_ms == 150.0
      assert stats.pii_total_detected == 3
      assert stats.pii_total_sanitized == 2
      assert stats.pii_total_preserved == 1
      assert stats.pii_by_type == %{email: 1, phone: 1}

      assert stats.provider_usage == %{
               source: %{openai: 1},
               target: %{"anthropic" => 1}
             }

      assert stats.streaming_count == 0
      assert stats.error_rate == 0.0
    end

    test "with multiple events of varying statuses" do
      events = [
        build_event(
          status: 200,
          duration_ms: 100.0,
          pii_detected_count: 1,
          pii_sanitized_count: 1,
          pii_preserved_count: 0,
          pii_types: [:email]
        ),
        build_event(
          status: 404,
          duration_ms: 200.0,
          pii_detected_count: 2,
          pii_sanitized_count: 1,
          pii_preserved_count: 1,
          pii_types: [:phone]
        ),
        build_event(
          status: 500,
          duration_ms: 300.0,
          pii_detected_count: 0,
          pii_sanitized_count: 0,
          pii_preserved_count: 0,
          pii_types: [],
          error: "boom"
        )
      ]

      stats = Stats.calculate(events)

      assert stats.requests_total == 3
      assert stats.requests_success == 1
      assert stats.requests_error == 2
      assert stats.client_errors == 1
      assert stats.server_errors == 1
      assert stats.avg_latency_ms == 200.0
      assert stats.p95_latency_ms == 300.0
      assert stats.p99_latency_ms == 300.0
      assert stats.min_latency_ms == 100.0
      assert stats.max_latency_ms == 300.0
      assert stats.pii_total_detected == 3
      assert stats.pii_total_sanitized == 2
      assert stats.pii_total_preserved == 1
      assert stats.pii_by_type == %{email: 1, phone: 1}
      assert stats.streaming_count == 0
      assert stats.error_rate == 2 / 3
    end

    test "requests_success counts 2xx statuses" do
      events = [
        build_event(status: 200),
        build_event(status: 201),
        build_event(status: 299),
        build_event(status: 300),
        build_event(status: 404),
        build_event(status: nil)
      ]

      stats = Stats.calculate(events)
      assert stats.requests_success == 3
    end

    test "requests_error counts 4xx and 5xx statuses and events with error field" do
      events = [
        build_event(status: 200),
        build_event(status: 400),
        build_event(status: 500),
        build_event(status: 200, error: "timeout"),
        build_event(status: nil, error: "crash")
      ]

      stats = Stats.calculate(events)
      assert stats.requests_error == 4
    end

    test "client_errors counts only 4xx" do
      events = [
        build_event(status: 200),
        build_event(status: 400),
        build_event(status: 404),
        build_event(status: 500),
        build_event(status: nil)
      ]

      stats = Stats.calculate(events)
      assert stats.client_errors == 2
    end

    test "server_errors counts only 5xx" do
      events = [
        build_event(status: 200),
        build_event(status: 500),
        build_event(status: 502),
        build_event(status: 400),
        build_event(status: nil)
      ]

      stats = Stats.calculate(events)
      assert stats.server_errors == 2
    end

    test "avg_latency_ms is correct average" do
      events = [
        build_event(duration_ms: 100.0),
        build_event(duration_ms: 200.0),
        build_event(duration_ms: 300.0)
      ]

      stats = Stats.calculate(events)
      assert stats.avg_latency_ms == 200.0
    end

    test "p95_latency_ms and p99_latency_ms are correct percentiles" do
      events = for i <- 1..100, do: build_event(duration_ms: i * 1.0)

      stats = Stats.calculate(events)
      # 95th percentile of 1..100 -> ceil(100*95/100) - 1 = 94 -> index 94 (0-based) => 95.0
      assert stats.p95_latency_ms == 95.0
      # 99th percentile -> ceil(100*99/100) - 1 = 98 -> index 98 => 99.0
      assert stats.p99_latency_ms == 99.0
    end

    test "min_latency_ms and max_latency_ms" do
      events = [
        build_event(duration_ms: 50.0),
        build_event(duration_ms: 150.0),
        build_event(duration_ms: 100.0)
      ]

      stats = Stats.calculate(events)
      assert stats.min_latency_ms == 50.0
      assert stats.max_latency_ms == 150.0
    end

    test "pii_total_detected sums all pii_detected_count" do
      events = [
        build_event(pii_detected_count: 1),
        build_event(pii_detected_count: 2),
        build_event(pii_detected_count: 3)
      ]

      stats = Stats.calculate(events)
      assert stats.pii_total_detected == 6
    end

    test "pii_total_sanitized sums all pii_sanitized_count" do
      events = [
        build_event(pii_sanitized_count: 1),
        build_event(pii_sanitized_count: 0),
        build_event(pii_sanitized_count: 4)
      ]

      stats = Stats.calculate(events)
      assert stats.pii_total_sanitized == 5
    end

    test "pii_total_preserved sums all pii_preserved_count" do
      events = [
        build_event(pii_preserved_count: 1),
        build_event(pii_preserved_count: 2),
        build_event(pii_preserved_count: 0)
      ]

      stats = Stats.calculate(events)
      assert stats.pii_total_preserved == 3
    end

    test "pii_by_type groups and counts PII types" do
      events = [
        build_event(pii_types: [:email, :phone]),
        build_event(pii_types: [:email, :ssn]),
        build_event(pii_types: [:email, :phone, :ssn])
      ]

      stats = Stats.calculate(events)
      assert stats.pii_by_type == %{email: 3, phone: 2, ssn: 2}
    end

    test "provider_usage groups by source and target provider" do
      events = [
        build_event(source_provider: :openai, target_provider: "anthropic"),
        build_event(source_provider: :openai, target_provider: "openai"),
        build_event(source_provider: :anthropic, target_provider: "anthropic")
      ]

      stats = Stats.calculate(events)

      assert stats.provider_usage == %{
               source: %{openai: 2, anthropic: 1},
               target: %{"anthropic" => 2, "openai" => 1}
             }
    end

    test "streaming_count counts streaming events" do
      events = [
        build_event(streaming: true),
        build_event(streaming: false),
        build_event(streaming: true)
      ]

      stats = Stats.calculate(events)
      assert stats.streaming_count == 2
    end

    test "error_rate is correct (errors / total)" do
      events = [
        build_event(status: 200),
        build_event(status: 400),
        build_event(status: 500)
      ]

      stats = Stats.calculate(events)
      assert stats.error_rate == 2 / 3
    end

    test "mix of success and error events" do
      events = [
        build_event(status: 200, duration_ms: 100.0),
        build_event(status: 201, duration_ms: 200.0),
        build_event(status: 400, duration_ms: 50.0),
        build_event(status: 500, duration_ms: 300.0),
        build_event(status: 200, error: "timeout", duration_ms: 150.0)
      ]

      stats = Stats.calculate(events)
      assert stats.requests_total == 5
      assert stats.requests_success == 3
      assert stats.requests_error == 3
      assert stats.client_errors == 1
      assert stats.server_errors == 1
      assert stats.error_rate == 3 / 5
    end

    test "events with nil status are handled correctly" do
      events = [
        build_event(status: nil),
        build_event(status: nil, error: "crash"),
        build_event(status: 200)
      ]

      stats = Stats.calculate(events)
      assert stats.requests_success == 1
      assert stats.client_errors == 0
      assert stats.server_errors == 0
      assert stats.requests_error == 1
      assert stats.error_rate == 1 / 3
    end
  end
end
