defmodule ShhAi.PIIPipeline.RestoreState do
  @moduledoc """
  Typed contract for the per-stream PII restore state.

  Carries the split-placeholder buffer and the in-flight tool-call
  argument accumulator across chunks. Tool-call argument deltas arrive as
  JSON string fragments that may split a placeholder mid-way, so they
  cannot be restored per delta: each fragment is appended to its call's
  buffer and the whole argument string is restored once, then emitted as
  a single synthesized delta when the call completes (a new call index
  begins or the stream finishes).

  Returned by `ShhAi.PIIPipeline.restore_stream_chunk/3` and
  `ShhAi.PIIPipeline.restore_stream_events/3` as the second tuple
  element. Owned by `ShhAi.PIIPipeline` (the consumer that reads and
  writes the state) and threaded through `ShhAi.ProviderClient.StreamHandler`
  via `ShhAi.ProviderClient.StreamHandler.Handle.pii_state`.
  """

  @enforce_keys [:buffer]

  defstruct buffer: "", tool_calls: %{}

  @type tool_call_entry :: %{arguments: binary()}

  @type t :: %__MODULE__{
          buffer: binary(),
          tool_calls: %{non_neg_integer() => tool_call_entry()}
        }

  @doc "Returns the empty restore state — initial state before any chunks processed."
  @spec new() :: t()
  def new, do: %__MODULE__{buffer: ""}
end
