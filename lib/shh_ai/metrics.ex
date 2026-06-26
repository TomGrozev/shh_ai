defmodule ShhAi.Metrics do
  @moduledoc """
  Telemetry-based metrics collection for the LLM Privacy Proxy.

  This module provides:
  - Telemetry event emission for request lifecycle
  - ETS-backed ring buffer for recent events (fast dashboard access)
  - Audit Mode persistence via the Audit Writer to the SQLite `events` table (when AUDIT_MODE=true; ephemeral in ETS when off)

  ## Architecture

      Request → emit_success/emit_error/emit_stream_stop at completion
                                    │
                                    ▼
                          ┌────────────────────────┐
                          │  Telemetry Handler     │
                          └──────────┬─────────────┘
                                     │
                          ┌──────────┴─────────────┐
                          ▼                        ▼
                  ┌───────────────┐      ┌──────────────────┐
                  │ ETS Ring Buffer│      │ Audit Writer     │
                  │ (last 1000)    │ ───▶ │ (cast :write_    │
                  │ (always)       │      │  event)          │
                  └───────────────┘      └────────┬─────────┘
                                                 │
                                          AUDIT_MODE=true?
                                          ┌──────┴──────┐
                                         yes           no
                                          │             │
                                          ▼             ▼
                                  ┌──────────────┐  (no-op,
                                  │ SQLite       │   event stays
                                  │ events table │   in ETS only)
                                  └──────────────┘

  ## Telemetry Events

  ### Request Stop

  Event: `[:shh_ai, :request, :stop]`

  Measurements:
  - `:duration` - Total request duration (native time units)
  - `:pii_duration` - PII detection/sanitization time (native)
  - `:source_conversion_duration` - Format source conversion time (native)
  - `:target_conversion_duration` - Format target conversion time (native)
  - `:backend_duration` - Backend request time (native)
  - `:restore_duration` - PII restoration time (native)

  Metadata:
  - `:id` - Request ID (auto-generated if not provided)
  - `:source_provider` - Request format provider
  - `:target_provider` - Selected backend provider
  - `:request_path` - The request path
  - `:method` - HTTP method
  - `:streaming` - Whether this is a streaming request
  - `:status` - HTTP response status code
  - `:pii_detected_count` - Total PII items detected
  - `:pii_sanitized_count` - PII items actually sanitized
  - `:pii_preserved_count` - PII items preserved via context rules
  - `:pii_types` - List of PII types detected (e.g., [:email, :phone])
  - `:error` - Error info if request failed (%{type: ..., message: ...})

  ## Usage

      # Successful request
      ShhAi.Metrics.emit_success(duration: 150_000, source_provider: :openai, ...)

      # Error request
      ShhAi.Metrics.emit_error(started, error_type: :timeout, error_message: "...")

      # Streaming request
      ShhAi.Metrics.emit_stream_stop(status, request_context, backend_start, accumulator, conversation_id, assistant_content)

  ## Attaching Custom Handlers

      :telemetry.attach(
        "my-handler",
        [:shh_ai, :request, :stop],
        fn event, measurements, metadata, config ->
          # Custom processing
        end,
        %{}
      )

  """

  require Logger

  alias ShhAi.Metrics.Event
  alias ShhAi.Metrics.EventBuffer
  alias ShhAi.Metrics.Stats
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.StreamHandler.Accumulator

  @doc """
  Creates a telemetry handler function that stores events in ETS and
  casts them to the Audit Writer for optional SQLite persistence.

  This handler is designed to be attached with `:telemetry.attach/4`:

      :telemetry.attach(
        "metrics-persist-handler",
        [:shh_ai, :request, :stop],
        &ShhAi.Metrics.persist_handler/4,
        %{}
      )

  The handler:
  1. Creates an Event from measurements/metadata
  2. Stores in ETS ring buffer (for dashboard)
  3. Casts `{:write_event, event}` to `ShhAi.Audit.Writer`, which inserts
     a row into the SQLite `events` table when AUDIT_MODE=true and is a
     no-op when AUDIT_MODE=false. There is no JSONL fallback — events
     are ephemeral in ETS when Audit Mode is off. See issue #25.
  """
  @spec persist_handler(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: any()
  def persist_handler(_event_name, measurements, metadata, _config) do
    event = Event.from_telemetry(measurements, metadata)
    EventBuffer.store(event)
    Phoenix.PubSub.broadcast(ShhAi.PubSub, "dashboard:requests", {:request, event})

    # Broadcast to conversations topic if event has a conversation_id
    if event.conversation_id do
      Phoenix.PubSub.broadcast(
        ShhAi.PubSub,
        "dashboard:conversations",
        {:conversation_update, event}
      )
    end
  rescue
    exception ->
      Logger.error("Failed to persist metrics event: #{inspect(exception)}")
  end

  @doc """
  Lists recent events from the ETS ring buffer.

  ## Options

    * `:limit` - Maximum number of events to return (default: 100)
    * `:provider` - Filter by provider (optional)
    * `:streaming` - Filter by streaming flag (optional)

  ## Examples

      iex> ShhAi.Metrics.list_recent(limit: 50)
      [%ShhAi.Metrics.Event{...}, ...]

      iex> ShhAi.Metrics.list_recent(provider: :openai, limit: 20)
      [%ShhAi.Metrics.Event{...}, ...]

  """
  @spec list_recent(keyword()) :: [Event.t()]
  def list_recent(opts \\ []) do
    EventBuffer.list_recent(opts)
  end

  @doc """
  Lists events since time from the ETS ring buffer.

  ## Parameters

    * `window` - Atom of :minute, :hour, :day, :week to query for
    * `opts` - Keyword list of options

  ## Options

    * `:limit` - Maximum number of events to return (default: 100)
    * `:provider` - Filter by provider (optional)
    * `:streaming` - Filter by streaming flag (optional)

  ## Examples

      iex> ShhAi.Metrics.list_since(:day, limit: 50)
      [%ShhAi.Metrics.Event{...}, ...]

      iex> ShhAi.Metrics.list_since(:minute, provider: :openai, limit: 20)
      [%ShhAi.Metrics.Event{...}, ...]

  """
  @spec list_since(:minute | :hour | :day | :week, keyword()) :: [Event.t()]
  def list_since(window, opts \\ []) do
    now = System.system_time(:microsecond)

    start_time =
      case window do
        :minute -> now - 60_000_000
        :hour -> now - 3_600_000_000
        :day -> now - 86_400_000_000
        :week -> now - 604_800_000_000
      end

    EventBuffer.list_since(start_time, opts)
  end

  @doc """
  Returns aggregated statistics calculated from recent events.

  ## Options

    * `:limit` - Number of events to include in calculation (default: 1000)
    * `:provider` - Filter by provider (optional)
    * `:events` - Preloaded events to calculate stats for

  ## Returns

    * `:requests_total` - Total number of requests
    * `:requests_success` - Successful requests (2xx status)
    * `:requests_error` - Failed requests
    * `:avg_latency_ms` - Average latency in milliseconds
    * `:p95_latency_ms` - 95th percentile latency
    * `:pii_total_detected` - Total PII items detected
    * `:pii_by_type` - PII counts grouped by type
    * `:provider_usage` - Request counts by provider

  ## Examples

      iex> ShhAi.Metrics.calculate_stats(limit: 500)
      %{
        requests_total: 500,
        requests_success: 495,
        requests_error: 5,
        avg_latency_ms: 145.2,
        p95_latency_ms: 289.5,
        pii_total_detected: 127,
        pii_by_type: %{email: 45, phone: 32, ...},
        provider_usage: %{openai: 200, anthropic: 150, ollama: 150}
      }

  """
  @spec calculate_stats(keyword()) :: map()
  def calculate_stats(opts \\ []) do
    events = Keyword.get_lazy(opts, :events, fn -> list_recent(opts) end)
    Stats.calculate(events)
  end

  @doc """
  Captures the current monotonic and system time atomically for use as a
  request start timestamp.

  Call once at the top of a request handler, then use `started.monotonic`
  for elapsed-time calculations and `started.system` for `started_at` metadata.
  """
  @spec capture_started() :: %{monotonic: integer(), system: integer()}
  def capture_started do
    %{monotonic: System.monotonic_time(:microsecond), system: System.system_time(:microsecond)}
  end

  @doc """
  Emits telemetry for a successful request and returns the measurements map.

  Builds both measurements and metadata from a single keyword list via the
  private `build_telemetry/1`, emits the stop event, and returns measurements
  so callers can include them in the response.

  ## Options

  All timing options (default 0):

    * `:duration` - Total request duration in microseconds
    * `:pii_duration` - PII detection/sanitization time
    * `:source_conversion_duration` - Format source conversion time
    * `:target_conversion_duration` - Format target conversion time
    * `:backend_duration` - Backend request time
    * `:restore_duration` - PII restoration time
    * `:pii_info` - Map with PII counts/types (default: `%{}`)

  Required metadata:

    * `:source_provider` - Request format provider
    * `:target_provider` - Selected backend provider
    * `:request_path` - The request path
    * `:method` - HTTP method
    * `:started_at` - Wall-clock start time in microseconds

  Optional metadata:

    * `:streaming` - Whether this is a streaming request (default: false)
    * `:status` - HTTP response status code (default: 0)
    * `:conversation_id` - Conversation ID (omitted from map if nil)
    * `:error` - Error info map `%{type: ..., message: ...}` (omitted if nil)

  """
  @spec emit_success(keyword()) :: map()
  def emit_success(opts) when is_list(opts) do
    {measurements, metadata} = build_telemetry(opts)
    emit_stop(measurements, metadata)
    measurements
  end

  @doc """
  Emits telemetry and logs a request error event.

  Accepts a `started` timestamp map (from `now/0`) and the same timing/metadata
  options as `emit_success/1`, augmented with error-specific fields. All options
  are passed through to `build_telemetry/1`.

  ## Error-specific options (required)

    * `:error_type` - Error type atom or string
    * `:error_message` - Error message string

  ## Timing options (all default to 0 if not provided)

    * `:duration` - Computed from `started` if not already set
    * `:pii_duration` - PII detection/sanitization time
    * `:source_conversion_duration` - Format source conversion time
    * `:target_conversion_duration` - Format target conversion time
    * `:backend_duration` - Backend request time
    * `:restore_duration` - PII restoration time
    * `:pii_info` - Map with PII counts/types (default: `%{}`)

  ## Required metadata

    * `:source_provider` - Request format provider
    * `:target_provider` - Selected backend provider
    * `:request_path` - The request path
    * `:method` - HTTP method

  ## Optional metadata

    * `:streaming` - Whether this is a streaming request (default: false)
    * `:conversation_id` - Conversation ID (omitted from map if nil)

  """
  @spec emit_error(%{monotonic: integer(), system: integer()}, keyword()) :: :ok
  def emit_error(started, opts) when is_map(started) and is_list(opts) do
    now_mono = System.monotonic_time(:microsecond)

    opts =
      opts
      |> Keyword.put_new(:duration, now_mono - started.monotonic)
      |> Keyword.put(:started_at, started.system)
      |> Keyword.put(:status, 0)
      |> Keyword.put(:error, %{
        type: Keyword.fetch!(opts, :error_type),
        message: Keyword.fetch!(opts, :error_message)
      })

    {measurements, metadata} = build_telemetry(opts)
    emit_stop(measurements, metadata)
  end

  @doc """
  Context-aware variant of `emit_stream_stop` — accepts a
  `%RequestContext{}` plus `backend_start` directly. The per-request
  static values come from the context; the per-chunk restore duration
  comes from the accumulator.

  The 6-arg signature:

      emit_stream_stop(status, ctx, backend_start, acc, conversation_id, assistant_content)

  reads:

    * `status` — HTTP status from the stream
    * `ctx` — per-request state, source of `source_provider`, `target_provider`
      (from `ctx.config.name`), `request_path` (from `ctx.source_path`),
      `method`, `started_at`, `pii_info`, `pii_duration`/`source_conversion_duration`/
      `target_conversion_duration` (from `ctx.timings`), and `streaming`
    * `backend_start` — monotonic time at which the backend HTTP call began
      (recorded by `ProviderClient.perform_stream/3` immediately before
      `Req.request/1` is called)
    * `acc` — per-chunk accumulator holding `restore_duration`
    * `conversation_id` — finalised conversation ID
    * `assistant_content` — pre-joined assistant content binary
  """
  @spec emit_stream_stop(
          integer(),
          RequestContext.t(),
          integer(),
          Accumulator.t(),
          String.t(),
          String.t()
        ) :: map()
  def emit_stream_stop(
        status,
        %RequestContext{} = ctx,
        backend_start,
        %Accumulator{} = acc,
        conversation_id,
        assistant_content
      )
      when is_integer(backend_start) and is_binary(conversation_id) and
             is_binary(assistant_content) do
    backend_end = System.monotonic_time(:microsecond)

    emit_success(
      duration: backend_end - ctx.started.monotonic,
      pii_duration: ctx.timings.pii_duration,
      source_conversion_duration: ctx.timings.source_conversion_duration,
      target_conversion_duration: ctx.timings.target_conversion_duration,
      backend_duration: backend_end - backend_start,
      restore_duration: acc.restore_duration,
      pii_info: ctx.pii_info,
      source_provider: ctx.source_provider,
      target_provider: ctx.config.name,
      request_path: ctx.source_path,
      method: ctx.method,
      streaming: ctx.streaming,
      started_at: ctx.started.system,
      status: status,
      conversation_id: conversation_id,
      assistant_content: assistant_content
    )
  end

  @doc """
  Context-aware variant of `emit_success/1` for the non-streaming
  request path. Takes the per-request `%RequestContext{}`, the
  monotonic `backend_start` (captured by the caller immediately
  before the backend HTTP call), and a map of runtime-only overrides
  (duration, backend_duration, restore_duration, status,
  conversation_id).

  `backend_start` is passed in rather than reconstructed from the
  pre-stream timings, so any future timing phase added to
  `ProviderClient.prepare_request/7` cannot drift the value. This
  also matches the stream path (`emit_stream_stop/6` already takes
  `backend_start` explicitly).

  All fields derived from the request context (provider, path,
  method, streaming=false, pii_info, started_at, the three conversion
  durations) come from `default_success_opts/1`; the caller-supplied
  overrides are layered on top via `Keyword.merge`, so callers don't
  have to repeat the static fields.
  """
  @spec emit_success_for_context(RequestContext.t(), integer(), map()) :: map()
  def emit_success_for_context(%RequestContext{} = ctx, backend_start, overrides)
      when is_integer(backend_start) do
    opts =
      [backend_start: backend_start]
      |> Keyword.merge(default_success_opts(ctx))
      |> Keyword.merge(Map.to_list(overrides))

    emit_success(opts)
  end

  @doc """
  Context-aware variant of `emit_error/2` for the non-streaming
  request path. Takes the per-request `%RequestContext{}` plus a map
  of runtime-only overrides (error_type, error_message,
  conversation_id) and delegates to `emit_error/2` with the
  context-derived defaults.

  The caller-supplied overrides are merged on top of the defaults so
  they win on conflict, matching the `emit_success_for_context/2`
  layering convention.
  """
  @spec emit_error_for_context(RequestContext.t(), map()) :: :ok
  def emit_error_for_context(%RequestContext{} = ctx, overrides) do
    opts =
      default_success_opts(ctx)
      |> Keyword.merge(Map.to_list(overrides))

    emit_error(ctx.started, opts)
  end

  # Fields derived from `%RequestContext{}` that are static for the
  # lifetime of a request. Used by both `emit_success_for_context/3`
  # and `emit_error_for_context/2` so the two stay in lockstep.
  defp default_success_opts(%RequestContext{} = ctx) do
    [
      pii_duration: ctx.timings.pii_duration,
      source_conversion_duration: ctx.timings.source_conversion_duration,
      target_conversion_duration: ctx.timings.target_conversion_duration,
      pii_info: ctx.pii_info,
      source_provider: ctx.conversation.source_provider,
      target_provider: ctx.config.name,
      request_path: ctx.source_path,
      method: ctx.method,
      streaming: ctx.streaming,
      started_at: ctx.started.system
    ]
  end

  # Private helpers

  @required_stop_measurement_keys [:duration]
  @required_stop_metadata_keys [:source_provider, :target_provider, :status]

  defp emit_stop(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    validate_required_keys!(measurements, @required_stop_measurement_keys)
    validate_required_keys!(metadata, @required_stop_metadata_keys)

    metadata = Map.put_new(metadata, :id, generate_id())
    metadata = Map.put_new(metadata, :streaming, false)

    :telemetry.execute([:shh_ai, :request, :stop], measurements, metadata)

    log_request_complete(
      metadata.target_provider,
      metadata.request_path,
      metadata.method,
      metadata.status,
      measurements
    )
  end

  defp validate_required_keys!(map, required_keys) do
    missing = Enum.reject(required_keys, &Map.has_key?(map, &1))

    if Enum.empty?(missing) do
      :ok
    else
      raise ArgumentError, "missing required emit keys #{inspect(missing)}"
    end
  end

  defp build_telemetry(opts) do
    pii = Keyword.get(opts, :pii_info, %{})

    measurements = %{
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

    base_metadata = %{
      source_provider: Keyword.fetch!(opts, :source_provider),
      target_provider: Keyword.fetch!(opts, :target_provider),
      request_path: Keyword.fetch!(opts, :request_path),
      method: Keyword.fetch!(opts, :method),
      streaming: Keyword.get(opts, :streaming, false),
      started_at: Keyword.fetch!(opts, :started_at),
      status: Keyword.get(opts, :status, 0)
    }

    metadata =
      base_metadata
      |> maybe_put(:conversation_id, Keyword.get(opts, :conversation_id))
      |> maybe_put(:error, Keyword.get(opts, :error))
      |> maybe_put(:assistant_content, Keyword.get(opts, :assistant_content))

    {measurements, metadata}
  end

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

  defp generate_id do
    # Generate a short UUID-like ID
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
