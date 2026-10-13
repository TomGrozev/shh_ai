defmodule ShhAi.Eval.LatencyTest do
  @moduledoc """
  Detection-latency benchmark comparing the hybrid detector with NER on against
  regex-only detection, over a sample of real dataset documents.

  Excluded from the normal/CI run; run it with `mix test.eval`.
  """

  use ExUnit.Case

  @moduletag :eval
  @moduletag timeout: :infinity

  alias ShhAi.Eval.AI4Privacy
  alias ShhAi.Eval.Setup
  alias ShhAi.PII.Detector

  @sample_size 25
  @sample_seed 7

  setup_all do
    Setup.load!()
  end

  test "NER-on vs NER-off detection latency" do
    inputs =
      AI4Privacy.docs(limit: @sample_size, seed: @sample_seed)
      |> Map.new(fn doc -> {to_string(doc.id), doc.text} end)

    Benchee.run(
      %{
        "ner_on" => fn text -> Detector.detect(text) end,
        "ner_off" => fn text -> Detector.detect(text, mode: :regex_only) end
      },
      inputs: inputs,
      warmup: 2,
      time: 10,
      memory_time: 0
    )
  end
end
