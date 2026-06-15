defmodule ShhAi.ApiConverter.Shared do
  @moduledoc false

  @doc """
  Generates a unique ID with the given prefix.
  Format: `"\#{prefix}-\#{24 hex chars}"`.
  """
  def generate_id(prefix) do
    random_suffix =
      :crypto.strong_rand_bytes(12)
      |> Base.encode16(case: :lower)

    "#{prefix}-#{random_suffix}"
  end

  @doc """
  Parses a single SSE inner chunk.

  Returns:
    * `{:data, data_string}` for `data:` lines (with or without a trailing space)
    * `:done` for chunks containing `[DONE]`
    * `{:error, :invalid_format}` for unparseable chunks
  """
  def parse_sse_chunk(chunk) do
    cond do
      String.contains?(chunk, "[DONE]") ->
        :done

      String.starts_with?(chunk, "data:") ->
        [_, data] = String.split(chunk, "data:", parts: 2)
        {:data, String.trim(data)}

      true ->
        {:error, :invalid_format}
    end
  end
end
