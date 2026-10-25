defmodule ShhAi.PII.Detector do
  @moduledoc """
  PII detection engine that identifies personally identifiable information in text.
  Uses a hybrid approach combining regex patterns and NER model for optimal detection.

  ## Detection Process

  1. Load compiled patterns from :persistent_term
  2. Scan text for regex pattern matches (fast)
  3. Optionally run NER model for context-aware detection (accurate)
  4. Merge and deduplicate results
  5. Filter by confidence threshold
  6. Return list of detections with positions and types

  ## Hybrid Detection

  The detector supports three modes (configured via PII_HYBRID_MODE env var):

  - `:complementary` (default) - Run both regex and NER, merge results
  - `:ner_only` - Use only NER model detection
  - `:regex_only` - Use only regex pattern detection

  ## Performance

  - Regex patterns are pre-compiled and stored in :persistent_term
  - Binary pattern matching for fast scanning
  - NER model uses Bumblebee with EXLA backend for optimized inference
  - NER runs over the whole text in overlapping windows, so large texts are
    detected end to end without caller-side chunking
  """

  require Logger

  alias ShhAi.PII.NER
  alias ShhAi.PII.Patterns

  @type pii_type :: Patterns.pii_type()

  @type detection :: %{
          type: pii_type(),
          value: String.t(),
          start_pos: non_neg_integer(),
          end_pos: non_neg_integer(),
          confidence: float(),
          description: String.t(),
          source: :regex | :ner | :hybrid
        }

  @type detections :: [detection()]

  @doc """
  Detects PII in the given text using hybrid detection strategy.

  Returns a list of detections, each containing the type, value, position,
  confidence score, and description.

  ## Options

    * `:confidence_threshold` - Minimum confidence threshold (default: from config)
    * `:types` - List of PII types to detect (default: all types from config)
    * `:mode` - Detection mode: `:complementary`, `:ner_only`, or `:regex_only`
    * `:skip_ner` - Skip NER detection (boolean, default: false)

  ## Examples

      iex> ShhAi.PII.Detector.detect("My email is john@example.com")
      [%{type: :email, value: "john@example.com", ...}]

      iex> ShhAi.PII.Detector.detect("SSN: 123-45-6789", types: [:ssn])
      [%{type: :ssn, value: "123-45-6789", ...}]

  """
  @spec detect(text :: String.t(), opts :: keyword()) :: detections()
  def detect(text, opts \\ []) when is_binary(text) do
    mode = Keyword.get(opts, :mode, config_hybrid_mode())
    skip_ner = Keyword.get(opts, :skip_ner, false)
    types = Keyword.get(opts, :types, config_types())

    case {mode, skip_ner} do
      {:regex_only, _} ->
        detect_regex_only(text, opts)

      {:ner_only, _} ->
        detect_ner_only(text, opts)

      {:complementary, true} ->
        detect_regex_only(text, opts)

      {:complementary, false} ->
        detect_hybrid(text, opts)
    end
    |> Stream.filter(&filter_by_type(&1, types))
    |> sort_by_position_confidence()
    |> deduplicate_sorted()
  end

  @doc """
  Checks if text contains any PII.

  Returns `true` if PII is detected, `false` otherwise.

  ## Examples

      iex> ShhAi.PII.Detector.contains_pii?("Contact me at john@example.com")
      true

      iex> ShhAi.PII.Detector.contains_pii?("Hello world")
      false

  """
  @spec contains_pii?(text :: String.t(), opts :: keyword()) :: boolean()
  def contains_pii?(text, opts \\ []) when is_binary(text) do
    detect(text, opts) != []
  end

  @doc """
  Returns a summary of detected PII types and counts.

  ## Examples

      iex> ShhAi.PII.Detector.summary("Email: a@b.com, Phone: 555-1234")
      %{email: 1, phone: 1}

  """
  @spec summary(text :: String.t(), opts :: keyword()) :: %{pii_type() => non_neg_integer()}
  def summary(text, opts \\ []) when is_binary(text) do
    detect(text, opts)
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, detections} -> {type, length(detections)} end)
    |> Map.new()
  end

  # Private functions

  defp config_regex_threshold do
    ShhAi.Config.pii_regex_confidence_threshold()
  end

  defp config_types do
    ShhAi.Config.pii_types()
  end

  defp config_hybrid_mode do
    ShhAi.Config.pii_hybrid_mode()
  end

  defp detect_regex_only(text, opts) do
    confidence_threshold = Keyword.get(opts, :confidence_threshold, config_regex_threshold())
    types = Keyword.get(opts, :types, config_types())

    Patterns.all()
    |> Stream.filter(&filter_by_type(&1, types))
    |> Stream.flat_map(&scan_pattern(text, &1))
    |> Enum.filter(&filter_by_confidence(&1, confidence_threshold))
  end

  defp detect_ner_only(text, opts) do
    unless NER.initialized?() do
      raise "NER model not initialized. Call ShhAi.PII.NER.init/1 first."
    end

    case NER.detect(text, opts) do
      {:ok, detections} ->
        detections

      {:error, reason} ->
        raise "NER detection failed: #{inspect(reason)}"
    end
  end

  defp detect_hybrid(text, opts) do
    # Run regex detection (fast, well-calibrated)
    regex_detections = detect_regex_only(text, opts)

    # Run NER detection if available (context-aware, but overconfident)
    ner_detections =
      if NER.initialized?() do
        case NER.detect(text, opts) do
          {:ok, detections} -> detections
          {:error, reason} -> raise "NER detection failed: #{inspect(reason)}"
        end
      else
        Logger.debug("NER not initialized, ignoring.")
        []
      end

    # Cross-validate NER detections against regex patterns
    # This can boost confidence when both agree and stops a regex match from
    # rewriting the type of an NER entity it overlaps.
    {validated_ner_detections, remaining_regex_detections} =
      cross_validate_ner(ner_detections, regex_detections)

    remaining_regex_detections ++ validated_ner_detections
  end

  # Cross-validates NER detections against regex patterns.
  # Returns the NER detections to report and the regex detections not consumed
  # by a conflict.
  #
  # When NER detects something that also matches a regex pattern:
  # - If types match: boost confidence (both agree) and keep both spans
  # - If types conflict: keep the higher-confidence detection and drop the
  #   other. The regex never rewrites the NER type: NER reads the sentence
  #   context, and a legal phrase such as "the Warsaw District Court" is an
  #   organisation even when a pattern also sees a street shape in it
  # - If NER-only: keep the NER confidence unchanged, so the NER threshold
  #   remains a true floor on the model's calibrated score
  #
  # Resolving the conflict here, instead of leaving both detections to the
  # position-first dedupe, makes the winner depend on confidence alone.
  defp cross_validate_ner(ner_detections, regex_detections) do
    {ner_kept, regex_kept} =
      Enum.reduce(ner_detections, {[], regex_detections}, fn ner_det, {ner_acc, regex_acc} ->
        case find_overlapping(ner_det, regex_acc) do
          nil -> {[ner_det | ner_acc], regex_acc}
          regex_det -> resolve_overlap(ner_det, regex_det, ner_acc, regex_acc)
        end
      end)

    {Enum.reverse(ner_kept), regex_kept}
  end

  # Both detectors agree on the type, so the NER hit gains confidence.
  defp resolve_overlap(%{type: type} = ner_det, %{type: type}, ner_acc, regex_acc) do
    boosted = %{ner_det | confidence: min(ner_det.confidence + 0.1, 0.99), source: :hybrid}
    {[boosted | ner_acc], regex_acc}
  end

  # The types disagree, so the more confident detection is the one reported.
  defp resolve_overlap(ner_det, regex_det, ner_acc, regex_acc) do
    if ner_det.confidence >= regex_det.confidence do
      {[ner_det | ner_acc], List.delete(regex_acc, regex_det)}
    else
      {ner_acc, regex_acc}
    end
  end

  defp find_overlapping(detection, detections) do
    Enum.find(detections, fn other ->
      overlaps?(detection, other)
    end)
  end

  defp filter_by_type(%{type: type}, types) do
    type in types
  end

  defp filter_by_confidence(%{confidence: confidence}, threshold) do
    confidence >= threshold
  end

  defp scan_pattern(text, %{pattern: pattern} = entry) do
    %{type: type, confidence: confidence, description: description} = entry

    pattern
    |> Regex.scan(text, return: :index)
    |> Stream.flat_map(fn
      [{start, length}] ->
        build_detection(text, entry, start, length, type, confidence, description)

      # Handle captures - use the first capture if available
      [{_start, _length} | [{cap_start, cap_length} | _]] ->
        build_detection(text, entry, cap_start, cap_length, type, confidence, description)

      [] ->
        []
    end)
  end

  # Builds a detection for one matched span, dropping it when the pattern's
  # validator (a Luhn, IBAN mod-97 or SSN structural check) rejects the value.
  # A pattern with no validator always produces a detection.
  defp build_detection(text, entry, start, length, type, confidence, description) do
    value = binary_part(text, start, length)

    if Patterns.validate(entry, value) do
      [
        %{
          type: type,
          value: value,
          start_pos: start,
          end_pos: start + length,
          confidence: confidence,
          description: description,
          source: :regex
        }
      ]
    else
      []
    end
  end

  @doc false
  # Efficient O(n) deduplication for already-sorted detections.
  # Since detections are sorted by start_pos, we only need to check
  # overlaps with the last kept detection, not all previous ones.
  defp deduplicate_sorted(sorted_detections) do
    sorted_detections
    |> Enum.reduce([], fn
      detection, [] ->
        [detection]

      detection, [last | _] = acc ->
        if overlaps?(detection, last) do
          # Skip this detection as it overlaps with a higher-confidence one
          # (already sorted by confidence descending)
          acc
        else
          [detection | acc]
        end
    end)
    |> Enum.reverse()
  end

  defp overlaps?(d1, d2) do
    # Check if two detections overlap
    d1.start_pos < d2.end_pos and d2.start_pos < d1.end_pos
  end

  defp sort_by_position_confidence(detections) do
    # Sort by start_pos, then by span (longer first), then by confidence (higher first)
    # This ensures that when multiple detections start at the same position,
    # the longer (more specific) match is kept during deduplication.
    Enum.sort_by(detections, &{&1.start_pos, -(&1.end_pos - &1.start_pos), -&1.confidence})
  end
end
