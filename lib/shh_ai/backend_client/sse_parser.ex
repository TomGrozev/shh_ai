defmodule ShhAi.BackendClient.SSEParser do
  @moduledoc false

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
