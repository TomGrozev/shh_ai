defmodule ShhAi.Performance.StreamingTest do
  @moduledoc """
  Performance tests for streaming PII restoration.

  Run with: mix test --only performance
  """

  use ExUnit.Case

  @moduletag :performance

  alias ShhAi.TestSupport.DataGenerator
  alias ShhAi.TestSupport.Reporter
  alias ShhAi.Performance.Baseline
  alias ShhAi.PIIPipeline

  @baseline_name "streaming"

  defp run_benchmarks(benchmarks) do
    baseline =
      case Baseline.load_baseline(@baseline_name) do
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

    baseline_path = Path.join(".perf/baselines", @baseline_name <> ".json")
    IO.puts(Reporter.format_markdown_table(results, baseline_path))

    current_map = Map.new(results, fn r -> {r.name, %{"time" => r.average, "std_dev" => r.std_dev}} end)
    baseline_map = Map.new(baseline, fn {k, v} -> {k, v} end)

    case Baseline.compare(current_map, baseline_map) do
      :ok ->
        Baseline.save_baseline(@baseline_name, current_map)
        :ok

      {:warn, diffs} ->
        IO.puts("⚠️  Minor regressions detected:")
        Enum.each(diffs, fn {name, base, cur, pct} ->
          IO.puts("  #{name}: #{base} -> #{cur} (+#{pct}%)")
        end)

        Baseline.save_baseline(@baseline_name, current_map)

      {:fail, diffs} ->
        IO.puts("❌ Major regressions detected:")
        Enum.each(diffs, fn {name, base, cur, pct} ->
          IO.puts("  #{name}: #{base} -> #{cur} (+#{pct}%)")
        end)

        # DON'T save baseline on major regression
        System.halt(1)
    end
  end

  describe "streaming restoration benchmarks" do
    test "restore chunks" do
      chunk1 = "data: {\"delta\":{\"content\":\"Hello <PER\"}}"
      chunk2 = "data: {\"delta\":{\"content\":\"SON_1>\"}}"
      mapping = %{"<PERSON_1>" => "John Smith"}

      run_benchmarks(%{
        "restore_single_chunk" => fn ->
          PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)
        end,
        "restore_multiple_chunks" => fn ->
          {_, state} = PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)
          PIIPipeline.restore_stream_chunk(chunk2, state, mapping)
        end,
        "restore_no_mapping" => fn ->
          PIIPipeline.restore_stream_chunk(chunk1, %{}, %{})
        end
      })
    end
  end
end
