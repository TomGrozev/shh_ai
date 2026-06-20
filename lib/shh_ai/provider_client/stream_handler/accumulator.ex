defmodule ShhAi.ProviderClient.StreamHandler.Accumulator do
  @moduledoc """
  Typed contract for per-chunk streaming accumulator.

  Fields mutate as chunks arrive; finalize at stream end to emit metrics.
  """

  @type t :: %__MODULE__{
          restore_duration: non_neg_integer(),
          assistant_content_chunks: [String.t()]
        }

  @enforce_keys [:restore_duration, :assistant_content_chunks]

  defstruct restore_duration: 0, assistant_content_chunks: []

  @doc """
  Returns the empty accumulator — initial state before any chunks processed.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{restore_duration: 0, assistant_content_chunks: []}
  end
end
