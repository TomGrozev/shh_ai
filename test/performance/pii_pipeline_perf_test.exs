defmodule ShhAi.Performance.PIIPipelineTest do
  @moduledoc """
  Performance tests for the PII Sanitization Pipeline.

  Run with: mix test --only performance
  """

  use ExUnit.Case

  @moduletag :performance

  alias ShhAi.TestSupport.DataGenerator
  alias ShhAi.TestSupport.Reporter
  alias ShhAi.Performance.Baseline
  alias ShhAi.PIIPipeline

  @baseline_name "pii_pipeline"

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

  describe "sanitization benchmarks" do
    test "sanitize requests" do
      small = DataGenerator.generate_request(size: :small)
      medium = DataGenerator.generate_request(size: :medium)
      large = DataGenerator.generate_request(size: :large)

      run_benchmarks(%{
        "sanitize_small" => fn -> PIIPipeline.sanitize_openai_request(small, enabled: true) end,
        "sanitize_medium" => fn -> PIIPipeline.sanitize_openai_request(medium, enabled: true) end,
        "sanitize_large" => fn -> PIIPipeline.sanitize_openai_request(large, enabled: true) end
      })
    end
  end

  describe "restoration benchmarks" do
    test "restore responses" do
      small_text = DataGenerator.generate_text(size: :small)
      medium_text = DataGenerator.generate_text(size: :medium)
      large_text = DataGenerator.generate_text(size: :large)

      small_resp = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => small_text}}]}
      medium_resp = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => medium_text}}]}
      large_resp = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => large_text}}]}

      small_mapping = %{"<EMAIL_1>" => "john@example.com"}
      medium_mapping = %{"<EMAIL_1>" => "john@example.com", "<PHONE_2>" => "555-123-4567"}
      large_mapping = %{"<EMAIL_1>" => "john@example.com", "<PHONE_2>" => "555-123-4567", "<SSN_3>" => "123-45-6789"}

      run_benchmarks(%{
        "restore_small" => fn -> PIIPipeline.restore_openai_response(small_resp, mapping: small_mapping) end,
        "restore_medium" => fn -> PIIPipeline.restore_openai_response(medium_resp, mapping: medium_mapping) end,
        "restore_large" => fn -> PIIPipeline.restore_openai_response(large_resp, mapping: large_mapping) end
      })
    end
  end

  describe "streaming restoration benchmarks" do
    test "restore stream chunks" do
      chunk1 = "data: {\"delta\":{\"content\":\"Hello <PER\"}}"
      chunk2 = "data: {\"delta\":{\"content\":\"SON_1>\"}}"
      mapping = %{"<PERSON_1>" => "John Smith"}

      run_benchmarks(%{
        "restore_stream_chunk" => fn ->
          {_, state} = PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)
          PIIPipeline.restore_stream_chunk(chunk2, state, mapping)
        end
      })
    end
  end
end
