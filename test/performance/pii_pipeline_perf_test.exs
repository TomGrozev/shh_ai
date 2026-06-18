defmodule ShhAi.Performance.PIIPipelineTest do
  @moduledoc """
  Performance tests for the PII Sanitization Pipeline.

  Run with: mix test --only performance
  """

  use ExUnit.Case

  @moduletag :performance

  import ShhAi.Performance.Baseline, only: [run_benchmarks: 2]

  alias ShhAi.PII.NER
  alias ShhAi.PIIPipeline
  alias ShhAi.TestSupport.DataGenerator

  @baseline_name "pii_pipeline"

  setup do
    if NER.initialized?() do
      :ok
    else
      NER.init()
    end
  end

  test "runs all PII pipeline benchmarks" do
    # --- sanitization inputs ---
    small = DataGenerator.generate_request(size: :small)
    medium = DataGenerator.generate_request(size: :medium)
    large = DataGenerator.generate_request(size: :large)

    # --- restoration inputs ---
    small_text = DataGenerator.generate_text(size: :small)
    medium_text = DataGenerator.generate_text(size: :medium)
    large_text = DataGenerator.generate_text(size: :large)

    small_resp = %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => small_text}}]
    }

    medium_resp = %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => medium_text}}]
    }

    large_resp = %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => large_text}}]
    }

    small_mapping = %{"<EMAIL_1>" => "john@example.com"}
    medium_mapping = %{"<EMAIL_1>" => "john@example.com", "<PHONE_2>" => "555-123-4567"}

    large_mapping = %{
      "<EMAIL_1>" => "john@example.com",
      "<PHONE_2>" => "555-123-4567",
      "<SSN_3>" => "123-45-6789"
    }

    # --- streaming restoration inputs ---
    chunk1 = "data: {\"delta\":{\"content\":\"Hello <PER\"}}"
    chunk2 = "data: {\"delta\":{\"content\":\"SON_1>\"}}"
    stream_mapping = %{"<PERSON_1>" => "John Smith"}

    run_benchmarks(@baseline_name, %{
      "sanitize_small" => fn -> PIIPipeline.sanitize_openai_request(small, enabled: true) end,
      "sanitize_medium" => fn -> PIIPipeline.sanitize_openai_request(medium, enabled: true) end,
      "sanitize_large" => fn -> PIIPipeline.sanitize_openai_request(large, enabled: true) end,
      "restore_small" => fn ->
        PIIPipeline.restore_openai_response(small_resp, mapping: small_mapping)
      end,
      "restore_medium" => fn ->
        PIIPipeline.restore_openai_response(medium_resp, mapping: medium_mapping)
      end,
      "restore_large" => fn ->
        PIIPipeline.restore_openai_response(large_resp, mapping: large_mapping)
      end,
      "restore_stream_chunk" => fn ->
        {_, state} = PIIPipeline.restore_stream_chunk(chunk1, %{}, stream_mapping)
        PIIPipeline.restore_stream_chunk(chunk2, state, stream_mapping)
      end
    })
  end
end
