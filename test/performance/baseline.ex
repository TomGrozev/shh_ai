defmodule ShhAi.Performance.Baseline do
  @moduledoc """
  Baseline storage and comparison for performance benchmarks.

  Provides functions to:
  - Load baseline results from local `.perf/baselines/` or a CI artifact location
  - Save current benchmark results as a new baseline
  - Compare current results against a baseline with configurable thresholds

  ## Thresholds

  - Major regression: > 50% slowdown → `{:fail, diffs}`
  - Minor regression: 20–50% slowdown → `{:warn, diffs}`
  - Otherwise (improvement or < 20% change) → `:ok`

  Thresholds are configurable via `opts` passed to `compare/3`.

  ## Storage

  - **Local**: `.perf/baselines/` directory (gitignored)
  - **CI**: artifact storage (implementation deferred to CI workflow issue)
  """

  @default_local_dir ".perf/baselines"
  @default_major_threshold 0.50
  @default_minor_threshold 0.20

  @doc """
  Loads a baseline by name.

  Checks the local `.perf/baselines/` directory first, then falls back to
  the CI artifact location if configured via the `baseline_dir` application
  environment.

  Returns `{:ok, data}` on success or `{:error, :not_found}` if the baseline
  does not exist.
  """
  @spec load_baseline(String.t()) :: {:ok, map()} | {:error, :not_found}
  def load_baseline(name) do
    # Try local path first
    local_path = Path.join(local_dir(), name <> ".json")

    cond do
      File.regular?(local_path) ->
        case File.read(local_path) do
          {:ok, contents} ->
            case Jason.decode(contents) do
              {:ok, data} when is_map(data) -> {:ok, data}
              {:ok, _} -> {:error, :not_found}
              {:error, _} -> {:error, :not_found}
            end

          {:error, _} ->
            {:error, :not_found}
        end

      true ->
        # TODO: Fall back to CI artifact storage when implemented.
        {:error, :not_found}
    end
  end

  @doc """
  Saves `data` as the baseline named `name`.

  Creates the `.perf/baselines/` directory (and any intermediates) if needed.
  Writes the data as pretty-printed JSON.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec save_baseline(String.t(), map()) :: :ok | {:error, File.posix() | term()}
  def save_baseline(name, data) do
    dir = local_dir()
    :ok = File.mkdir_p!(dir)
    path = Path.join(dir, name <> ".json")

    # Merge with existing baseline if it exists
    merged =
      case load_baseline(name) do
        {:ok, existing} -> Map.merge(existing, data)
        {:error, :not_found} -> data
      end

    case Jason.encode(merged, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compares `current` results against `baseline` with configurable thresholds.

  Both `current` and `baseline` are maps of `name => metric` where `metric`
  is a map containing at minimum a `"time"` key (or the key configured via
  `:metric_key`).

  ## Options

    * `:metric_key` - the key used to extract the numeric value for each
      benchmark entry (default `"time"`)
    * `:minor_threshold` - fraction representing minor regression threshold
      (default `0.20`)
    * `:major_threshold` - fraction representing major regression threshold
      (default `0.50`)

  ## Returns

    * `:ok` - no regression or improvement
    * `{:warn, diffs}` - one or more metrics regressed between the minor and
      major thresholds
    * `{:fail, diffs}` - one or more metrics regressed beyond the major
      threshold

  `diffs` is a list of tuples `{name, baseline_value, current_value, pct_change}`
  for every regressed metric, sorted by percentage change descending.
  """
  @type diff :: {String.t(), number(), number(), float()}

  @spec compare(map(), map(), keyword()) :: :ok | {:warn, [diff()]} | {:fail, [diff()]}
  def compare(current, baseline, opts \\ []) do
    metric_key = Keyword.get(opts, :metric_key, "time")
    minor = Keyword.get(opts, :minor_threshold, @default_minor_threshold)
    major = Keyword.get(opts, :major_threshold, @default_major_threshold)

    diffs =
      for {name, base} <- baseline,
          cur = current[name],
          not is_nil(cur) do
        base_val = metric_value(base, metric_key)
        cur_val = metric_value(cur, metric_key)

        if base_val == 0 or is_nil(base_val) or is_nil(cur_val) do
          nil
        else
          pct_change = (cur_val - base_val) / base_val

          if pct_change > minor do
            {name, base_val, cur_val, Float.round(pct_change * 100, 2)}
          else
            nil
          end
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_, _, _, pct} -> pct end, :desc)

    cond do
      Enum.any?(diffs, fn {_, _, _, pct} -> pct > major * 100 end) -> {:fail, diffs}
      diffs != [] -> {:warn, diffs}
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp local_dir do
    Application.get_env(:shh_ai, :baseline_dir, @default_local_dir)
  end

  defp metric_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key)
  end

  defp metric_value(value, _key), do: value
end
