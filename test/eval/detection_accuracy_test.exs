defmodule ShhAi.Eval.DetectionAccuracyTest do
  @moduledoc """
  Detection-quality benchmark: scores ShhAi's detector against a seeded subset
  of the AI4Privacy `pii-masking-200k` dataset using span+type matching.

  The detector runs with **every** supported PII type enabled
  (`ShhAi.Config.supported_pii_types/0`), not the product default allow-list,
  so the score reflects the detector's full capability (`:date`, `:age`,
  `:organization` and `:title` included).

  Excluded from the normal/CI run; run it with `mix test.eval`. Results are
  published into the `eval:accuracy` block of `docs/benchmarks.md`.
  """

  use ExUnit.Case

  @moduletag :eval
  @moduletag timeout: :infinity

  alias ShhAi.Config
  alias ShhAi.Eval.AI4Privacy
  alias ShhAi.Eval.Report
  alias ShhAi.Eval.Scorer
  alias ShhAi.Eval.Setup
  alias ShhAi.PII.Detector

  @subset_size 5_000
  @seed 42

  setup_all do
    Setup.load!()
  end

  test "span+type detection quality against the seeded AI4Privacy subset" do
    docs = AI4Privacy.docs(limit: @subset_size, seed: @seed)

    scored =
      Enum.map(docs, fn doc ->
        %{gold: AI4Privacy.map_annotations(doc.annotations), predicted: predict(doc.text)}
      end)

    result = Scorer.score(scored)

    meta = [
      docs: length(docs),
      seed: @seed,
      ner: true,
      types: length(Config.supported_pii_types()),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    ]

    IO.puts("\n" <> Report.render_accuracy(result, meta))
    :ok = Report.publish_accuracy(result, meta)

    assert result.micro.tp + result.micro.fn > 0, "no gold annotations were scored"
  end

  # Predictions are projected onto the mapped type set so the detector is not
  # penalised for types the benchmark does not score.
  defp predict(text) do
    types = AI4Privacy.mapped_types()

    text
    |> Detector.detect(types: Config.supported_pii_types())
    |> Enum.map(&%{type: &1.type, start: &1.start_pos, end: &1.end_pos})
    |> Enum.filter(&MapSet.member?(types, &1.type))
  end
end
