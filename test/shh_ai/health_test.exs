defmodule ShhAi.HealthTest do
  @moduledoc """
  Unit tests for `ShhAi.Health` — the readiness decision backing `/ready`.

  The NER sub-check is the only fatal one; the audit-DB sub-check is
  reported but never flips `ready`. These tests exercise the decision at its
  public seam (`liveness/0`, `readiness/0`) by driving the two feature flags
  and the two probe functions the report depends on.
  """

  use ExUnit.Case, async: false
  use ShhAi.AuditCase

  alias ShhAi.Config
  alias ShhAi.Health

  describe "liveness/0" do
    test "is always :ok while the app is up" do
      assert Health.liveness() == :ok
    end
  end

  describe "readiness/0" do
    test "is ready with both features disabled (test defaults)" do
      assert %{ready: true, checks: %{ner: :disabled, audit_db: :disabled}} = Health.readiness()
    end

    test "is ready when NER is enabled and initialized" do
      stub_probes(ner_enabled: true, initialized: true)

      assert %{ready: true, checks: %{ner: :ok}} = Health.readiness()
    end

    test "is not ready when NER is enabled and not initialized" do
      stub_probes(ner_enabled: true, initialized: false)

      assert %{ready: false, checks: %{ner: :error}} = Health.readiness()
    end

    test "stays ready when the audit DB is unwritable (non-fatal)" do
      stub_probes(audit_enabled: true, audit_writable: false)

      assert %{ready: true, checks: %{audit_db: :error}} = Health.readiness()
    end

    test "reports the audit DB as :ok when it accepts writes" do
      stub_probes(audit_enabled: true, audit_writable: true)

      assert %{ready: true, checks: %{audit_db: :ok}} = Health.readiness()
    end
  end

  # Drives both readiness probes at their seams without mocking `ShhAi.Config`:
  # NER is configured through the environment (the real config path) with its
  # model load mocked to succeed and `initialized?` mocked to the requested
  # value; the audit probe is mocked directly. `stub_probes/1` is only called
  # by tests that need a feature enabled, so the defaults cover the rest.
  defp stub_probes(opts) do
    ShhAi.AuditCase.snapshot_env(["PII_NER_ENABLED", "AUDIT_MODE", "AUDIT_ENCRYPTION_KEY"])

    :meck.new(ShhAi.PII.NER, [:passthrough])
    on_exit(fn -> :meck.unload() end)
    :meck.expect(ShhAi.PII.NER, :init, fn -> :ok end)

    System.put_env("PII_NER_ENABLED", to_string(Keyword.get(opts, :ner_enabled, false)))
    System.put_env("AUDIT_MODE", to_string(Keyword.get(opts, :audit_enabled, false)))
    System.put_env("AUDIT_ENCRYPTION_KEY", Base.encode32(:crypto.strong_rand_bytes(32)))
    Config.load()

    if Keyword.has_key?(opts, :initialized) do
      initialized = Keyword.fetch!(opts, :initialized)
      :meck.expect(ShhAi.PII.NER, :initialized?, fn -> initialized end)
    end

    if Keyword.has_key?(opts, :audit_writable) do
      writable = Keyword.fetch!(opts, :audit_writable)
      :meck.new(ShhAi.Audit.Writer, [:passthrough])
      :meck.expect(ShhAi.Audit.Writer, :writable?, fn -> writable end)
    end
  end
end
