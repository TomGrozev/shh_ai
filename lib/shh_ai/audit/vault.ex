defmodule ShhAi.Audit.Vault do
  @moduledoc """
  Cloak vault for encrypting PII columns stored in the audit database
  (Audit Mode only). AES-256-GCM, with the key sourced from the
  `AUDIT_ENCRYPTION_KEY` env var (Base32-encoded) and merged into the
  cipher config in `init/1`.
  """

  use Cloak.Vault, otp_app: :shh_ai

  alias ShhAi.Config

  @impl GenServer
  def init(config) do
    key = Config.audit_encryption_key() |> Base.decode32!()

    # Inject the decoded key into the configured cipher's opts. The
    # `:ciphers` entry is a keyword list whose values are
    # `{CipherModule, opts}` tuples; we update `opts` in place.
    ciphers =
      config
      |> Keyword.fetch!(:ciphers)
      |> Keyword.new(fn {label, {cipher, opts}} ->
        {label, {cipher, Keyword.put(opts, :key, key)}}
      end)

    config = Keyword.put(config, :ciphers, ciphers)
    {:ok, config}
  end
end
