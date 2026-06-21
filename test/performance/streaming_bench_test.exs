defmodule ShhAi.Performance.StreamingTest do
  @moduledoc """
  Performance tests for streaming PII restoration.

  Run with: mix test --only performance
  """

  use ExUnit.Case

  @moduletag :performance

  import ShhAi.Performance.Baseline, only: [run_benchmarks: 2]

  alias ShhAi.PIIPipeline
  alias ShhAi.PIIPipeline.RestoreState

  @baseline_name "streaming"

  describe "streaming restoration benchmarks" do
    test "restore chunks" do
      chunk1 = "data: {\"delta\":{\"content\":\"Hello <PER\"}}"
      chunk2 = "data: {\"delta\":{\"content\":\"SON_1>\"}}"
      mapping = %{"<PERSON_1>" => "John Smith"}

      run_benchmarks(@baseline_name, %{
        "restore_single_chunk" => fn ->
          PIIPipeline.restore_stream_chunk(chunk1, RestoreState.new(), mapping)
        end,
        "restore_multiple_chunks" => fn ->
          {_, state} = PIIPipeline.restore_stream_chunk(chunk1, RestoreState.new(), mapping)
          PIIPipeline.restore_stream_chunk(chunk2, state, mapping)
        end,
        "restore_no_mapping" => fn ->
          PIIPipeline.restore_stream_chunk(chunk1, RestoreState.new(), %{})
        end
      })
    end
  end
end
