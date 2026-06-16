defmodule ShhAi.BackendClient.MetricsEmitter do
  @moduledoc false

  require Logger

  alias ShhAi.Metrics

  @doc """
  Captures the current monotonic and system time atomically (as close as
  Elixir allows) for use as a request start timestamp.

  Call once at the top of `request/6` or `stream/8`, then use
  `started.monotonic` for elapsed-time calculations and `started.system`
  for `started_at` metadata — eliminates the racy two-call approach.
  """
  @spec now() :: %{monotonic: integer(), system: integer()}
  def now do
    %{monotonic: System.monotonic_time(:microsecond), system: System.system_time(:microsecond)}
  end

  @doc """
  Emits a request-stop telemetry event and logs the completion line.
  """
  @spec emit_stop(map(), map()) :: :ok
  def emit_stop(measurements, metadata) do
    Metrics.emit_stop!(measurements, metadata)

    log_request_complete(
      metadata.target_provider,
      metadata.request_path,
      metadata.method,
      metadata.status,
      measurements
    )
  end

  @doc """
  Builds a measurements map from the given timing and PII keyword options.

  Eliminates 4× duplication of the PII fields block across success/error
  paths for both streaming and non-streaming requests.
  """
  @spec build_measurements(keyword()) :: map()
  def build_measurements(opts) do
    pii = Keyword.get(opts, :pii_info, %{})

    %{
      duration: Keyword.get(opts, :duration, 0),
      pii_duration: Keyword.get(opts, :pii_duration, 0),
      source_conversion_duration: Keyword.get(opts, :source_conversion_duration, 0),
      target_conversion_duration: Keyword.get(opts, :target_conversion_duration, 0),
      backend_duration: Keyword.get(opts, :backend_duration, 0),
      restore_duration: Keyword.get(opts, :restore_duration, 0),
      pii_detected_count: Map.get(pii, :detected_count, 0),
      pii_sanitized_count: Map.get(pii, :sanitized_count, 0),
      pii_preserved_count: Map.get(pii, :preserved_count, 0),
      pii_types: Map.get(pii, :types, [])
    }
  end

  @doc """
  Builds a metadata map from the given keyword options.

  `started_at` should be the wall-clock system time at which the request
  started (captured via `now/0`), in microseconds.
  """
  @spec build_metadata(keyword()) :: map()
  def build_metadata(opts) do
    base = %{
      source_provider: Keyword.fetch!(opts, :source_provider),
      target_provider: Keyword.fetch!(opts, :target_provider),
      request_path: Keyword.fetch!(opts, :request_path),
      method: Keyword.fetch!(opts, :method),
      streaming: Keyword.get(opts, :streaming, false),
      started_at: Keyword.fetch!(opts, :started_at),
      status: Keyword.get(opts, :status, 0)
    }

    base
    |> maybe_put(:conversation_id, Keyword.get(opts, :conversation_id))
    |> maybe_put(:error, Keyword.get(opts, :error))
  end

  @doc """
  Emits telemetry and logs the completion line for a streaming request.

  Accepts the raw `metrics_context` map accumulated per-chunk and the
  `StreamContext` struct so it can pull timings and PII info.
  """
  @spec emit_stream_stop(integer(), map(), map()) :: :ok
  def emit_stream_stop(status, metrics_context, ctx) do
    backend_end = System.monotonic_time(:microsecond)
    backend_start = ctx.backend_start || backend_end

    measurements =
      build_measurements(
        duration: backend_end - metrics_context.start_time,
        pii_duration: ctx.pre_stream_timings.pii_duration,
        source_conversion_duration: ctx.pre_stream_timings.source_conversion_duration,
        target_conversion_duration: ctx.pre_stream_timings.target_conversion_duration,
        backend_duration: backend_end - backend_start,
        restore_duration: metrics_context.restore_duration,
        pii_info: ctx.pii_info
      )

    metadata =
      build_metadata(
        source_provider: metrics_context.metrics_opts[:source_provider],
        target_provider: metrics_context.metrics_opts[:target_provider],
        request_path: metrics_context.metrics_opts[:request_path],
        method: metrics_context.metrics_opts[:method],
        streaming: metrics_context.metrics_opts[:streaming],
        started_at: ctx.started_at,
        status: status,
        conversation_id: metrics_context.conversation_id
      )

    emit_stop(measurements, metadata)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp log_request_complete(target_provider, path, method, status, measurements) do
    duration = format_duration(measurements.duration)
    backend = format_duration(measurements.backend_duration)
    pii_count = measurements.pii_sanitized_count

    Logger.info(
      "✅ Request complete | #{method |> to_string() |> String.upcase()} #{path} → #{target_provider} | #{duration} (backend: #{backend}) | Status: #{status}#{if pii_count > 0, do: " | 🔒 PII: #{pii_count}", else: ""}"
    )
  end

  defp format_duration(microseconds) when microseconds < 1_000 do
    "#{microseconds}μs"
  end

  defp format_duration(microseconds) when microseconds < 1_000_000 do
    "#{div(microseconds, 1000)}ms"
  end

  defp format_duration(microseconds) do
    "#{Float.round(microseconds / 1_000_000, 2)}s"
  end
end
