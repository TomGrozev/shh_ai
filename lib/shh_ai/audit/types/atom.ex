defmodule ShhAi.Audit.Types.Atom do
  @moduledoc """
  Ecto type for atom fields persisted as TEXT.

  Ecto ships no built-in atom type, and `:string` rejects atoms
  (`Ecto.Type.cast(:string, :post)` is `:error`) — which silently
  invalidated the audit `method` changeset and dropped every event. This
  type keeps the in-memory value an atom while dumping and loading it as
  its string form, so an existing TEXT column needs no migration.

  See ADR 0010.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(value) when is_atom(value), do: {:ok, value}
  def cast(_), do: :error

  @impl true
  def dump(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def dump(_), do: :error

  @impl true
  def load(value) when is_binary(value), do: {:ok, String.to_existing_atom(value)}
  def load(_), do: :error
end
