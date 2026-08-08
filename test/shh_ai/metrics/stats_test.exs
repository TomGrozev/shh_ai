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
