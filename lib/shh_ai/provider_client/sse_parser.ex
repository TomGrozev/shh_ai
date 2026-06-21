defmodule ShhAi.ProviderClient.SSEParser do
  @moduledoc false

  @enforce_keys [:type]
  defstruct [:type, :event_name, :payload]

  @type t :: %__MODULE__{
          type: :data | :done | :event,
          event_name: String.t() | nil,
          payload: map() | nil
        }

  @type parse_reason :: :partial | :invalid_json | :malformed

  @doc """
  Constructs a new SSEEvent struct with invariant validation.

  - `new!(:data, payload: %{})` — payload required, must be a map
  - `new!(:event, event_name: "x", payload: %{})` — event_name required (string), payload required (map)
  - `new!(:done)` — no kwargs allowed
  """
  @spec new!(:data, keyword()) :: t()
  @spec new!(:event, keyword()) :: t()
  @spec new!(:done) :: t()
  def new!(type, opts \\ [])

  def new!(:data, opts) do
    payload = Keyword.get(opts, :payload)

    unless is_map(payload) do
      raise ArgumentError,
            "SSEParser.new!(:data) requires :payload to be a map, got: #{inspect(payload)}"
    end

    %__MODULE__{type: :data, payload: payload, event_name: nil}
  end

  def new!(:event, opts) do
    event_name = Keyword.get(opts, :event_name)
    payload = Keyword.get(opts, :payload)

    unless is_binary(event_name) do
      raise ArgumentError,
            "SSEParser.new!(:event) requires :event_name to be a string, got: #{inspect(event_name)}"
    end

    unless is_map(payload) do
      raise ArgumentError,
            "SSEParser.new!(:event) requires :payload to be a map, got: #{inspect(payload)}"
    end

    %__MODULE__{type: :event, event_name: event_name, payload: payload}
  end

  def new!(:done, opts) do
    if opts != [] do
      raise ArgumentError,
            "SSEParser.new!(:done) accepts no options, got: #{inspect(opts)}"
    end

    %__MODULE__{type: :done, event_name: nil, payload: nil}
  end

  @doc """
  Parses raw SSE bytes into a list of typed SSEParser structs.

  Returns a list of `%SSEParser{}` events for complete frames, or
  `{:error, reason}` if the bytes contain a partial frame, invalid JSON,
  or malformed input.
  """
  @spec parse(binary()) :: [t()] | {:error, :partial | :invalid_json | :malformed}
  def parse(bytes) when is_binary(bytes) do
    case parse_frames(bytes, []) do
      {:error, _} = err -> err
      acc -> Enum.reverse(acc)
    end
  end

  defp parse_frames(bytes, acc) do
    case extract_frame(bytes) do
      {:complete, frame, rest} ->
        case parse_frame(frame) do
          {:ok, event} -> parse_frames(rest, [event | acc])
          {:error, _reason} = err -> err
        end

      {:partial, ""} ->
        acc

      {:partial, _} ->
        {:error, :partial}
    end
  end

  defp extract_frame(bytes) do
    norm =
      if String.contains?(bytes, "\r\n"), do: String.replace(bytes, "\r\n", "\n"), else: bytes

    if String.contains?(norm, "\n\n") do
      [frame, rest] = String.split(norm, "\n\n", parts: 2)
      {:complete, frame, rest}
    else
      {:partial, bytes}
    end
  end

  defp parse_frame(frame) do
    lines = String.split(frame, "\n", trim: true)

    event_name = extract_field(lines, "event:")
    data = extract_field(lines, "data:")

    cond do
      event_name != nil and data != nil ->
        parse_typed_event(event_name, data)

      event_name != nil ->
        {:error, :malformed}

      data != nil ->
        parse_data_payload(data)

      true ->
        {:error, :malformed}
    end
  end

  # Pull the value of a single SSE field (`event:` or `data:`) from a list
  # of lines. Returns the trimmed string, or `nil` if the field is
  # absent or empty. Handles both the spaced (`data: x`) and unspaced
  # (`data:x`) forms of the prefix.
  defp extract_field(lines, prefix) do
    Enum.find_value(lines, fn
      ^prefix <> rest ->
        trimmed = String.trim(rest)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end)
  end

  defp parse_typed_event(event_name, data) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) ->
        {:ok, %__MODULE__{type: :event, event_name: event_name, payload: payload}}

      {:ok, _} ->
        {:error, :invalid_json}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp parse_data_payload("[DONE]"),
    do: {:ok, %__MODULE__{type: :done, event_name: nil, payload: nil}}

  defp parse_data_payload(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> {:ok, %__MODULE__{type: :data, payload: payload}}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
