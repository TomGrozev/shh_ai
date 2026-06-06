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

  alias ShhAi.TestSupport.Reporter

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

    if File.regular?(local_path) do
      case File.read(local_path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, data} when is_map(data) -> {:ok, data}
            _ -> {:error, :not_found}
          end

        {:error, _} ->
          {:error, :not_found}
      end
    else
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

    # Merge with existing baseline if it exists (deep merge to preserve
    # nested metric keys such as "std_dev" when the new data only updates
    # a subset like "time").
    merged =
      case load_baseline(name) do
        {:ok, existing} -> deep_merge(existing, data)
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
          not is_nil(cur),
          valid_metric_pair?(base, cur, metric_key),
          diff <- compute_diff(name, base, cur, metric_key, minor) do
        diff
      end
      |> Enum.sort_by(&elem(&1, 3), :desc)

    classify_result(diffs, major)
  end

  @doc """
  Runs a benchmark and formats the results
  """
  @spec run_benchmarks(String.t(), map()) :: :ok
  def run_benchmarks(baseline_name, benchmarks) do
    baseline =
      case load_baseline(baseline_name) do
        {:ok, data} -> data
        {:error, :not_found} -> %{}
      end

    suite =
      Benchee.run(
        benchmarks,
        time: 5,
        formatters: [Benchee.Formatters.Console]
      )

    results =
      suite.scenarios
      |> Enum.map(fn scenario ->
        stats = scenario.run_time_data.statistics

        %{
          name: scenario.name,
          average: stats.average,
          std_dev: stats.std_dev
        }
      end)

    baseline_path = Path.join(".perf/baselines", baseline_name <> ".json")
    IO.puts(Reporter.format_terminal_table(results, baseline_path))

    current_map =
      Map.new(results, fn r -> {r.name, %{"time" => r.average, "std_dev" => r.std_dev}} end)

    baseline_map = Map.new(baseline, fn {k, v} -> {k, v} end)

    case compare(current_map, baseline_map) do
      :ok ->
        save_baseline(baseline_name, current_map)
        :ok

      {:warn, diffs} ->
        IO.puts("#{Reporter.status_label(:warn)} Minor regressions detected:")

        Enum.each(diffs, fn {name, base, cur, pct} ->
          IO.puts("  #{name}: #{base} -> #{cur} (+#{pct}%)")
        end)

        save_baseline(baseline_name, current_map)

      {:fail, diffs} ->
        IO.puts("#{Reporter.status_label(:fail)} Major regressions detected:")

        Enum.each(diffs, fn {name, base, cur, pct} ->
          IO.puts("  #{name}: #{base} -> #{cur} (+#{pct}%)")
        end)

        # DON'T save baseline on major regression
        System.halt(1)
    end
  end

  # Private helpers

  defp local_dir do
    Application.get_env(:shh_ai, :baseline_dir, @default_local_dir)
  end

  defp metric_value(%{} = map, key) when is_binary(key) do
    case Map.get(map, key) do
      val when is_number(val) -> val
      _ -> nil
    end
  end

  defp metric_value(value, _key) when is_number(value), do: value
  defp metric_value(_, _), do: nil

  # Validates that both baseline and current entries have compatible structure
  # (both maps with the metric key, or both plain numbers) before comparing.
  defp valid_metric_pair?(%{} = base, %{} = cur, metric_key) do
    is_number(Map.get(base, metric_key)) and is_number(Map.get(cur, metric_key))
  end

  defp valid_metric_pair?(base, cur, _metric_key) do
    is_number(base) and is_number(cur)
  end

  # Deep-merge two maps recursively; for non-map values the right side wins.
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, v1, v2 -> deep_merge(v1, v2) end)
  end

  defp deep_merge(_left, right), do: right

  # Computes a single diff tuple for one (baseline, current) pair, or returns
  # `[]` to indicate this entry should be skipped (non-numeric values, zero
  # baseline, or change within the minor threshold).
  defp compute_diff(name, base, cur, metric_key, minor) do
    base_val = metric_value(base, metric_key)
    cur_val = metric_value(cur, metric_key)

    with true <- is_number(base_val) and is_number(cur_val) and base_val != 0,
         pct_change = (cur_val - base_val) / base_val,
         true <- pct_change > minor do
      [{name, base_val, cur_val, Float.round(pct_change * 100, 2)}]
    else
      _ -> []
    end
  end

  # Classifies a sorted diffs list as :ok / {:warn, diffs} / {:fail, diffs}
  # based on the major threshold.
  defp classify_result([], _major), do: :ok

  defp classify_result(diffs, major) do
    if Enum.any?(diffs, fn {_, _, _, pct} -> pct > major * 100 end) do
      {:fail, diffs}
    else
      {:warn, diffs}
    end
  end
end
