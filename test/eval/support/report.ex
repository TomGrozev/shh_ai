defmodule ShhAi.Eval.Report do
  @moduledoc """
  Renders benchmark results as Markdown and publishes them into
  `docs/benchmarks.md`.

  The standing document carries an `eval:accuracy` block delimited by HTML
  comment markers; `publish_accuracy/3` replaces exactly that block, so a run
  refreshes the numbers without touching the hand-written methodology and
  comparator sections around it.
  """

  @start_marker "<!-- eval:accuracy:start -->"
  @end_marker "<!-- eval:accuracy:end -->"
  @default_path "docs/benchmarks.md"

  @doc """
  Renders an accuracy result as a Markdown block.

  `meta` carries `:docs` (subset size), `:seed`, `:ner` (boolean),
  `:types` (count of PII types enabled) and `:timestamp` (a display string).
  """
  @spec render_accuracy(ShhAi.Eval.Scorer.result(), keyword()) :: String.t()
  def render_accuracy(result, meta) do
    """
    _Run: #{meta[:timestamp]} · dataset: AI4Privacy pii-masking-200k_
    _(#{meta[:docs]} docs, seed #{meta[:seed]}) · NER: #{ner_label(meta[:ner])} · PII types: all #{meta[:types]} supported_

    #{metric_lines(result)}
    | Type | TP | FP | FN | Precision | Recall | F1 |
    |---|---:|---:|---:|---:|---:|---:|
    #{rows(result.per_type)}
    """
  end

  @doc """
  Renders a held-out benchmark result: the all-source headline, the per-type
  table, and one micro/macro block per source.

  `per_source` is `[{source, docs, result}]`, where `source` is the dataset
  repo id as it appears in the JSONL and `docs` the number of documents scored
  for it. The per-source blocks share the headline's metric layout, so a
  regression in one source is visible without rerunning the suite per source.
  """
  @spec render_heldout(
          ShhAi.Eval.Scorer.result(),
          [{String.t(), non_neg_integer(), ShhAi.Eval.Scorer.result()}],
          keyword()
        ) :: String.t()
  def render_heldout(result, per_source, meta) do
    """
    _Run: #{meta[:timestamp]} · dataset: #{meta[:dataset]}_
    _(#{meta[:docs]} docs) · NER: #{ner_label(meta[:ner])} · PII types scored: #{meta[:types]}_

    #{metric_lines(result)}
    | Type | TP | FP | FN | Precision | Recall | F1 |
    |---|---:|---:|---:|---:|---:|---:|
    #{rows(result.per_type)}

    #{source_blocks(per_source)}
    """
  end

  @doc """
  Replaces the `eval:accuracy` block in `path` with the rendered result.
  """
  @spec publish_accuracy(ShhAi.Eval.Scorer.result(), keyword(), String.t()) :: :ok
  def publish_accuracy(result, meta, path \\ @default_path) do
    document = File.read!(path)

    unless String.contains?(document, @start_marker) and String.contains?(document, @end_marker) do
      raise "docs/benchmarks.md is missing the #{@start_marker} / #{@end_marker} markers"
    end

    [before, rest] = String.split(document, @start_marker, parts: 2)
    [_stale, after_block] = String.split(rest, @end_marker, parts: 2)

    block = "\n" <> render_accuracy(result, meta) <> "\n"

    File.write!(path, before <> @start_marker <> block <> @end_marker <> after_block)
  end

  defp rows(per_type) do
    per_type
    |> Enum.sort_by(fn {type, _} -> type end)
    |> Enum.map_join("\n", fn {type, m} ->
      "| #{type} | #{m.tp} | #{m.fp} | #{m.fn} | #{format(m.precision)} | #{format(m.recall)} | #{format(m.f1)} |"
    end)
  end

  defp metric_lines(result) do
    """
    **Micro** — precision #{format(result.micro.precision)},
    recall #{format(result.micro.recall)}, F1 #{format(result.micro.f1)}

    **Macro** — precision #{format(result.macro.precision)},
    recall #{format(result.macro.recall)}, F1 #{format(result.macro.f1)}
    """
  end

  defp source_blocks(per_source) do
    per_source
    |> Enum.sort_by(fn {source, _docs, _result} -> source end)
    |> Enum.map_join("\n", fn {source, docs, result} ->
      "### #{source_label(source)} (#{docs} docs)\n\n#{metric_lines(result)}"
    end)
  end

  # Short names for the held-out sources; an unknown source keeps its repo id.
  defp source_label("gretelai/gretel-pii-masking-en-v1"), do: "gretel-en"
  defp source_label("gretelai/synthetic_pii_finance_multilingual"), do: "gretel-finance"
  defp source_label("ildpil/text-anonymization-benchmark"), do: "TAB (ECHR)"
  defp source_label(source), do: source

  defp format(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp ner_label(true), do: "on"
  defp ner_label(_), do: "off"
end
