defmodule ShhAi.Audit.Types.EncryptedBinary do
  @moduledoc """
  Ecto type for encrypted binary fields via `ShhAi.Audit.Vault`.

  Uses `Cloak.Ecto.Binary` under the hood, delegating encrypt/decrypt
  to the Cloak vault configured in `config/config.exs`.

  See ADR 0010.
  """

  use Cloak.Ecto.Binary, vault: ShhAi.Audit.Vault
end
