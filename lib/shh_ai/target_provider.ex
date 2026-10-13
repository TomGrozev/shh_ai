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

  @doc """
  Picks a retry fallback instance (issue #72, ADR-0013 §5): uniformly at
  random from the capable pool for the request's `model`, excluding every
  already-tried instance. An empty remainder — a single-backend deployment,
  or every capable instance already tried — yields
  `{:error, {:pool_exhausted, model}}`, which the controller maps to a
  distinct 503. Model-less requests fall back across the whole configured
  pool minus the tried instances.
  """
  @spec resolve_alternate(map(), [Config.provider_instance()]) ::
          {:ok, Config.named_provider()} | {:error, {:pool_exhausted, String.t() | nil}}
  def resolve_alternate(body, tried_instances) do
    case capable_pool(body) do
      {:error, {:pool_exhausted, model}} ->
        {:error, {:pool_exhausted, model}}

      {model, pool} ->
        # `tried_instances` are stable instance names (`openai_1`), while the
        # pool holds `{idx, provider, config}` tuples — compare via the
        # project's single instance-name rule.
        remainder = Enum.reject(pool, &(Config.provider_instance(&1) in tried_instances))
        pick_alternate(model, remainder)
    end
  end

  defp select_by_model(%{"model" => model} = body) when is_binary(model) do
    case capable_pool(body) do
      {:error, {:pool_exhausted, _}} -> {:error, {:model_not_served, model}}
      {_model, pool} -> {:ok, Enum.random(pool)}
    end
  end

  defp select_by_model(_body) do
    {:ok, Enum.random(configured())}
  end

  # The configured instances the model catalog reports as serving the
  # request's model, paired with the model (nil for a model-less request).
  # A model with no capable instance is exhaustion with that model attached.
  defp capable_pool(%{"model" => model} = _body) when is_binary(model) do
    serving = ModelCatalog.provider_instances_serving(model)
    pool = Enum.filter(configured(), &(Config.provider_instance(&1) in serving))

    case pool do
      [] -> {:error, {:pool_exhausted, model}}
      pool -> {model, pool}
    end
  end

  defp capable_pool(_body) do
    {nil, configured()}
  end

  defp pick_alternate(model, []), do: {:error, {:pool_exhausted, model}}

  defp pick_alternate(_model, remainder) do
    {:ok, Enum.random(remainder)}
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
