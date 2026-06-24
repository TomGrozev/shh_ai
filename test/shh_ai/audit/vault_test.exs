defmodule ShhAi.Audit.VaultTest do
  @moduledoc """
  Tests the AES-256-GCM encryption / decryption round-trip of
  `ShhAi.Audit.Vault`. Uses a real Cloak Vault initialised in
  `init/1` (no mocks) so the wiring between config, env var, and
  the cipher is exercised end-to-end.
  """

  use ExUnit.Case, async: false

  alias ShhAi.Audit.Vault
  alias ShhAi.Config

  setup do
    # Snapshot the env vars we touch so we can restore them.
    ShhAi.AuditCase.snapshot_env([
      "AUDIT_ENCRYPTION_KEY",
      "AUDIT_DB_PATH"
    ])

    :ok
  end

  describe "encrypt/decrypt round-trip" do
    test "decrypting an encrypted value returns the original plaintext" do
      key = Base.encode32(:crypto.strong_rand_bytes(32))
      System.put_env("AUDIT_ENCRYPTION_KEY", key)
      System.delete_env("AUDIT_DB_PATH")

      # Loading config exercises the env-var path; the Vault GenServer
      # is started explicitly so we have a real (non-mocked) init/1.
      Config.load()

      {:ok, _vault_pid} = start_supervised(Vault)

      plaintext = "SSN: 123-45-6789, email: alice@example.com"

      assert {:ok, ciphertext} = Vault.encrypt(plaintext, :default)
      refute ciphertext == plaintext
      assert is_binary(ciphertext)

      assert {:ok, ^plaintext} = Vault.decrypt(ciphertext)
    end
  end
end
