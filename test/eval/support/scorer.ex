defmodule ShhAi.Eval.Scorer do
  @moduledoc """
  Span+type scoring for the detection benchmark.

  A predicted annotation is a true positive when it *overlaps* a gold
  annotation **and** carries the same mapped type. Matching is one-to-one and
  greedy: gold annotations are walked in order and each takes the first unused
  overlapping prediction of the same type. Leftover predictions are false
  positives, unmatched gold annotations are false negatives.

  Precision/recall/F1 are reported micro-averaged across types (the headline
  number), with a macro average over the types present as a secondary, plus the
  per-type table. A metric with a zero denominator is reported as `0.0`.
  """

  @typedoc "A span annotation in the detector's type space."
  @type annotation :: %{type: atom(), start: non_neg_integer(), end: non_neg_integer()}

  @typedoc "One scored document: its gold and predicted annotations."
  @type scored_doc :: %{gold: [annotation()], predicted: [annotation()]}

  @typedoc "Counts and derived metrics for one type (or the micro total)."
  @type metrics :: %{
          tp: non_neg_integer(),
          fp: non_neg_integer(),
          fn: non_neg_integer(),
          precision: float(),
          recall: float(),
          f1: float()
        }

  @type result :: %{
          micro: metrics(),
          macro: %{precision: float(), recall: float(), f1: float()},
          per_type: %{atom() => metrics()}
        }

  @doc """
  Scores a list of `t:scored_doc/0` maps into micro, macro and per-type metrics.
  """
  @spec score([scored_doc()]) :: result()
  def score(docs) when is_list(docs) do
    counts =
      Enum.reduce(docs, %{}, fn doc, acc ->
        {tp, fp, missed} = match_doc(doc.gold, doc.predicted)

        acc
        |> add_types(tp, :tp)
        |> add_types(fp, :fp)
        |> add_types(missed, :fn)
      end)

    per_type = Map.new(counts, fn {type, count} -> {type, metrics(count)} end)

    %{
      micro: metrics(total(counts)),
      macro: macro(per_type),
      per_type: per_type
    }
  end

  @doc """
  Whether a prediction satisfies a gold annotation (overlap + same type).
  """
  @spec matches?(annotation(), annotation()) :: boolean()
  def matches?(%{type: type, start: start_pos, end: end_pos}, %{
        type: type,
        start: gold_start,
        end: gold_end
      }) do
    start_pos < gold_end and gold_start < end_pos
  end

  def matches?(_prediction, _gold), do: false

  defp match_doc(gold, predicted) do
    {tp, missed, remaining} =
      Enum.reduce(gold, {[], [], predicted}, fn annotation, {tp, missed, avail} ->
        case take_match(avail, annotation) do
          {:ok, rest} -> {[annotation.type | tp], missed, rest}
          :error -> {tp, [annotation.type | missed], avail}
        end
      end)

    {tp, Enum.map(remaining, & &1.type), missed}
  end

  defp take_match(avail, gold) do
    case Enum.split_while(avail, fn prediction -> not matches?(prediction, gold) end) do
      {kept, [_match | rest]} -> {:ok, kept ++ rest}
      {_kept, []} -> :error
    end
  end

  defp add_types(counts, types, kind) do
    Enum.reduce(types, counts, fn type, acc ->
      Map.update(acc, type, first_count(kind), fn count ->
        Map.update!(count, kind, &(&1 + 1))
      end)
    end)
  end

  defp first_count(kind) do
    Map.update!(%{tp: 0, fp: 0, fn: 0}, kind, &(&1 + 1))
  end

  defp total(counts) do
    Enum.reduce(counts, %{tp: 0, fp: 0, fn: 0}, fn {_type, count}, acc ->
      %{tp: acc.tp + count.tp, fp: acc.fp + count.fp, fn: acc.fn + count.fn}
    end)
  end

  defp metrics(%{tp: tp, fp: fp, fn: false_negatives}) do
    precision = ratio(tp, tp + fp)
    recall = ratio(tp, tp + false_negatives)

    %{
      tp: tp,
      fp: fp,
      fn: false_negatives,
      precision: precision,
      recall: recall,
      f1: f1(precision, recall)
    }
  end

  defp macro(per_type) do
    metrics = Map.values(per_type)
    count = length(metrics)

    if count == 0 do
      %{precision: 0.0, recall: 0.0, f1: 0.0}
    else
      %{
        precision: Enum.sum(Enum.map(metrics, & &1.precision)) / count,
        recall: Enum.sum(Enum.map(metrics, & &1.recall)) / count,
        f1: Enum.sum(Enum.map(metrics, & &1.f1)) / count
      }
    end
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp f1(precision, recall) when precision == 0.0 or recall == 0.0, do: 0.0
  defp f1(precision, recall), do: 2 * precision * recall / (precision + recall)
end
