defmodule ShhAi.Health do
  @moduledoc """
  Readiness decision for the orchestration probes.

  `/health` is liveness only (the endpoint answered, so the app is up);
  `/ready` asks this module whether the instance is safe to receive proxy
  traffic. The single fatal condition is NER: when `PII_NER_ENABLED` and the
  model is not loaded, an instance must not serve. Because NER load is
  boot-blocking, a live instance is normally always ready — this check is the
  guard against serving with detection silently disabled.

  The audit-DB sub-check is **non-fatal**: a read-only or locked audit volume
  degrades audit retention, not proxying, so it is reported but never flips
  readiness. See issue #65.
  """

  alias ShhAi.Audit.Writer
  alias ShhAi.Config
  alias ShhAi.PII.NER

  @typedoc """
  One sub-check's outcome: `:ok` healthy, `:error` unhealthy, or `:disabled`
  when the feature is not configured (so the check does not apply).
  """
  @type check :: :ok | :error | :disabled

  @typedoc """
  The readiness report. `ready` is the decision `/ready` renders as 200/503;
  `checks` carries the per-feature detail, including the non-fatal ones.
  """
  @type report :: %{
          ready: boolean(),
          checks: %{ner: check(), audit_db: check()}
        }

  @doc """
  Liveness: `:ok` whenever the application is running.

  The endpoint only calls this while it can serve, so it is unconditional.
  """
  @spec liveness() :: :ok
  def liveness, do: :ok

  @doc """
  Readiness report for `/ready`.

  `ready` is `false` only when `PII_NER_ENABLED` is on and the NER model is
  not loaded. `checks` reports NER and audit-DB (`:ok` / `:error` / `:disabled`).
  """
  @spec readiness() :: report()
  def readiness do
    checks = %{ner: ner_check(), audit_db: audit_db_check()}
    %{ready: checks.ner != :error, checks: checks}
  end

  # NER is fatal: an instance configured to detect PII must not serve with
  # the model unloaded. `initialized?/0` is a cheap persistent_term read.
  defp ner_check, do: check(Config.pii_ner_enabled(), &NER.initialized?/0)

  defp audit_db_check, do: check(Config.audit_mode?(), &Writer.writable?/0)

  defp check(false, _probe), do: :disabled
  defp check(true, probe), do: if(probe.(), do: :ok, else: :error)
end
