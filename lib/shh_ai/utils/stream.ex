defmodule ShhAi.Utils.Stream do
  @moduledoc false

  @doc false
  def stream_binary(binary, chunk_size) do
    Stream.unfold(0, fn skip ->
      case binary do
        <<_skipped::binary-size(skip), chunk::binary-size(chunk_size), _rest::binary>> ->
          {chunk, skip + chunk_size}

        <<_skipped::binary-size(skip)>> ->
          nil

        <<_skipped::binary-size(skip), chunk::binary>> ->
          {chunk, skip + byte_size(chunk)}
      end
    end)
  end
end
