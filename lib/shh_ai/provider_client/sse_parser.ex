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
    norm = String.replace(bytes, "\r\n", "\n")

    if String.contains?(norm, "\n\n") do
      [frame, rest] = String.split(norm, "\n\n", parts: 2)
      {:complete, frame, rest}
    else
      {:partial, bytes}
    end
  end

  defp parse_frame(frame) do
    lines = String.split(frame, "\n", trim: true)

    event_name =
      Enum.find_value(lines, fn
        "event: " <> rest -> String.trim(rest)
        "event:" <> rest ->
          trimmed = String.trim_leading(rest)
          if trimmed == "", do: nil, else: trimmed
        _ -> nil
      end)

    data =
      Enum.find_value(lines, fn
        "data: " <> rest ->
          trimmed = String.trim(rest)
          if trimmed == "", do: nil, else: trimmed

        "data:" <> rest ->
          trimmed = String.trim(rest)
          if trimmed == "", do: nil, else: trimmed

        _ -> nil
      end)

    cond do
      event_name != nil and data != nil ->
        case Jason.decode(data) do
          {:ok, payload} when is_map(payload) ->
            {:ok, %__MODULE__{type: :event, event_name: event_name, payload: payload}}
          {:ok, _} -> {:error, :invalid_json}
          {:error, _} -> {:error, :invalid_json}
        end

      event_name != nil ->
        {:error, :malformed}

      data != nil ->
        parse_data_payload(data)

      true ->
        {:error, :malformed}
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

  @doc """
  Extracts the assistant message from an OpenAI-format response.

  Matches a single-element `choices` list with either a `message` or `delta` key.
  Falls back to an empty assistant message.
  """
  @spec extract_assistant_message(map()) :: map()
  def extract_assistant_message(%{"choices" => [%{"message" => message} | _]}), do: message
  def extract_assistant_message(%{"choices" => [%{"delta" => delta} | _]}), do: delta
  def extract_assistant_message(_), do: %{"role" => "assistant", "content" => ""}

  @doc """
  Extracts text content from a list of OpenAI-format SSE chunks.

  Only text content (`delta.content` / `message.content`) is returned.
  Tool calls and other non-text content are silently ignored.
  """
  @spec extract_content_from_openai_chunks(list()) :: String.t()
  def extract_content_from_openai_chunks(chunks) when is_list(chunks) do
    Enum.map_join(chunks, fn chunk ->
      case parse_sse_chunk_to_map(chunk) do
        %{"choices" => _} = map ->
          get_in(map, ["choices", Access.at(0), "delta", "content"]) ||
            get_in(map, ["choices", Access.at(0), "message", "content"]) || ""

        _ ->
          ""
      end
    end)
  end

  def extract_content_from_openai_chunks(_), do: ""

  @doc """
  Parses an SSE chunk (binary or map) into a map.
  """
  @spec parse_sse_chunk_to_map(binary() | map()) :: map()
  def parse_sse_chunk_to_map(chunk) when is_map(chunk), do: chunk

  def parse_sse_chunk_to_map(chunk) when is_binary(chunk) do
    if String.starts_with?(chunk, "data:") do
      chunk
      |> String.replace_prefix("data:", "")
      |> String.trim()
      |> decode_sse_data()
    else
      %{}
    end
  end

  @doc """
  Decodes an SSE `data:` payload. Returns an empty map for `[DONE]`
  or invalid JSON.
  """
  @spec decode_sse_data(String.t()) :: map()
  def decode_sse_data("[DONE]"), do: %{}

  def decode_sse_data(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end
end
