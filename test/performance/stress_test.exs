defmodule ShhAi.Performance.StressTest do
  @moduledoc """
  Stress tests for PII Sanitization Pipeline with extreme data sizes.

  This suite is for **local use only** — not intended for CI.
  It allows developers to test edge cases with extreme payloads
  without slowing down the CI pipeline.

  Run with: mix test.stress

  Sizes tested:
    - :xlarge (~100KB)
    - :xxlarge (~500KB)
    - :huge (~1MB)
  """

  use ExUnit.Case

  @moduletag :stress

  alias ShhAi.PIIPipeline
  alias ShhAi.TestSupport.DataGenerator
  alias ShhAi.TestSupport.Reporter

  defp run_stress_benchmarks(benchmarks) do
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

    IO.puts(Reporter.format_terminal_table(results, "/dev/null"))
  end

  describe "stress sanitization" do
    test "sanitize extreme payload sizes" do
      xlarge = DataGenerator.generate_request(size: :xlarge)
      xxlarge = DataGenerator.generate_request(size: :xxlarge)
      huge = DataGenerator.generate_request(size: :huge)

      run_stress_benchmarks(%{
        "sanitize_xlarge" => fn -> PIIPipeline.sanitize_openai_request(xlarge, enabled: true) end,
        "sanitize_xxlarge" => fn ->
          PIIPipeline.sanitize_openai_request(xxlarge, enabled: true)
        end,
        "sanitize_huge" => fn -> PIIPipeline.sanitize_openai_request(huge, enabled: true) end
      })
    end
  end

  describe "stress restoration" do
    test "restore extreme payload sizes" do
      xlarge_text = DataGenerator.generate_text(size: :xlarge)
      xxlarge_text = DataGenerator.generate_text(size: :xxlarge)
      huge_text = DataGenerator.generate_text(size: :huge)

      xlarge_resp = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => xlarge_text}}]
      }

      xxlarge_resp = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => xxlarge_text}}]
      }

      huge_resp = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => huge_text}}]
      }

      mapping = %{
        "<EMAIL_1>" => "john@example.com",
        "<PHONE_2>" => "555-123-4567",
        "<SSN_3>" => "123-45-6789"
      }

      run_stress_benchmarks(%{
        "restore_xlarge" => fn ->
          PIIPipeline.restore_openai_response(xlarge_resp, mapping: mapping)
        end,
        "restore_xxlarge" => fn ->
          PIIPipeline.restore_openai_response(xxlarge_resp, mapping: mapping)
        end,
        "restore_huge" => fn ->
          PIIPipeline.restore_openai_response(huge_resp, mapping: mapping)
        end
      })
    end
  end
end
