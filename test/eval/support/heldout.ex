defmodule ShhAi.Eval.Heldout do
  @moduledoc """
  Loads the held-out PII benchmark (`heldout_v1.jsonl`) for the detection
  benchmark.

  Unlike the AI4Privacy suite, the held-out set is not a public dataset: it is
  built reproducibly (seeded, licensed for commercial use, disjoint from
  ai4privacy) by `python training/build_heldout.py` and cached beside the
  AI4Privacy dataset. Each JSONL line is already in ShhAi's own type space
  (contract item 2):

      {"id": "...", "text": "...",
       "spans": [{"start": 0, "end": 4, "type": "name"}], "source": "..."}

  `docs/0` parses those lines into the same `%{id, text, annotations}` shape the
  AI4Privacy loader returns, with `annotations` as `%{type, start, end}` ready
  for `ShhAi.Eval.Scorer`. The keys `source` and `neutral` travel alongside:
  `neutral` is a list of `{start, end}` ranges the source marks as
  context-dependent identifiers (TAB `QUASI` mentions), where an unmatched
  prediction is neither a true positive nor a false positive.

  ## Offsets

  `start`/`end` are Unicode codepoint (Python `str` index) half-open offsets.
  `parse_line/1` converts them to UTF-8 byte offsets, the unit of the
  detector's `start_pos`/`end_pos`, so the scorer compares like with like on
  non-ASCII text.
  """

  alias ShhAi.Eval.AI4Privacy

  @filename "heldout_v1.jsonl"

  @doc """
  The path the held-out benchmark is read from.

  Defaults to `$SHHAI_EVAL_CACHE_DIR/heldout_v1.jsonl` (or
  `~/.cache/shh_ai/eval/heldout_v1.jsonl`). The AI4Privacy cache directory is
  reused so both benchmarks agree on `SHHAI_EVAL_CACHE_DIR`.
  """
  @spec path() :: String.t()
  def path, do: Path.join(AI4Privacy.cache_dir(), @filename)

  @doc """
  Whether the held-out benchmark file is present and non-empty.
  """
  @spec available?() :: boolean()
  def available? do
    case File.stat(path()) do
      {:ok, %{size: size}} -> size > 0
      _ -> false
    end
  end

  @doc """
  Loads the held-out benchmark documents.

  Returns a list of `%{id: term, text: String.t(), annotations: [map]}` maps,
  where each annotation is
  `%{type: atom, start: non_neg_integer, end: non_neg_integer}` in ShhAi's PII
  type space, plus `source: String.t` (the dataset repo) and
  `neutral: [{start, end}]` (ranges that are not scored). Raises `File.Error`
  when the file is absent; callers that may run without it check
  `available?/0` first.
  """
  @spec docs() :: [map()]
  def docs do
    path()
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&parse_line/1)
  end

  @doc """
  Parses one JSONL line into a document map.
  """
  @spec parse_line(String.t()) :: map()
  def parse_line(line) do
    row = Jason.decode!(line)
    text = row["text"]
    to_byte = byte_offsets(text)

    %{
      id: row["id"],
      text: text,
      source: row["source"] || "",
      annotations: Enum.map(row["spans"] || [], &normalise_span(&1, to_byte)),
      neutral: Enum.map(row["neutral"] || [], &normalise_range(&1, to_byte))
    }
  end

  # The JSONL offsets are Python `str` indices (codepoints), but detections
  # carry UTF-8 byte offsets (`ShhAi.PII.NER`). Without this conversion every
  # non-ASCII document is scored against shifted gold. The tuple maps a
  # codepoint index to its byte offset; the extra last entry covers `end`.
  defp byte_offsets(text) do
    text
    |> String.codepoints()
    |> Enum.scan(0, &(byte_size(&1) + &2))
    |> then(&List.to_tuple([0 | &1]))
  end

  defp normalise_span(span, to_byte) do
    %{
      type: parse_type(span["type"]),
      start: elem(to_byte, span["start"]),
      end: elem(to_byte, span["end"])
    }
  end

  # Neutral ranges are offset pairs, not typed spans: the source says nothing
  # about which type a hit there should carry, only that a hit is allowed.
  defp normalise_range([start_pos, end_pos], to_byte),
    do: {elem(to_byte, start_pos), elem(to_byte, end_pos)}

  defp normalise_range(other, _to_byte),
    do: raise(ArgumentError, "invalid neutral range #{inspect(other)}")

  # Span types are lowercase names of `ShhAi.Config.supported_pii_types/0`; an
  # unknown name is a build-script bug, so raise rather than silently drop the
  # annotation (which would understate the gold set).
  defp parse_type(name) do
    case Enum.find(ShhAi.Config.supported_pii_types(), &(Atom.to_string(&1) == name)) do
      nil ->
        raise ArgumentError,
              "invalid held-out span type #{inspect(name)}; expected a supported PII type name"

      type ->
        type
    end
  end
end
