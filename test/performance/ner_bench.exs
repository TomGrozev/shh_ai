defmodule ShhAi.Performance.NERTest do
  @moduledoc """
  Performance tests for NER-based PII detection.

  Run with: mix test --only performance
  """

  use ExUnit.Case

  @moduletag :performance

  alias ShhAi.TestSupport.DataGenerator
  alias ShhAi.TestSupport.Reporter
  alias ShhAi.Performance.Baseline
  alias ShhAi.PII.Detector
  alias ShhAi.PII.NER

  @baseline_name "ner"

  # Guard: skip tests if NER not initialized
  setup do
    if NER.initialized?() do
      :ok
    else
      {:skip, "NER model not initialized"}
    end
  end

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

  describe "detector benchmarks" do
    test "detect varying text sizes" do
      small = DataGenerator.generate_text(size: :small)
      medium = DataGenerator.generate_text(size: :medium)
      large = DataGenerator.generate_text(size: :large)

      run_benchmarks(%{
        "detect_small" => fn -> Detector.detect(small, []) end,
        "detect_medium" => fn -> Detector.detect(medium, []) end,
        "detect_large" => fn -> Detector.detect(large, []) end,
        "detect_regex_only" => fn ->
          Detector.detect("My email is john@example.com and phone is 555-123-4567", mode: :regex_only)
        end
      })
    end
  end

  describe "NER benchmarks" do
    test "NER detect varying text sizes" do
      small = DataGenerator.generate_text(size: :small)
      medium = DataGenerator.generate_text(size: :medium)
      large = DataGenerator.generate_text(size: :large)

      run_benchmarks(%{
        "ner_detect_small" => fn -> NER.detect(small) end,
        "ner_detect_medium" => fn -> NER.detect(medium) end,
        "ner_detect_large" => fn -> NER.detect(large) end
      })
    end
  end
end
