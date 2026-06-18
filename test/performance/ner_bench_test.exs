defmodule ShhAi.Performance.NERTest do
  @moduledoc """
  Performance tests for NER-based PII detection.

  Run with: mix test --only performance
  """

  use ExUnit.Case

  @moduletag :performance

  import ShhAi.Performance.Baseline, only: [run_benchmarks: 2]

  alias ShhAi.PII.Detector
  alias ShhAi.PII.NER
  alias ShhAi.TestSupport.DataGenerator

  @baseline_name "ner"

  setup do
    if NER.initialized?() do
      :ok
    else
      NER.init()
    end
  end

  describe "detector benchmarks" do
    test "detect varying text sizes" do
      small = DataGenerator.generate_text(size: :small)
      medium = DataGenerator.generate_text(size: :medium)
      large = DataGenerator.generate_text(size: :large)

      run_benchmarks(@baseline_name, %{
        "detect_small" => fn -> Detector.detect(small, []) end,
        "detect_medium" => fn -> Detector.detect(medium, []) end,
        "detect_large" => fn -> Detector.detect(large, []) end,
        "detect_regex_only" => fn ->
          Detector.detect("My email is john@example.com and phone is 555-123-4567",
            mode: :regex_only
          )
        end
      })
    end
  end

  describe "NER benchmarks" do
    test "NER detect varying text sizes" do
      small = DataGenerator.generate_text(size: :small)
      medium = DataGenerator.generate_text(size: :medium)
      large = DataGenerator.generate_text(size: :large)

      run_benchmarks(@baseline_name, %{
        "ner_detect_small" => fn -> NER.detect(small) end,
        "ner_detect_medium" => fn -> NER.detect(medium) end,
        "ner_detect_large" => fn -> NER.detect(large) end
      })
    end
  end
end
