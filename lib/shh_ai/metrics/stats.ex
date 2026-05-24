defmodule ShhAi.Metrics.Stats do
  @moduledoc """
  On-the-fly statistics calculation from metrics events.

  This module calculates aggregated statistics from a list of events
  without storing pre-computed aggregates. Stats are calculated when
  requested (e.g., when the dashboard loads).

  ## Usage

      events = ShhAi.Metrics.list_recent(limit: 1000)
      stats = ShhAi.Metrics.Stats.calculate(events)

  ## Returns

      %{
        requests_total: 1000,
        requests_success: 985,
        requests_error: 15,
        avg_latency_ms: 145.2,
        p95_latency_ms: 289.5,
        p99_latency_ms: 450.1,
        min_latency_ms: 12.3,
        max_latency_ms: 890.2,
        pii_total_detected: 127,
        pii_total_sanitized: 115,
        pii_total_preserved: 12,
        pii_by_type: %{email: 45, phone: 32, ssn: 5, ...},
        provider_usage: %{openai: 400, anthropic: 350, ollama: 250},
        streaming_count: 150,
        error_rate: 0.015
      }

  """

  alias ShhAi.Metrics.Event

  @type stats :: %{
          requests_total: non_neg_integer(),
          requests_success: non_neg_integer(),
          requests_error: non_neg_integer(),
          client_errors: non_neg_integer(),
          server_errors: non_neg_integer(),
          avg_latency_ms: float(),
          p95_latency_ms: float(),
          p99_latency_ms: float(),
          min_latency_ms: float(),
          max_latency_ms: float(),
          pii_total_detected: non_neg_integer(),
          pii_total_sanitized: non_neg_integer(),
          pii_total_preserved: non_neg_integer(),
          pii_by_type: %{atom() => non_neg_integer()},
          provider_usage: %{atom() => non_neg_integer()},
          streaming_count: non_neg_integer(),
          error_rate: float()
        }

  @doc """
  Calculates statistics from a list of events.

  ## Parameters

    * `events` - List of Event structs to calculate stats from

  ## Examples

      iex> events = [%ShhAi.Metrics.Event{...}, ...]
      iex> ShhAi.Metrics.Stats.calculate(events)
      %{requests_total: 100, avg_latency_ms: 145.2, ...}

  """
  @spec calculate([Event.t()]) :: stats()
  def calculate(events) when is_list(events) do
    total = length(events)

    if total == 0 do
      empty_stats()
    else
      %{
        requests_total: total,
        requests_success: count_success(events),
        requests_error: count_errors(events),
        client_errors: count_client_errors(events),
        server_errors: count_server_errors(events),
        avg_latency_ms: avg_latency(events),
        p95_latency_ms: percentile_latency(events, 95),
        p99_latency_ms: percentile_latency(events, 99),
        min_latency_ms: min_latency(events),
        max_latency_ms: max_latency(events),
        pii_total_detected: sum_pii_detected(events),
        pii_total_sanitized: sum_pii_sanitized(events),
        pii_total_preserved: sum_pii_preserved(events),
        pii_by_type: group_pii_by_type(events),
        provider_usage: group_by_provider(events),
        streaming_count: count_streaming(events),
        error_rate: error_rate(events)
      }
    end
  end

  @doc """
  Calculates statistics for a specific time window.

  ## Options

    * `:since` - Time window in microseconds (default: 1 hour = 3_600_000_000)
    * `:limit` - Maximum events to consider (default: 10_000)

  ## Examples

      iex> ShhAi.Metrics.Stats.calculate_for_window(since: :day)
      %{requests_total: 5000, ...}

      iex> ShhAi.Metrics.Stats.calculate_for_window(since: 3_600_000_000)
      %{requests_total: 500, ...}

  """
  @spec calculate_for_window(keyword()) :: stats()
  def calculate_for_window(opts \\ []) do
    since = Keyword.get(opts, :since, :hour)
    limit = Keyword.get(opts, :limit, 10_000)

    since_microseconds =
      case since do
        :minute -> 60_000_000
        :hour -> 3_600_000_000
        :day -> 86_400_000_000
        :week -> 604_800_000_000
        value when is_integer(value) -> value
      end

    cutoff = System.system_time(:microsecond) - since_microseconds

    events =
      ShhAi.Metrics.EventBuffer.list_recent(limit: limit)
      |> Enum.filter(&(&1.ended_at >= cutoff))

    calculate(events)
  end

  # Private helpers

  defp empty_stats do
    %{
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

  defp count_success(events) do
    Enum.count(events, fn e ->
      is_integer(e.status) and e.status >= 200 and e.status < 300
    end)
  end

  defp count_errors(events) do
    Enum.count(events, fn e ->
      (is_integer(e.status) and (e.status < 200 or e.status >= 400)) or
        not is_nil(e.error)
    end)
  end

  defp count_client_errors(events) do
    Enum.count(events, fn e ->
      is_integer(e.status) and e.status >= 400 and e.status < 500
    end)
  end

  defp count_server_errors(events) do
    Enum.count(events, fn e ->
      is_integer(e.status) and e.status >= 500
    end)
  end

  defp avg_latency(events) do
    durations = Enum.map(events, & &1.duration_ms)
    Enum.sum(durations) / length(durations)
  end

  defp percentile_latency(events, percentile) do
    durations =
      events
      |> Enum.map(& &1.duration_ms)
      |> Enum.sort()

    index = ceil(length(durations) * percentile / 100) - 1
    index = max(0, min(index, length(durations) - 1))
    Enum.at(durations, index) || 0.0
  end

  defp min_latency(events) do
    events
    |> Enum.map(& &1.duration_ms)
    |> Enum.min()
  end

  defp max_latency(events) do
    events
    |> Enum.map(& &1.duration_ms)
    |> Enum.max()
  end

  defp sum_pii_detected(events) do
    Enum.map(events, & &1.pii_detected_count)
    |> Enum.sum()
  end

  defp sum_pii_sanitized(events) do
    Enum.map(events, & &1.pii_sanitized_count)
    |> Enum.sum()
  end

  defp sum_pii_preserved(events) do
    Enum.map(events, & &1.pii_preserved_count)
    |> Enum.sum()
  end

  defp group_pii_by_type(events) do
    events
    |> Enum.flat_map(& &1.pii_types)
    |> Enum.frequencies()
  end

  defp group_by_provider(events) do
    Enum.reduce(events, %{source: %{}, target: %{}}, fn event, acc ->
      acc
      |> update_in([:source, event.source_provider], fn
        nil -> 1
        count -> count + 1
      end)
      |> update_in([:target, event.target_provider], fn
        nil -> 1
        count -> count + 1
      end)
    end)
  end

  defp count_streaming(events) do
    Enum.count(events, & &1.streaming)
  end

  defp error_rate(events) do
    total = length(events)
    errors = count_errors(events)
    errors / total
  end
end
