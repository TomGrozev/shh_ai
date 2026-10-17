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

    **Micro** — precision #{format(result.micro.precision)},
    recall #{format(result.micro.recall)}, F1 #{format(result.micro.f1)}

    **Macro** — precision #{format(result.macro.precision)},
    recall #{format(result.macro.recall)}, F1 #{format(result.macro.f1)}

    | Type | TP | FP | FN | Precision | Recall | F1 |
    |---|---:|---:|---:|---:|---:|---:|
    #{rows(result.per_type)}
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

  defp format(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp ner_label(true), do: "on"
  defp ner_label(_), do: "off"
end
