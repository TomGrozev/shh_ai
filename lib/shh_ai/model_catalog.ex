defmodule ShhAi.ModelCatalog do
  @moduledoc """
  Discovers which configured provider instance serves which model, and
  aggregates the result for the proxy's own model-listing endpoints.

  At boot and on a periodic refresh (interval from
  `ShhAi.Config.model_catalog_refresh_interval/0`) the catalog probes every
  provider instance's listing endpoint — `/v1/models` for the OpenAI and
  Anthropic dialects, `/api/tags` for Ollama — normalises each response into
  canonical (OpenAI) shape through the existing `ShhAi.ApiConverter`, and
  caches one de-duplicated union.

  The union lives in one row of a named, public ETS table this process owns:
  a cache that is rebuilt at runtime belongs in ETS, not in `:persistent_term`
  — whose own docs scope persistent terms to values "never or infrequently
  updated" and make every update a global GC across the node (ADR-0013 §2).
  Reads are lock-free and never queue behind this process' mailbox, and a
  request that arrives while the table is being rebuilt (a refresher restart)
  reads the empty catalog rather than failing.

  Reads never touch the network: `/v1/models` and `/api/tags` are rendered from
  this cache, and model-aware selection (`ShhAi.Config.select_provider/1`, #68)
  filters its pool through `provider_instances_serving/1`.

  A provider instance that is unprobed or whose probe failed **serves nothing**
  until a probe succeeds — correctness over availability (ADR-0013 §3). Boot
  never blocks on a probe.

  Provider instances are identified by the ADR-0013 composite name
  (`"openai_1"`, `"ollama_2"`), which is what a conversation pins.
  """

  use GenServer

  require Logger

  alias ShhAi.{ApiConverter, Config, ProviderClient}
  alias ShhAi.ProviderClient.HTTPTransport

  # The canonical (OpenAI) listing path. Each dialect maps it to its own
  # listing endpoint through the converter — `/api/tags` for Ollama.
  @canonical_listing_path "/v1/models"

  # One row of this table is the whole cached catalog. The table is public and
  # named, owned by the refresher: every reader — `/v1/models`, `/api/tags`,
  # model-aware selection — looks the row up directly instead of calling the
  # process. Tests start extra instances on their own `:table`.
  @table __MODULE__.Table
  @snapshot_row :snapshot

  @empty_snapshot %{
    models: [],
    provider_instances_by_model: %{}
  }

  # One canonical (OpenAI-shaped) model entry, as the source dialect's
  # converter produced it: `"id"` and `"object"` always, `"created"` and
  # `"owned_by"` only where that dialect supplies them (Ollama's tags carry
  # both; Anthropic's listing has no owned-by notion).
  @type model :: %{required(String.t()) => term()}

  # The cached catalog: the aggregated union and the model → provider-instance
  # index over it, stored as the table's one row.
  @type snapshot :: %{
          models: [model()],
          provider_instances_by_model: %{String.t() => [Config.provider_instance()]}
        }

  @doc """
  Starts the model-catalog refresher. Registered under `ShhAi.ModelCatalog`
  unless `:name` says otherwise (tests start unregistered instances), and owns
  the `ShhAi.ModelCatalog.Table` ETS table unless `:table` says otherwise.

  The first probe is scheduled, not awaited, so application boot does not
  block on any provider instance.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Refreshes every configured provider instance's catalog synchronously.

  Returns `:ok` once the cache reflects the probe results. Provider instances
  that fail to probe contribute no models and leave the rest of the catalog
  intact. Used by tests and by `/ready` (#65).

  The probes run inside the refresher process, which may hold its mailbox for
  as long as the configured per-instance timeouts allow, so callers wait
  without a timeout of their own.
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, :infinity)
  end

  @doc """
  The aggregated, de-duplicated union of every successfully probed provider
  instance's models, in canonical (OpenAI) shape, sorted by `"id"`.
  """
  @spec models() :: [model()]
  def models do
    snapshot().models
  end

  @doc """
  The canonical OpenAI model-listing body for the aggregated catalog:
  `%{"object" => "list", "data" => models()}`.

  Rendered into the caller's dialect by the controller through the source
  provider's converter.
  """
  @spec listing() :: %{String.t() => term()}
  def listing do
    %{"object" => "list", "data" => models()}
  end

  @doc """
  The ADR-0013 composite names of the configured provider instances whose last
  successful probe advertised `model_id`, e.g. `["openai_1", "ollama_1"]`.

  Returns `[]` for a model nothing serves — including while the catalog is
  still cold.
  """
  @spec provider_instances_serving(String.t()) :: [Config.provider_instance()]
  def provider_instances_serving(model_id) do
    Map.get(snapshot().provider_instances_by_model, model_id, [])
  end

  # The table is public, so a reader that arrives before the refresher has
  # created it (or while a crashed one is being restarted) sees the empty
  # catalog instead of a failing request — the same degradation the readers
  # document.
  defp snapshot do
    :ets.lookup_element(@table, @snapshot_row, 2)
  rescue
    ArgumentError -> @empty_snapshot
  end

  # ---------------------------------------------------------------------------
  # Probing
  # ---------------------------------------------------------------------------

  # Each instance is probed independently: one failure yields no models for
  # that instance and never aborts the refresh.
  defp probe_all do
    Config.providers()
    |> Enum.map(&probe/1)
  end

  defp probe({_idx, provider, config} = named_provider) do
    probe_instance(Config.provider_instance(named_provider), provider, config)
  end

  # Everything that can fail for one instance — URL and header construction as
  # well as the request — sits inside the rescue, so a malformed provider
  # configuration degrades to "this instance served nothing this round" rather
  # than crashing the refresher.
  defp probe_instance(instance, provider, config) do
    path = ApiConverter.get_target_path(@canonical_listing_path, :openai, provider)
    url = HTTPTransport.build_url(config.base_url, path)
    headers = HTTPTransport.build_headers(provider, [], config)

    case ProviderClient.http_client().do_request(:get, url, "", headers, config.timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, instance, canonical_models(provider, body, path)}

      {:ok, %{status: status}} ->
        log_probe_failure(instance, {:unexpected_status, status})
        :error

      {:error, reason} ->
        log_probe_failure(instance, reason)
        :error
    end
  rescue
    exception ->
      log_probe_failure(instance, exception)
      :error
  end

  defp canonical_models(provider, body, path) do
    case ApiConverter.get_converter(provider).to_openai_response(body, path) do
      %{"data" => models} when is_list(models) ->
        Enum.filter(models, &(is_map(&1) and is_binary(&1["id"])))

      _other ->
        []
    end
  end

  defp log_probe_failure(instance, reason) do
    Logger.error("ShhAi.ModelCatalog probe #{instance} failed: #{inspect(reason)}")
  end

  # ---------------------------------------------------------------------------
  # Snapshot
  # ---------------------------------------------------------------------------

  defp build_snapshot(results) do
    probed = for {:ok, instance, models} <- results, do: {instance, models}

    %{
      models: aggregate_models(probed),
      provider_instances_by_model: index_by_model(probed)
    }
  end

  defp aggregate_models(probed) do
    probed
    |> Enum.flat_map(fn {_instance, models} -> models end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  defp index_by_model(probed) do
    probed
    |> Enum.reduce(%{}, fn {instance, models}, acc ->
      Enum.reduce(models, acc, fn model, acc ->
        Map.update(acc, model["id"], [instance], &(&1 ++ [instance]))
      end)
    end)
    |> Map.new(fn {model_id, instances} -> {model_id, Enum.uniq(instances)} end)
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])

    # The probe runs in `handle_continue`, so `start_link/1` — and therefore
    # application boot — returns without waiting for any provider instance.
    {:ok, table, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, table) do
    publish(table)
    schedule_refresh()
    {:noreply, table}
  end

  @impl true
  def handle_call(:refresh, _from, table) do
    publish(table)
    {:reply, :ok, table}
  end

  @impl true
  def handle_info(:refresh, table) do
    publish(table)
    schedule_refresh()
    {:noreply, table}
  end

  # One insert, so readers always see either the previous catalog or the new
  # one — never a half-written index.
  defp publish(table) do
    :ets.insert(table, {@snapshot_row, build_snapshot(probe_all())})
  end

  defp schedule_refresh do
    case Config.model_catalog_refresh_interval() do
      :disabled -> :ok
      interval -> Process.send_after(self(), :refresh, interval)
    end
  end
end
