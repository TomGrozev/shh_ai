defmodule ShhAi.ApiConverter.OpenAI do
  @moduledoc """
  OpenAI API format converter.
  OpenAI format is the canonical intermediate format, so this module
  mostly passes through data unchanged.
  """

  @behaviour ShhAi.ApiConverter

  alias ShhAi.ProviderClient.SSEParser

  # OpenAI format is canonical - pass through

  @impl true
  def to_openai_request(headers, body, _path), do: {headers, body}

  @impl true
  def from_openai_request(headers, body, _path), do: {headers, body}

  @impl true
  def to_openai_response(response, _path), do: response

  @impl true
  def from_openai_response(response, _path), do: response

  # Streaming callbacks. `to_openai_stream_events/2` parses SSE wire bytes
  # into typed `%SSEParser{}` events (one parse per chunk on the hot path)
  # and `from_openai_stream_events/2` serialises the events back to
  # OpenAI-format SSE bytes for the source client.
  #
  # The Ollama-as-target fallback path
  # (`StreamHandler.convert_via_chunks/6`) calls Ollama's plain
  # `to_openai_stream_chunk/2` to parse NDJSON to OpenAI chunks, then
  # re-parses those chunks to events and uses the events path uniformly.
  @impl true
  def to_openai_stream_events(chunk, _path) do
    case SSEParser.parse(chunk) do
      {:error, _reason} -> {:error, :invalid_format}
      events when is_list(events) -> events
    end
  end

  @impl true
  def from_openai_stream_events(events, _path) when is_list(events) do
    classify_events(events)
  end

  @impl true
  def to_openai_path(path), do: path

  @impl true
  def from_openai_path(path), do: path

  @impl true
  def get_path_type("/v1/chat/completions"), do: {:chat, "/v1/chat/completions"}
  def get_path_type("/v1/completions"), do: {:chat, "/v1/completions"}
  def get_path_type("/v1/embeddings"), do: {:embeddings, "/v1/embeddings"}
  def get_path_type("/v1/models"), do: {:models, "/v1/models"}
  def get_path_type(path), do: {:other, path}

  # Serialize a list of typed `%SSEParser{}` events back to OpenAI-format
  # SSE wire bytes. Used by `from_openai_stream_events/2` (events-in,
  # source-bytes-out) and by tests. The `:data` and `:event` cases
  # produce the same wire shape ("data: JSON\n\n") since OpenAI's wire
  # format has no `event:` lines; the split is preserved for clarity
  # (and to keep the function symmetric with the Anthropic converter).
  #
  # The `:done` event halts the reduce and tags the result with `{:done,
  # chunks}`. An empty input list is treated as `{:error, :invalid_format}`
  # to match the existing error-handling contract.
  defp classify_events(events) do
    events
    |> Enum.reduce_while([], fn event, acc ->
      case event do
        %SSEParser{type: :done} ->
          {:halt, {:done, ["data: [DONE]\n\n" | acc]}}

        %SSEParser{type: :data, payload: payload} ->
          {:cont, ["data: #{Jason.encode!(payload)}\n\n" | acc]}

        %SSEParser{type: :event, payload: payload} ->
          {:cont, ["data: #{Jason.encode!(payload)}\n\n" | acc]}
      end
    end)
    |> handle_empty_events()
    |> case do
      {:done, acc} -> {:done, Enum.reverse(acc)}
      chunks when is_list(chunks) -> Enum.reverse(chunks)
      other -> other
    end
  end

  defp handle_empty_events({:done, _} = result), do: result
  defp handle_empty_events([]), do: {:error, :invalid_format}
  defp handle_empty_events(chunks) when is_list(chunks), do: chunks
end
