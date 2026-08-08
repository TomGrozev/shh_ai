defmodule ShhAi.Metrics.Stats do
  @moduledoc """
  On-the-fly statistics calculation from metrics events.

  Provides individual statistical functions (latency percentiles, averages,
  error rates, provider breakdowns, hourly counts, etc.) that operate on
  a list of events without storing pre-computed aggregates.

  ## Usage

      events = ShhAi.Metrics.list_recent(limit: 1000)
      p99 = ShhAi.Metrics.Stats.latency_percentile(events, 99.0)
      avg = ShhAi.Metrics.Stats.avg_latency_ms(events)

  """

  alias ShhAi.Metrics.Event

  @doc """
  Percentile of `duration_ms` across the given events. `p` is a float in 0..100
  (e.g. 50.0 for p50, 99.0 for p99). Returns 0.0 if events is empty.
  """
  @spec latency_percentile([Event.t()], float()) :: float()
  def latency_percentile([], _p), do: 0.0

  def latency_percentile(events, p) when is_list(events) and is_float(p) do
    n = length(events)

    if n == 0 do
      0.0
    else
      sorted =
        events
        |> Enum.map(& &1.duration_ms)
        |> Enum.sort()

      index = ceil(p / 100 * n) - 1
      index = max(0, min(index, n - 1))
      Enum.at(sorted, index, 0.0)
    end
  end

  @doc """
  Average duration in ms across the given events. Returns 0.0 if events is empty.
  """
  @spec avg_latency_ms([Event.t()]) :: float()
  def avg_latency_ms([]), do: 0.0

  def avg_latency_ms(events) when is_list(events) do
    durations = Enum.map(events, & &1.duration_ms)
    Enum.sum(durations) / length(durations)
  end

  @doc """
  Average of `timings.pii_ms` across the given events (the PII pipeline latency).
  Returns 0.0 if events is empty.
  """
  @spec avg_pipeline_ms([Event.t()]) :: float()
  def avg_pipeline_ms([]), do: 0.0

  def avg_pipeline_ms(events) when is_list(events) do
    pii_ms_values = Enum.map(events, & &1.timings.pii_ms)
    Enum.sum(pii_ms_values) / length(pii_ms_values)
  end

  @doc """
  Percentile of `timings.pii_ms` across the given events (the PII pipeline latency).
  `p` is a float in 0..100 (e.g. 50.0 for p50). Returns 0.0 if events is empty.
  """
  @spec pipeline_percentile([Event.t()], float()) :: float()
  def pipeline_percentile([], _p), do: 0.0

  def pipeline_percentile(events, p) when is_list(events) and is_float(p) do
    n = length(events)

    if n == 0 do
      0.0
    else
      sorted =
        events
        |> Enum.map(& &1.timings.pii_ms)
        |> Enum.sort()

      index = ceil(p / 100 * n) - 1
      index = max(0, min(index, n - 1))
      Enum.at(sorted, index, 0.0)
    end
  end

  @doc """
  Error rate as a float in 0.0..1.0 — fraction of events where `error != nil`.
  Returns 0.0 if events is empty.
  """
  @spec error_rate([Event.t()]) :: float()
  def error_rate([]), do: 0.0

  def error_rate(events) when is_list(events) do
    total = length(events)
    errors = Enum.count(events, &(&1.error != nil))
    errors / total
  end

  @doc """
  Count of events where `error != nil`.
  """
  @spec error_count([Event.t()]) :: non_neg_integer()
  def error_count([]), do: 0

  def error_count(events) when is_list(events) do
    Enum.count(events, &(&1.error != nil))
  end

  @doc """
  Top source providers as a list of `{provider, count}` tuples, sorted by count desc.
  `n` defaults to 3.
  """
  @spec top_source_providers([Event.t()], non_neg_integer()) :: [{atom(), non_neg_integer()}]
  def top_source_providers(events, n \\ 3) when is_list(events) do
    events
    |> Enum.frequencies_by(& &1.source_provider)
    |> Enum.sort_by(fn {_k, v} -> v end, :desc)
    |> Enum.take(n)
  end

  @doc """
  Top target providers as a list of `{provider, count}` tuples, sorted by count desc.
  `n` defaults to 3.
  """
  @spec top_target_providers([Event.t()], non_neg_integer()) :: [{String.t(), non_neg_integer()}]
  def top_target_providers(events, n \\ 3) when is_list(events) do
    events
    |> Enum.frequencies_by(& &1.target_provider)
    |> Enum.sort_by(fn {_k, v} -> v end, :desc)
    |> Enum.take(n)
  end

  @doc """
  Buckets events into the last `hours` hours and returns a list of `{bucket_start_us, count}`
  tuples, oldest first. `now_us` is the reference time in microseconds; defaults to
  `System.system_time(:microsecond)`. The list always has `hours` entries, even for empty
  buckets.
  """
  @spec hourly_counts([Event.t()], non_neg_integer(), integer()) :: [
          {integer(), non_neg_integer()}
        ]
  def hourly_counts(events, hours \\ 24, now_us \\ System.system_time(:microsecond))
      when is_list(events) and is_integer(hours) and hours > 0 do
    bucket_size = 3_600_000_000

    earliest_bucket =
      (now_us - (hours - 1) * bucket_size) |> div(bucket_size) |> Kernel.*(bucket_size)

    buckets =
      for i <- 0..(hours - 1), into: %{} do
        {earliest_bucket + i * bucket_size, 0}
      end

    counted =
      Enum.reduce(events, buckets, fn event, acc ->
        bucket = div(event.ended_at, bucket_size) * bucket_size
        Map.update(acc, bucket, 1, &(&1 + 1))
      end)

    counted
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.to_list()
  end

  @doc """
  Returns events where `error != nil`, newest first, limited to `limit` (default 10).
  """
  @spec recent_errors([Event.t()], non_neg_integer()) :: [Event.t()]
  def recent_errors(events, limit \\ 10) when is_list(events) do
    events
    |> Enum.reject(&is_nil(&1.error))
    |> Enum.sort_by(& &1.ended_at, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Returns the application uptime in microseconds (since `:persistent_term` was set in
  ShhAi.Application.start/2). Returns 0 if not set (e.g. in tests that bypass Application).
  """
  @spec app_uptime_us() :: non_neg_integer()
  def app_uptime_us do
    started_at = :persistent_term.get({ShhAi, :started_at}, 0)
    System.system_time(:microsecond) - started_at
  end
end
