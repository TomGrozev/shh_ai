defmodule ShhAi.MeckHelper do
  @moduledoc """
  Test-only helper for `:meck` lifecycle management.

  A test's `on_exit` may run after another helper already unloaded the same
  mock, so the guard must tolerate an already-unloaded module.
  """

  @doc """
  Unloads `module` when it is currently mocked, otherwise does nothing.
  """
  @spec unload(module()) :: :ok
  def unload(module) do
    if module in :meck.mocked(), do: :meck.unload(module)
    :ok
  end
end
