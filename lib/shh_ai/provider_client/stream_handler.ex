defmodule ShhAi.ProviderClient.StreamHandler do
  @moduledoc """
  Host module for streaming lifecycle contracts.

  Owns the per-chunk Accumulator and per-request RequestMeta structs.
  In a follow-up slice (Candidate 3), this module will gain a behaviour
  with init/1 and handle_chunk/3 callbacks.
  """
end
