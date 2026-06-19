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
end
