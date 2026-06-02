defmodule ShhAi.TestSupport.Reporter do
  @moduledoc """
  Formats benchmark results for CI reporting.

  Provides GitHub-flavored markdown tables and JSON artifacts for
  performance test baselines and comparisons.
  """

  @type benchmark_result :: %{
          name: String.t(),
          average: float(),
          std_dev: float()
        }

  @type baseline_data :: %{String.t() => benchmark_result()}

  @doc """
  Formats a GitHub-flavored markdown comparison table.

  ## Parameters

    * `current_results` - List of benchmark results from the current run
    * `baseline_path` - Path to the baseline JSON file (may not exist)

  ## Returns

    A markdown string with the comparison table.
  """
  @spec format_markdown_table([benchmark_result()], String.t()) :: String.t()
  def format_markdown_table(current_results, baseline_path) do
    baseline = load_baseline(baseline_path)

    header = "| Benchmark | Baseline Avg (μs) | Baseline StdDev | Current Avg (μs) | Current StdDev | % Change | Status |\n"
    separator = "|---|---|---|---|---|---|---|\n"

    rows =
      current_results
      |> Enum.map(&format_row(&1, baseline[&1.name]))
      |> Enum.join("\n")

    header <> separator <> rows <> "\n"
  end

  @doc """
  Formats benchmark results as a JSON artifact.

  ## Parameters

    * `results` - List of benchmark results

  ## Returns

    A JSON-encoded string.
  """
  @spec format_json([benchmark_result()]) :: String.t()
  def format_json(results) do
    Jason.encode!(results)
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp load_baseline(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) ->
            Map.new(list, fn %{"name" => name} = item ->
              {name, atomize_keys(item)}
            end)

          {:ok, data} when is_map(data) ->
            Map.new(data, fn {name, metrics} ->
              case metrics do
                %{"time" => time, "std_dev" => std_dev} ->
                  {name, %{average: time, std_dev: std_dev}}

                %{"time" => time} ->
                  {name, %{average: time, std_dev: 0.0}}

                _ ->
                  {name, nil}
              end
            end)

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp format_row(current, baseline) do
    name = current.name
    current_avg = format_number(current.average)
    current_std = format_number(current.std_dev)

    {baseline_avg, baseline_std, change_pct, status} =
      case baseline do
        nil ->
          {"N/A", "N/A", "N/A", "✅"}

        %{average: base_avg} ->
          change = calculate_percent_change(base_avg, current.average)
          status = status_emoji(change)
          {format_number(base_avg), format_number(baseline.std_dev), format_change(change), status}
      end

    "| #{name} | #{baseline_avg} | #{baseline_std} | #{current_avg} | #{current_std} | #{change_pct} | #{status} |"
  end

  defp calculate_percent_change(baseline, current) when baseline > 0 do
    ((current - baseline) / baseline) * 100.0
  end

  defp calculate_percent_change(_baseline, _current), do: 0.0

  defp status_emoji(change) when change < 0, do: "✅"
  defp status_emoji(change) when change < 20, do: "✅"
  defp status_emoji(change) when change <= 50, do: "⚠️"
  defp status_emoji(_change), do: "❌"

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(nil), do: "N/A"

  defp format_change(change) when change > 0 do
    "+#{format_number(change)}%"
  end

  defp format_change(change) do
    "#{format_number(change)}%"
  end
end
