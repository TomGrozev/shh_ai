defmodule ShhAi.Eval.HeldoutAccuracyTest do
  @moduledoc """
  Detection-quality benchmark against the held-out PII set (`heldout_v1.jsonl`),
  the honest, non-ai4privacy comparison to the shipped model.

  The gold spans are already in ShhAi's type space (see `ShhAi.Eval.Heldout`),
  so predictions are projected onto the types the benchmark scores — the union
  of the gold types — before `ShhAi.Eval.Scorer` runs, mirroring the AI4Privacy
  suite's projection.

  Excluded from the normal/CI run; run it with `mix test.eval`. The file is
  built by `python training/build_heldout.py`; when it is absent the test prints
  a skip notice instead of failing.
  """

  use ExUnit.Case

  @moduletag :eval
  @moduletag timeout: :infinity

  alias ShhAi.Config
  alias ShhAi.Eval.Heldout
  alias ShhAi.Eval.Scorer
  alias ShhAi.Eval.Setup
  alias ShhAi.PII.Detector

  setup_all do
    Setup.load!()
  end

  test "span+type detection quality against the held-out benchmark" do
    if Heldout.available?() do
      docs = Heldout.docs()
      types = scored_types(docs)

      scored =
        Enum.map(docs, fn doc ->
          %{gold: doc.annotations, predicted: predict(doc.text, types)}
        end)

      result = Scorer.score(scored)

      IO.puts("\n" <> render(docs, result))

      assert result.micro.tp + result.micro.fn > 0, "no gold annotations were scored"
    else
      IO.puts("""

      [skip] held-out benchmark not found at #{Heldout.path()}.
             Build it with `python training/build_heldout.py`, or point
             SHHAI_EVAL_CACHE_DIR at a directory holding heldout_v1.jsonl.
      """)
    end
  end

  # The benchmark scores the types its gold spans actually use.
  defp scored_types(docs) do
    docs
    |> Enum.flat_map(& &1.annotations)
    |> Enum.map(& &1.type)
    |> MapSet.new()
  end

  defp predict(text, types) do
    text
    |> Detector.detect(types: Config.supported_pii_types())
    |> Enum.map(&%{type: &1.type, start: &1.start_pos, end: &1.end_pos})
    |> Enum.filter(&MapSet.member?(types, &1.type))
  end

  defp render(docs, result) do
    """
    _Run: #{DateTime.utc_now() |> DateTime.to_iso8601()} · dataset: held-out v1 (heldout_v1.jsonl)_
    _(#{length(docs)} docs) · NER: on · PII types scored: #{inspect(MapSet.to_list(scored_types(docs)))}_

    **Micro** — precision #{format(result.micro.precision)},
    recall #{format(result.micro.recall)}, F1 #{format(result.micro.f1)}

    **Macro** — precision #{format(result.macro.precision)},
    recall #{format(result.macro.recall)}, F1 #{format(result.macro.f1)}

    | Type | TP | FP | FN | Precision | Recall | F1 |
    |---|---:|---:|---:|---:|---:|---:|
    #{rows(result.per_type)}
    """
  end

  defp rows(per_type) do
    per_type
    |> Enum.sort_by(fn {type, _} -> type end)
    |> Enum.map_join("\n", fn {type, m} ->
      "| #{type} | #{m.tp} | #{m.fp} | #{m.fn} | #{format(m.precision)} | #{format(m.recall)} | #{format(m.f1)} |"
    end)
  end

  defp format(value), do: :erlang.float_to_binary(value, decimals: 3)
end
