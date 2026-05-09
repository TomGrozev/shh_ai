defmodule ShhAi.Metrics.Event do
  @moduledoc """
  Struct representing a single request metrics event.

  This struct captures all relevant information about a proxied request,
  including timing, PII detection, and provider information.
  """

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
      duration_ms: native_to_milliseconds(measurements[:duration]),
      source_provider: Map.fetch!(metadata, :source_provider),
      target_provider: Map.fetch!(metadata, :target_provider),
      request_path: Map.fetch!(metadata, :request_path),
      method: Map.fetch!(metadata, :method),
      streaming: Map.get(metadata, :streaming, false),
      status: Map.get(metadata, :status),
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
      source_provider: string_to_atom(Map.fetch!(map, "source_provider")),
      target_provider: Map.fetch!(map, "target_provider"),
      request_path: Map.fetch!(map, "request_path"),
      method: Map.fetch!(map, "method"),
      streaming: Map.fetch!(map, "streaming"),
      status: Map.get(map, "status"),
      pii_detected_count: Map.fetch!(map, "pii_detected_count"),
      pii_sanitized_count: Map.fetch!(map, "pii_sanitized_count"),
      pii_preserved_count: Map.get(map, "pii_preserved_count", 0),
      pii_types: Enum.map(Map.fetch!(map, "pii_types"), &string_to_atom/1),
      timings:
        Map.new(Map.fetch!(map, "timings"), fn {k, v} ->
          {String.to_existing_atom(k), v}
        end),
      error: Map.get(map, "error"),
      inserted_at: Map.fetch!(map, "inserted_at")
    }
  end

  # Private helpers

  defp native_to_milliseconds(nil), do: 0.0
  defp native_to_milliseconds(duration) when is_integer(duration), do: duration / 1_000

  defp build_timings_map(measurements) do
    %{
      pii_ms: native_to_milliseconds(measurements[:pii_duration]),
      source_conversion_ms: native_to_milliseconds(measurements[:source_conversion_duration]),
      target_conversion_ms: native_to_milliseconds(measurements[:target_conversion_duration]),
      backend_ms: native_to_milliseconds(measurements[:backend_duration]),
      restore_ms: native_to_milliseconds(measurements[:restore_duration])
    }
  end

  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(other), do: other

  defp string_to_atom(string) when is_binary(string), do: String.to_atom(string)
  defp string_to_atom(other), do: other
end
