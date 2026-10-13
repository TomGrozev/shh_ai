defmodule ShhAi.Eval.Setup do
  @moduledoc """
  Shared bootstrap for the `mix test.eval` benchmark suites: loads application
  config and PII patterns into `:persistent_term` and loads the NER model.

  The model load is fail-loud: an eval run that cannot load NER must not report
  a misleading NER-on accuracy, so it raises rather than skipping.
  """

  alias ShhAi.PII.NER
  alias ShhAi.PII.Patterns

  @doc """
  Prepares the runtime for an eval suite. Idempotent.

  The test environment disables NER by default (`config/test.exs`); the eval
  benchmark needs it, so it is enabled here before config is loaded.
  """
  @spec load!() :: :ok
  def load! do
    System.put_env("PII_NER_ENABLED", "true")
    ShhAi.Config.load()
    Patterns.load_into_persistent_term()
    init_ner()
  end

  defp init_ner do
    if NER.initialized?() do
      :ok
    else
      case NER.init() do
        :ok -> :ok
        {:error, reason} -> raise "NER model failed to load: #{inspect(reason)}"
      end
    end
  end
end
