defmodule ShhAi.ConversationCase do
  @moduledoc """
  Shared setup helper for tests that use the ETS conversation store.
  Provides a single `setup_ets/0` function that initialises tables and wipes
  their contents for test isolation.
  """

  alias ShhAi.ConversationStore.ETS

  def setup_ets do
    ETS.init()
    :ets.delete_all_objects(:conversations)
    :ets.delete_all_objects(:conversation_mappings)
    :ets.delete_all_objects(:conversation_reverse_index)
    :ok
  end
end
