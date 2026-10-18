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
  for `ShhAi.Eval.Scorer`.

  ## Offsets

  `start`/`end` are Unicode codepoint (Python `str` index) half-open offsets.
  They are handed to the scorer unchanged, exactly as `ShhAi.Eval.AI4Privacy`
  passes the AI4Privacy offsets through: the scorer compares gold and predicted
  offsets numerically, and the detector's offsets are UTF-8 byte indices that
  coincide with codepoints for ASCII text.
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

  Returns a list of `%{id: term, text: String.t, annotations: [map]}`, where
  each annotation is `%{type: atom, start: non_neg_integer, end: non_neg_integer}`
  in ShhAi's PII type space. Raises `File.Error` when the file is absent; callers
  that may run without it check `available?/0` first.
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

    %{
      id: row["id"],
      text: row["text"],
      annotations: Enum.map(row["spans"] || [], &normalise_span/1)
    }
  end

  defp normalise_span(span) do
    %{type: parse_type(span["type"]), start: span["start"], end: span["end"]}
  end

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
