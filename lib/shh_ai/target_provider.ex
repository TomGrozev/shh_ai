defmodule ShhAi.TargetProvider do
  @moduledoc """
  Chooses the Provider Instance that serves a request — the Target Provider
  (ADR-0013 §2).

  The single home for that rule: `ShhAi.ProviderClient` asks here, and
  `ShhAi.Config` stays settings-only.
  """

  alias ShhAi.{Config, Conversation, ModelCatalog}

  @doc """
  Resolves the effective Target Provider instance for a turn (ADR-0013 §2): the
  conversation's pin when it still resolves in the current config, else
  model-aware selection on the request's `model`. A pinned instance that is
  gone from config re-selects — pinning is keyed on the stable instance name,
  and a stale name is a permanent (not transient) condition.

  Model-aware selection filters the configured pool through the catalog's probe
  results. An instance the catalog does not list serves nothing until a probe
  succeeds, so a model no configured instance serves yields
  `{:error, {:model_not_served, model}}` rather than falling back to an
  arbitrary provider instance (ADR-0013 §3).

  A request that carries no `model` to filter on — e.g. `GET /v1/models/{id}`
  or Ollama's `GET /api/version` — is still forwarded to a provider instance
  but cannot be model-matched (ADR-0013 §3 concerns requests *for* a model), so
  any configured instance is picked uniformly at random.
  """
  @spec resolve(Conversation.t(), map()) ::
          {:ok, Config.named_provider()} | {:error, {:model_not_served, String.t()}}
  def resolve(%Conversation{pinned_provider: pinned}, body) when is_binary(pinned) do
    case Enum.find(configured(), &(Config.provider_instance(&1) == pinned)) do
      nil -> select_by_model(body)
      provider -> {:ok, provider}
    end
  end

  def resolve(%Conversation{}, body) do
    select_by_model(body)
  end

  defp select_by_model(%{"model" => model}) when is_binary(model) do
    serving = ModelCatalog.provider_instances_serving(model)

    case Enum.filter(configured(), &(Config.provider_instance(&1) in serving)) do
      [] -> {:error, {:model_not_served, model}}
      pool -> {:ok, Enum.random(pool)}
    end
  end

  defp select_by_model(_body) do
    {:ok, Enum.random(configured())}
  end

  defp configured do
    case Config.providers() do
      [] ->
        raise ArgumentError,
              "No providers configured. Set at least one PROVIDER_{TYPE}_{IDX}_ENABLED=true environment variable."

      providers ->
        providers
    end
  end
end
