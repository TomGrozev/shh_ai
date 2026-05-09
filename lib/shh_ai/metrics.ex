defmodule ShhAi.Metrics do
  @moduledoc """
  Telemetry-based metrics collection for the LLM Privacy Proxy.

  This module provides:
  - Telemetry event emission for request lifecycle
  - ETS-backed ring buffer for recent events (fast dashboard access)
  - JSONL file persistence for long-term storage

  ## Architecture

      Request → emit_start() → ...processing... → emit_stop()
                                         │
                                         ▼
                              ┌────────────────────────┐
                              │  Telemetry Handler     │
                              └──────────┬─────────────┘
                                         │
                              ┌──────────┴─────────────┐
                              ▼                        ▼
                     ┌───────────────┐      ┌─────────────────┐
                     │ ETS Ring Buffer│      │ JSONL File      │
                     │ (last 1000)    │      │ (append-only)   │
                     └───────────────┘      └─────────────────┘

  ## Telemetry Events

  ### Request Start

  Event: `[:shh_ai, :request, :start]`

  Measurements: (none at start)

  Metadata:
  - `:id` - Unique request ID (UUID)
  - `:source_provider` - Request format provider (:openai, :anthropic, :ollama)
  - `:request_path` - The request path
  - `:method` - HTTP method
  - `:streaming` - Whether this is a streaming request

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
  - `:id` - Request ID (matches start event)
  - `:target_provider` - Selected backend provider
  - `:status` - HTTP response status code
  - `:pii_detected_count` - Total PII items detected
  - `:pii_sanitized_count` - PII items actually sanitized
  - `:pii_preserved_count` - PII items preserved via context rules
  - `:pii_types` - List of PII types detected (e.g., [:email, :phone])
  - `:error` - Error info if request failed (%{type: ..., message: ...})

  ## Usage

  ### Emitting Events

      # At request start
      ShhAi.Metrics.emit_start(%{
        source_provider: :openai,
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      })

      # At request completion
      ShhAi.Metrics.emit_stop(measurements, metadata)

  ### Attaching Custom Handlers

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

  @doc """
  Emits a request start telemetry event.

  ## Parameters

    * `metadata` - Map with request metadata

  ## Metadata

    * `:id` - Unique request ID (auto-generated if not provided)
    * `:source_provider` - Request format provider
    * `:request_path` - The request path
    * `:method` - HTTP method
    * `:streaming` - Whether this is a streaming request (default: false)

  ## Examples

      iex> ShhAi.Metrics.emit_start!(%{
      ...>   source_provider: :openai,
      ...>   request_path: "/v1/chat/completions",
      ...>   method: "POST"
      ...> })
      {:ok, %{
        id: "uuid-123",
        source_provider: :openai,
        request_path: "/v1/chat/completions",
        method: "POST"
      }}

  """
  @required_start_keys [:source_provider, :request_path, :method]

  @spec emit_start!(metadata :: map()) :: {:ok, map()}
  def emit_start!(metadata) when is_map(metadata) do
    validate_required_keys!(metadata, @required_start_keys)

    metadata = Map.put_new(metadata, :id, generate_id())
    metadata = Map.put_new(metadata, :streaming, false)
    metadata = Map.put(metadata, :started_at, System.system_time(:microsecond))

    :ok = :telemetry.execute([:shh_ai, :request, :start], %{}, metadata)

    {:ok, metadata}
  end

  defp validate_required_keys!(map, required_keys) do
    missing = Enum.reject(required_keys, &Map.has_key?(map, &1))

    if Enum.empty?(missing) do
      :ok
    else
      raise ArgumentError, "missing required emit keys #{inspect(missing)}"
    end
  end

  @doc """
  Emits a request stop telemetry event.

  ## Parameters

    * `measurements` - Map with timing measurements
    * `metadata` - Map with request metadata

  ## Measurements

    * `:duration` - Total request duration (native time units)
    * `:pii_duration` - PII detection/sanitization time (native)
    * `:source_conversion_duration` - Format source conversion time (native)
    * `:target_conversion_duration` - Format target conversion time (native)
    * `:backend_duration` - Backend request time (native)
    * `:restore_duration` - PII restoration time (native)

  ## Metadata

    * `:id` - Request ID (must match start event)
    * `:target_provider` - Selected backend provider
    * `:status` - HTTP response status code
    * `:pii_detected_count` - Total PII items detected
    * `:pii_sanitized_count` - PII items actually sanitized
    * `:pii_preserved_count` - PII items preserved via context rules
    * `:pii_types` - List of PII types detected
    * `:error` - Error info if request failed (optional)

  ## Examples

      iex> measurements = %{
      ...>   duration: 150_000_000,
      ...>   pii_duration: 2_100_000,
      ...>   backend_duration: 145_000_000
      ...> }
      iex> metadata = %{
      ...>   id: "uuid-123",
      ...>   target_provider: :anthropic,
      ...>   status: 200,
      ...>   pii_detected_count: 2,
      ...>   pii_types: [:email, :phone]
      ...> }
      iex> ShhAi.Metrics.emit_stop!(measurements, metadata)
      :ok

  """
  @required_stop_measurement_keys [:duration]
  @required_stop_metadata_keys [:id, :target_provider, :status]

  @spec emit_stop!(measurements :: map(), metadata :: map()) :: :ok
  def emit_stop!(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    validate_required_keys!(measurements, @required_stop_measurement_keys)
    validate_required_keys!(metadata, @required_stop_metadata_keys)

    :telemetry.execute([:shh_ai, :request, :stop], measurements, metadata)
  end

  @doc """
  Creates a telemetry handler function that persists events to ETS and JSONL.

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
  3. Appends to JSONL file (for long-term storage)
  """
  @spec persist_handler(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: any()
  def persist_handler(_event_name, measurements, metadata, _config) do
    try do
      event = Event.from_telemetry(measurements, metadata)
      EventBuffer.store(event)
      Phoenix.PubSub.broadcast(ShhAi.PubSub, "dashboard:requests", {:request, event})
    rescue
      exception ->
        Logger.error("Failed to persist metrics event: #{inspect(exception)}")
    end
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
    ShhAi.Metrics.Stats.calculate(events)
  end

  # Private helpers

  defp generate_id do
    # Generate a short UUID-like ID
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
