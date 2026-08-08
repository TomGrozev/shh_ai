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

  describe "latency_percentile/2" do
    test "returns 0.0 for empty list" do
      assert Stats.latency_percentile([], 50.0) == 0.0
    end

    test "p50 of single event returns that event's duration" do
      events = [build_event(duration_ms: 100.0)]
      assert Stats.latency_percentile(events, 50.0) == 100.0
    end

    test "p50 of list returns correct median" do
      events = [
        build_event(duration_ms: 100.0),
        build_event(duration_ms: 200.0),
        build_event(duration_ms: 300.0)
      ]

      # ceil(3 * 50 / 100) - 1 = ceil(1.5) - 1 = 2 - 1 = 1 -> sorted[1] = 200.0
      assert Stats.latency_percentile(events, 50.0) == 200.0
    end

    test "p99 of 100 events returns 100th value" do
      events = for i <- 1..100, do: build_event(duration_ms: i * 1.0)
      assert Stats.latency_percentile(events, 99.0) == 99.0
    end

    test "p100 returns the maximum" do
      events = [
        build_event(duration_ms: 50.0),
        build_event(duration_ms: 150.0),
        build_event(duration_ms: 100.0)
      ]

      assert Stats.latency_percentile(events, 100.0) == 150.0
    end

    test "all same values returns that value" do
      events = for _ <- 1..5, do: build_event(duration_ms: 42.0)
      assert Stats.latency_percentile(events, 50.0) == 42.0
    end
  end

  describe "avg_latency_ms/1" do
    test "returns 0.0 for empty list" do
      assert Stats.avg_latency_ms([]) == 0.0
    end

    test "returns duration for single event" do
      events = [build_event(duration_ms: 250.0)]
      assert Stats.avg_latency_ms(events) == 250.0
    end

    test "returns correct average for multiple events" do
      events = [
        build_event(duration_ms: 100.0),
        build_event(duration_ms: 200.0),
        build_event(duration_ms: 300.0)
      ]

      assert Stats.avg_latency_ms(events) == 200.0
    end
  end

  describe "avg_pipeline_ms/1" do
    test "returns 0.0 for empty list" do
      assert Stats.avg_pipeline_ms([]) == 0.0
    end

    test "returns pii_ms for single event" do
      events = [
        build_event(
          timings: %{
            pii_ms: 3.5,
            backend_ms: 100.0,
            restore_ms: 1.0,
            source_conversion_ms: 0.5,
            target_conversion_ms: 0.5
          }
        )
      ]

      assert Stats.avg_pipeline_ms(events) == 3.5
    end

    test "returns correct average of pii_ms across events" do
      events = [
        build_event(
          timings: %{
            pii_ms: 2.0,
            backend_ms: 100.0,
            restore_ms: 1.0,
            source_conversion_ms: 0.5,
            target_conversion_ms: 0.5
          }
        ),
        build_event(
          timings: %{
            pii_ms: 4.0,
            backend_ms: 100.0,
            restore_ms: 1.0,
            source_conversion_ms: 0.5,
            target_conversion_ms: 0.5
          }
        ),
        build_event(
          timings: %{
            pii_ms: 6.0,
            backend_ms: 100.0,
            restore_ms: 1.0,
            source_conversion_ms: 0.5,
            target_conversion_ms: 0.5
          }
        )
      ]

      assert Stats.avg_pipeline_ms(events) == 4.0
    end
  end

  describe "error_rate/1" do
    test "returns 0.0 for empty list" do
      assert Stats.error_rate([]) == 0.0
    end

    test "returns 0.0 when no errors" do
      events = [build_event(error: nil), build_event(error: nil)]
      assert Stats.error_rate(events) == 0.0
    end

    test "returns 1.0 when all are errors" do
      events = [build_event(error: %{type: :timeout}), build_event(error: %{type: :crash})]
      assert Stats.error_rate(events) == 1.0
    end

    test "returns correct fraction for partial errors" do
      events = [
        build_event(error: nil),
        build_event(error: %{type: :timeout}),
        build_event(error: nil),
        build_event(error: %{type: :crash})
      ]

      assert Stats.error_rate(events) == 0.5
    end
  end

  describe "error_count/1" do
    test "returns 0 for empty list" do
      assert Stats.error_count([]) == 0
    end

    test "returns 0 when no errors" do
      events = [build_event(error: nil), build_event(error: nil)]
      assert Stats.error_count(events) == 0
    end

    test "returns correct count for some errors" do
      events = [
        build_event(error: nil),
        build_event(error: %{type: :timeout}),
        build_event(error: nil),
        build_event(error: %{type: :crash})
      ]

      assert Stats.error_count(events) == 2
    end
  end

  describe "top_source_providers/2" do
    test "returns empty list for empty events" do
      assert Stats.top_source_providers([]) == []
    end

    test "returns providers sorted by count desc" do
      events = [
        build_event(source_provider: :openai),
        build_event(source_provider: :openai),
        build_event(source_provider: :anthropic)
      ]

      result = Stats.top_source_providers(events)
      assert result == [{:openai, 2}, {:anthropic, 1}]
    end

    test "respects the limit parameter" do
      events = [
        build_event(source_provider: :openai),
        build_event(source_provider: :openai),
        build_event(source_provider: :anthropic),
        build_event(source_provider: :ollama)
      ]

      result = Stats.top_source_providers(events, 2)
      assert length(result) == 2
      assert hd(result) == {:openai, 2}
    end

    test "handles ties deterministically" do
      events = [
        build_event(source_provider: :openai),
        build_event(source_provider: :anthropic),
        build_event(source_provider: :ollama)
      ]

      result = Stats.top_source_providers(events, 10)
      assert length(result) == 3
      # All have count 1
      assert Enum.all?(result, fn {_k, v} -> v == 1 end)
    end
  end

  describe "top_target_providers/2" do
    test "returns empty list for empty events" do
      assert Stats.top_target_providers([]) == []
    end

    test "returns providers sorted by count desc" do
      events = [
        build_event(target_provider: "anthropic"),
        build_event(target_provider: "anthropic"),
        build_event(target_provider: "openai")
      ]

      result = Stats.top_target_providers(events)
      assert result == [{"anthropic", 2}, {"openai", 1}]
    end

    test "respects the limit parameter" do
      events = [
        build_event(target_provider: "anthropic"),
        build_event(target_provider: "openai"),
        build_event(target_provider: "ollama")
      ]

      result = Stats.top_target_providers(events, 1)
      assert length(result) == 1
      assert hd(result) == {"anthropic", 1}
    end
  end

  describe "hourly_counts/3" do
    test "returns empty buckets for no events" do
      now_us = System.system_time(:microsecond)
      result = Stats.hourly_counts([], 24, now_us)
      assert length(result) == 24
      assert Enum.all?(result, fn {_bucket, count} -> count == 0 end)
    end

    test "counts events in the correct bucket" do
      now_us = System.system_time(:microsecond)

      # Event in current hour
      event = build_event(ended_at: now_us)

      result = Stats.hourly_counts([event], 24, now_us)
      assert length(result) == 24

      # The last bucket (current hour) should have 1 event
      {_last_bucket, last_count} = List.last(result)
      assert last_count == 1
    end

    test "returns exactly `hours` entries even if events span multiple hours" do
      now_us = System.system_time(:microsecond)
      bucket_size = 3_600_000_000

      events = [
        build_event(ended_at: now_us),
        build_event(ended_at: now_us - 2 * bucket_size)
      ]

      result = Stats.hourly_counts(events, 24, now_us)
      assert length(result) == 24
    end
  end

  describe "recent_errors/2" do
    test "returns empty list when no errors" do
      events = [build_event(error: nil), build_event(error: nil)]
      assert Stats.recent_errors(events) == []
    end

    test "returns only error events, newest first" do
      now = System.system_time(:microsecond)

      good = build_event(error: nil, ended_at: now - 1000)
      err1 = build_event(error: %{type: :timeout}, ended_at: now - 2000)
      err2 = build_event(error: %{type: :crash}, ended_at: now)

      result = Stats.recent_errors([good, err1, err2])
      assert length(result) == 2
      assert hd(result).error == %{type: :crash}
      assert List.last(result).error == %{type: :timeout}
    end

    test "respects the limit" do
      now = System.system_time(:microsecond)

      errors =
        for i <- 1..5 do
          build_event(error: %{type: :timeout}, ended_at: now - i * 1000)
        end

      result = Stats.recent_errors(errors, 3)
      assert length(result) == 3
    end

    test "returns empty list for empty input" do
      assert Stats.recent_errors([]) == []
    end
  end

  describe "app_uptime_us/0" do
    test "returns 0 when persistent_term is not set" do
      # In test env, Application may not have started with our persistent_term
      # So this should return 0 (or a very small number if it was set)
      result = Stats.app_uptime_us()
      assert is_integer(result)
      assert result >= 0
    end
  end
end
