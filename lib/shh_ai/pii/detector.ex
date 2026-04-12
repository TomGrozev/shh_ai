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
  - Supports parallel detection for large texts
  """

  require Logger

  alias ShhAi.PII.Patterns
  alias ShhAi.PII.NER

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
  Detects PII in text with parallel processing for large texts.
  Useful for documents or large payloads.

  ## Options

    * `:chunk_size` - Size of each chunk for parallel processing (default: 10_000)
    * All options from `detect/2`

  """
  @spec detect_large(text :: String.t(), opts :: keyword()) :: detections()
  def detect_large(text, opts \\ []) when is_binary(text) do
    chunk_size = Keyword.get(opts, :chunk_size, 10_000)

    text
    |> chunk_text(chunk_size)
    |> Task.async_stream(
      fn {chunk, offset} ->
        detections = detect(chunk, opts)

        Enum.map(detections, fn d ->
          %{d | start_pos: d.start_pos + offset, end_pos: d.end_pos + offset}
        end)
      end,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, detections} -> detections end)
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

      {:error, _reason} ->
        # Fall back to regex on NER failure
        detect_regex_only(text, opts)
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
          {:error, _} -> []
        end
      else
        Logger.debug("NER not initialized, ignoring.")
        []
      end

    # Cross-validate NER detections against regex patterns
    # This calibrates confidence and can correct misclassifications
    validated_ner_detections = cross_validate_ner(ner_detections, regex_detections)

    regex_detections ++ validated_ner_detections
  end

  # Cross-validates NER detections against regex patterns.
  # When NER detects something that also matches a regex pattern:
  # - If types match: boost confidence (both agree)
  # - If types conflict: use regex type and reduce NER confidence
  # - If NER-only: apply a confidence penalty for unvalidated detections
  #
  # This helps correct common NER misclassifications like:
  # - Credit card numbers detected as phone numbers
  # - Dates detected in isolation
  defp cross_validate_ner(ner_detections, regex_detections) do
    # Find overlapping detections
    ner_detections
    |> Enum.map(fn ner_det ->
      # Check if any regex detection overlaps with this NER detection
      overlapping_regex = find_overlapping(ner_det, regex_detections)

      case overlapping_regex do
        nil ->
          # NER-only detection: apply penalty for unvalidated detections
          # NER models are often overconfident on patterns they haven't seen
          adjust_unvalidated_confidence(ner_det)

        regex_det ->
          # Both NER and regex found something here
          if ner_det.type == regex_det.type do
            # Types agree: boost confidence
            %{ner_det | confidence: min(ner_det.confidence + 0.1, 0.99), source: :hybrid}
          else
            # Types conflict: trust regex for type, but keep NER's position info
            # Common case: NER misclassifies credit card as phone
            %{ner_det | type: regex_det.type, confidence: regex_det.confidence, source: :hybrid}
          end
      end
    end)
  end

  defp find_overlapping(detection, detections) do
    Enum.find(detections, fn other ->
      overlaps?(detection, other)
    end)
  end

  # Adjust confidence for NER detections that don't have regex validation
  # Different PII types have different reliability from NER
  defp adjust_unvalidated_confidence(detection) do
    penalty = confidence_penalty_for_type(detection.type)
    adjusted_confidence = detection.confidence * penalty
    %{detection | confidence: adjusted_confidence}
  end

  # Confidence penalties for unvalidated NER detections
  # These are empirically tuned based on NER model accuracy
  defp confidence_penalty_for_type(:email), do: 0.95
  defp confidence_penalty_for_type(:phone), do: 0.70
  defp confidence_penalty_for_type(:ssn), do: 0.85
  defp confidence_penalty_for_type(:financial), do: 0.70
  defp confidence_penalty_for_type(:date), do: 0.50
  defp confidence_penalty_for_type(:ip_address), do: 0.90
  defp confidence_penalty_for_type(:vin), do: 0.80
  defp confidence_penalty_for_type(:name), do: 0.85
  defp confidence_penalty_for_type(:location), do: 0.75
  defp confidence_penalty_for_type(:organization), do: 0.80
  defp confidence_penalty_for_type(_), do: 0.70

  defp filter_by_type(%{type: type}, types) do
    type in types
  end

  defp filter_by_confidence(%{confidence: confidence}, threshold) do
    confidence >= threshold
  end

  defp scan_pattern(text, %{
         pattern: pattern,
         type: type,
         confidence: confidence,
         description: description
       }) do
    Regex.scan(pattern, text, return: :index)
    |> Stream.flat_map(fn
      [{start, length}] ->
        [
          %{
            type: type,
            value: binary_part(text, start, length),
            start_pos: start,
            end_pos: start + length,
            confidence: confidence,
            description: description,
            source: :regex
          }
        ]

      # Handle captures - use the first capture if available
      [{start, length} | captures] ->
        # If there are captures, use the first capture for the value
        case captures do
          [{cap_start, cap_length} | _] ->
            [
              %{
                type: type,
                value: binary_part(text, cap_start, cap_length),
                start_pos: cap_start,
                end_pos: cap_start + cap_length,
                confidence: confidence,
                description: description,
                source: :regex
              }
            ]

          [] ->
            [
              %{
                type: type,
                value: binary_part(text, start, length),
                start_pos: start,
                end_pos: start + length,
                confidence: confidence,
                description: description,
                source: :regex
              }
            ]
        end

      [] ->
        []
    end)
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
    Enum.sort_by(detections, &{&1.start_pos, -&1.confidence})
  end

  defp chunk_text(text, chunk_size) do
    text
    |> ShhAi.Utils.Stream.stream_binary(chunk_size)
    |> Stream.with_index()
    |> Stream.map(fn {chunk, idx} -> {chunk, idx * chunk_size} end)
  end
end
