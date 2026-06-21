defmodule ShhAi.PIIPipeline.RestoreState do
  @moduledoc """
  Typed contract for the per-stream PII restore state.

  Carries the split-placeholder buffer across chunks. Returned by
  `ShhAi.PIIPipeline.restore_stream_chunk/3` and
  `ShhAi.PIIPipeline.restore_stream_events/3` as the second tuple
  element. Owned by `ShhAi.PIIPipeline` (the consumer that reads and
  writes the buffer) and threaded through `ShhAi.ProviderClient.StreamHandler`
  via `ShhAi.ProviderClient.StreamHandler.Handle.pii_state`.
  """

  @enforce_keys [:buffer]

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc "Returns the empty restore state — initial state before any chunks processed."
  @spec new() :: t()
  def new, do: %__MODULE__{buffer: ""}
end
