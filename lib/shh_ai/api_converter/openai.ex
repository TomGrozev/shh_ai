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

  @impl true
  def to_openai_stream_chunk(chunk, _path) do
    case SSEParser.parse(chunk) do
      {:error, _reason} -> {:error, :invalid_format}
      events when is_list(events) -> classify_events(events)
    end
  end

  @impl true
  def from_openai_stream_chunk(chunk, _path) do
    case SSEParser.parse(chunk) do
      {:error, _reason} -> {:error, :invalid_format}
      events when is_list(events) -> classify_events(events)
    end
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

  defp classify_events(events) do
    Enum.reduce_while(events, [], fn event, acc ->
      case event do
        %SSEParser{type: :done} ->
          {:halt, {:done, acc ++ ["data: [DONE]\n\n"]}}

        %SSEParser{type: :data, payload: payload} ->
          {:cont, acc ++ ["data: #{Jason.encode!(payload)}\n\n"]}

        %SSEParser{type: :event, payload: payload} ->
          {:cont, acc ++ ["data: #{Jason.encode!(payload)}\n\n"]}
      end
    end)
    |> handle_empty_events()
  end

  defp handle_empty_events({:done, _} = result), do: result
  defp handle_empty_events([]), do: {:error, :invalid_format}
  defp handle_empty_events(chunks) when is_list(chunks), do: chunks
end
