defmodule ShhAi.Eval.HeldoutAccuracyTest do
  @moduledoc """
  Detection-quality benchmark against the held-out PII set (`heldout_v1.jsonl`),
  the honest, non-ai4privacy comparison to the shipped model.

  The gold spans are already in ShhAi's type space (see `ShhAi.Eval.Heldout`).
  Each source is scored only on the types its gold covers
  (`ShhAi.Eval.Scorer.score_by_source/1`): TAB gold uses `name` and
  `organization` only, so its `location` and `date` mentions are neither true
  positives nor false positives, exactly as the training dev metric treats
  them. TAB `QUASI` mentions arrive as `neutral` ranges: an unmatched
  prediction there is dropped as well.

  The run prints the all-source headline plus one micro/macro block per source
  (gretel-en, gretel-finance, TAB), so a source's annotation policy cannot hide
  inside an aggregate.

  Excluded from the normal/CI run; run it with `mix test.eval`. The file is
  built by `python training/build_heldout.py`; when it is absent the test prints
  a skip notice instead of failing.
  """

  use ExUnit.Case

  @moduletag :eval
  @moduletag timeout: :infinity

  alias ShhAi.Config
  alias ShhAi.Eval.Heldout
  alias ShhAi.Eval.Report
  alias ShhAi.Eval.Scorer
  alias ShhAi.Eval.Setup
  alias ShhAi.PII.Detector

  setup_all do
    Setup.load!()
  end

  test "span+type detection quality against the held-out benchmark" do
    if Heldout.available?() do
      docs = Heldout.docs()

      scored =
        Enum.map(docs, fn doc ->
          %{
            source: doc.source,
            gold: doc.annotations,
            predicted: predict(doc.text),
            neutral: doc.neutral
          }
        end)

      {result, per_source_results} = Scorer.score_by_source(scored)

      meta = [
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        dataset: "held-out v1 (heldout_v1.jsonl)",
        docs: length(docs),
        ner: true,
        types: "per source (each source's gold types)"
      ]

      counts = Enum.frequencies_by(docs, & &1.source)

      per_source =
        per_source_results
        |> Enum.sort_by(fn {source, _result} -> source end)
        |> Enum.map(fn {source, source_result} -> {source, counts[source], source_result} end)

      IO.puts("\n" <> Report.render_heldout(result, per_source, meta))

      assert result.micro.tp + result.micro.fn > 0, "no gold annotations were scored"
    else
      IO.puts("""

      [skip] held-out benchmark not found at #{Heldout.path()}.
             Build it with `python training/build_heldout.py`, or point
             SHHAI_EVAL_CACHE_DIR at a directory holding heldout_v1.jsonl.
      """)
    end
  end

  defp predict(text) do
    text
    |> Detector.detect(types: Config.supported_pii_types())
    |> Enum.map(&%{type: &1.type, start: &1.start_pos, end: &1.end_pos})
  end
end
