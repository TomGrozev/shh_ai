defmodule ShhAi.Metrics.Event do
  @moduledoc """
  Struct representing a single request metrics event.

  This struct captures all relevant information about a proxied request,
  including timing, PII detection, and provider information.
  """

  alias ShhAi.Utils

  @type t :: %__MODULE__{
          id: String.t(),
          started_at: integer(),
          ended_at: integer(),
          duration_ms: float(),
          source_provider: atom(),
          target_provider: String.t(),
          request_path: String.t(),
          method: String.t(),
          streaming: boolean(),
          status: integer() | nil,
          conversation_id: String.t() | nil,
          pii_detected_count: non_neg_integer(),
          pii_sanitized_count: non_neg_integer(),
          pii_preserved_count: non_neg_integer(),
          pii_types: [atom()],
          timings: map(),
          error: map() | nil,
          inserted_at: integer()
        }

  @enforce_keys [
    :id,
    :started_at,
    :ended_at,
    :duration_ms,
    :source_provider,
    :target_provider,
    :request_path,
    :method,
    :streaming,
    :pii_detected_count,
    :pii_sanitized_count,
    :pii_preserved_count,
    :pii_types,
    :timings,
    :inserted_at
  ]

  defstruct [
    :id,
    :started_at,
    :ended_at,
    :duration_ms,
    :source_provider,
    :target_provider,
    :request_path,
    :method,
    :streaming,
    :status,
    :conversation_id,
    :pii_detected_count,
    :pii_sanitized_count,
    :pii_preserved_count,
    :pii_types,
    :timings,
    :error,
    :inserted_at
  ]

  @doc """
  Creates a new Event from telemetry measurements and metadata.

  ## Parameters

    * `measurements` - Map with timing measurements (duration, pii_ms, backend_ms, etc.)
    * `metadata` - Map with request metadata (id, providers, path, PII info, etc.)

  ## Examples

      iex> measurements = %{duration: 150_000_000, pii_ms: 2.1, backend_ms: 145.0}
      iex> metadata = %{id: "uuid-123", source_provider: :openai, target_provider: :anthropic, ...}
      iex> ShhAi.Metrics.Event.from_telemetry(measurements, metadata)
      %ShhAi.Metrics.Event{...}

  """
  @spec from_telemetry(measurements :: map(), metadata :: map()) :: t()
  def from_telemetry(measurements, metadata) do
    now = System.system_time(:microsecond)

    %__MODULE__{
      id: Map.fetch!(metadata, :id),
      started_at: Map.get(metadata, :started_at, now),
      ended_at: now,
      duration_ms: microseconds_to_milliseconds(measurements[:duration]),
      source_provider: Map.fetch!(metadata, :source_provider),
      target_provider: to_string(Map.fetch!(metadata, :target_provider)),
      request_path: Map.fetch!(metadata, :request_path),
      method: Map.fetch!(metadata, :method),
      streaming: Map.get(metadata, :streaming, false),
      status: Map.get(metadata, :status),
      conversation_id: Map.get(metadata, :conversation_id),
      pii_detected_count: Map.get(measurements, :pii_detected_count, 0),
      pii_sanitized_count: Map.get(measurements, :pii_sanitized_count, 0),
      pii_preserved_count: Map.get(measurements, :pii_preserved_count, 0),
      pii_types: Map.get(measurements, :pii_types, []),
      timings: build_timings_map(measurements),
      error: Map.get(metadata, :error),
      inserted_at: now
    }
  end

  @doc """
  Converts an Event to a map suitable for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      id: event.id,
      started_at: event.started_at,
      ended_at: event.ended_at,
      duration_ms: event.duration_ms,
      source_provider: atom_to_string(event.source_provider),
      target_provider: event.target_provider,
      request_path: event.request_path,
      method: event.method,
      streaming: event.streaming,
      status: event.status,
      conversation_id: event.conversation_id,
      pii_detected_count: event.pii_detected_count,
      pii_sanitized_count: event.pii_sanitized_count,
      pii_preserved_count: event.pii_preserved_count,
      pii_types: Enum.map(event.pii_types, &atom_to_string/1),
      timings: event.timings,
      error: event.error,
      inserted_at: event.inserted_at
    }
  end

  @doc """
  Creates an Event from a JSON-decoded map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      id: Map.fetch!(map, "id"),
      started_at: Map.fetch!(map, "started_at"),
      ended_at: Map.fetch!(map, "ended_at"),
      duration_ms: Map.fetch!(map, "duration_ms"),
      source_provider: Utils.safe_to_existing_atom(Map.fetch!(map, "source_provider")),
      target_provider: Map.fetch!(map, "target_provider"),
      request_path: Map.fetch!(map, "request_path"),
      method: Map.fetch!(map, "method"),
      streaming: Map.fetch!(map, "streaming"),
      status: Map.get(map, "status"),
      conversation_id: Map.get(map, "conversation_id"),
      pii_detected_count: Map.fetch!(map, "pii_detected_count"),
      pii_sanitized_count: Map.fetch!(map, "pii_sanitized_count"),
      pii_preserved_count: Map.get(map, "pii_preserved_count", 0),
      pii_types:
        Map.fetch!(map, "pii_types")
        |> Enum.map(&Utils.safe_to_existing_atom/1)
        |> Enum.reject(&is_nil/1),
      timings:
        Map.new(
          for {k, v} <- Map.fetch!(map, "timings"),
              key = Utils.safe_to_existing_atom(k),
              key != nil do
            {key, v}
          end
        ),
      error: Map.get(map, "error"),
      inserted_at: Map.fetch!(map, "inserted_at")
    }
  end

  # Private helpers

  defp microseconds_to_milliseconds(nil), do: 0.0
  defp microseconds_to_milliseconds(duration) when is_integer(duration), do: duration / 1_000

  defp build_timings_map(measurements) do
    %{
      pii_ms: microseconds_to_milliseconds(measurements[:pii_duration]),
      source_conversion_ms:
        microseconds_to_milliseconds(measurements[:source_conversion_duration]),
      target_conversion_ms:
        microseconds_to_milliseconds(measurements[:target_conversion_duration]),
      backend_ms: microseconds_to_milliseconds(measurements[:backend_duration]),
      restore_ms: microseconds_to_milliseconds(measurements[:restore_duration])
    }
  end

  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(other), do: other

  @doc """
  Returns true if the event represents a successful request.

  A successful request has:
  - HTTP status in the 2xx range (200-299)
  - No error field set

  This is the canonical definition used across the codebase for
  filtering successful events in dashboards and metrics.
  """
  @spec successful?(t()) :: boolean()
  def successful?(%__MODULE__{} = event) do
    is_nil(event.error) and
      is_integer(event.status) and
      event.status >= 200 and
      event.status < 300
  end

  @doc """
  Returns true if the event matches the given provider (source or target).
  """
  @spec matches_provider?(t(), atom() | nil) :: boolean()
  def matches_provider?(_event, nil), do: true

  def matches_provider?(event, provider) when is_atom(provider) do
    provider_str = Atom.to_string(provider)

    to_string(event.source_provider) == provider_str or
      to_string(event.target_provider) == provider_str
  end

  @doc """
  Returns true if the event matches the given streaming flag.
  """
  @spec matches_streaming?(t(), boolean() | nil) :: boolean()
  def matches_streaming?(_event, nil), do: true

  def matches_streaming?(event, streaming) when is_boolean(streaming) do
    event.streaming == streaming
  end

  @doc """
  Filters a list of events based on the provided options.

  ## Options

    * `:provider` - Filter by source or target provider (atom)
    * `:streaming` - Filter by streaming flag (boolean)
    * `:status_success` - Filter by success status (boolean)
    * `:conversation_id` - Filter by conversation ID (string)

  """
  @spec filter([t()], keyword() | map()) :: [t()]
  def filter(events, opts) when is_map(opts) do
    filter(events, Map.to_list(opts))
  end

  def filter(events, opts) when is_list(opts) do
    events
    |> filter_by_provider(Keyword.get(opts, :provider))
    |> filter_by_streaming(Keyword.get(opts, :streaming))
    |> filter_by_status_success(Keyword.get(opts, :status_success))
    |> filter_by_conversation_id(Keyword.get(opts, :conversation_id))
  end

  defp filter_by_provider(events, nil), do: events

  defp filter_by_provider(events, provider) do
    Enum.filter(events, &matches_provider?(&1, provider))
  end

  defp filter_by_streaming(events, nil), do: events

  defp filter_by_streaming(events, streaming) when is_boolean(streaming) do
    Enum.filter(events, &matches_streaming?(&1, streaming))
  end

  defp filter_by_status_success(events, nil), do: events
  defp filter_by_status_success(events, true), do: Enum.filter(events, &successful?/1)
  defp filter_by_status_success(events, false), do: Enum.reject(events, &successful?/1)

  defp filter_by_conversation_id(events, nil), do: events

  defp filter_by_conversation_id(events, conversation_id) when is_binary(conversation_id) do
    Enum.filter(events, &(&1.conversation_id == conversation_id))
  end

  @doc """
  Returns true if the event's target provider matches.
  """
  @spec matches_target_provider?(t(), String.t() | nil) :: boolean()
  def matches_target_provider?(_event, nil), do: true

  def matches_target_provider?(event, target) when is_binary(target) do
    to_string(event.target_provider) == target
  end
end
