defmodule ShhAi.PII.Detector do
  @moduledoc """
  PII detection engine that identifies personally identifiable information in text.
  Uses regex patterns loaded from ShhAi.PII.Patterns for fast detection.

  ## Detection Process

  1. Load compiled patterns from :persistent_term
  2. Scan text for pattern matches
  3. Filter by confidence threshold
  4. Return list of detections with positions and types

  ## Performance

  - Patterns are pre-compiled and stored in :persistent_term
  - Binary pattern matching for fast scanning
  - Supports parallel detection for large texts
  """

  alias ShhAi.PII.Patterns

  @type pii_type :: Patterns.pii_type()

  @type detection :: %{
          type: pii_type(),
          value: String.t(),
          start_pos: non_neg_integer(),
          end_pos: non_neg_integer(),
          confidence: float(),
          description: String.t()
        }

  @type detections :: [detection()]

  @doc """
  Detects PII in the given text.

  Returns a list of detections, each containing the type, value, position,
  confidence score, and description.

  ## Options

    * `:confidence_threshold` - Minimum confidence threshold (default: from config)
    * `:types` - List of PII types to detect (default: all types from config)

  ## Examples

      iex> ShhAi.PII.Detector.detect("My email is john@example.com")
      [%{type: :email, value: "john@example.com", ...}]

      iex> ShhAi.PII.Detector.detect("SSN: 123-45-6789", types: [:ssn])
      [%{type: :ssn, value: "123-45-6789", ...}]

  """
  @spec detect(text :: String.t(), opts :: keyword()) :: detections()
  def detect(text, opts \\ []) when is_binary(text) do
    confidence_threshold = Keyword.get(opts, :confidence_threshold, config_threshold())
    types = Keyword.get(opts, :types, config_types())

    patterns = Patterns.all()

    patterns
    |> Stream.filter(&filter_by_type(&1, types))
    |> Stream.flat_map(&scan_pattern(text, &1))
    |> Enum.filter(&filter_by_confidence(&1, confidence_threshold))
    |> deduplicate_detections()
    |> sort_by_position()
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
    |> deduplicate_detections()
    |> sort_by_position()
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

  defp config_threshold do
    ShhAi.Config.pii_confidence_threshold()
  end

  defp config_types do
    ShhAi.Config.pii_types()
  end

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
            description: description
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
                description: description
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
                description: description
              }
            ]
        end

      [] ->
        []
    end)
  end

  defp deduplicate_detections(detections) do
    # Remove overlapping detections, keeping the one with higher confidence
    detections
    |> Enum.sort_by(&{&1.start_pos, -&1.confidence})
    |> Enum.reduce([], fn detection, acc ->
      if overlaps_any?(detection, acc) do
        acc
      else
        [detection | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp overlaps_any?(detection, existing) do
    Enum.any?(existing, &overlaps?(detection, &1))
  end

  defp overlaps?(d1, d2) do
    # Check if two detections overlap
    d1.start_pos < d2.end_pos and d2.start_pos < d1.end_pos
  end

  defp sort_by_position(detections) do
    Enum.sort_by(detections, & &1.start_pos)
  end

  defp chunk_text(text, chunk_size) do
    text
    |> ShhAi.Utils.Stream.stream_binary(chunk_size)
    |> Stream.with_index()
    |> Stream.map(fn {chunk, idx} -> {chunk, idx * chunk_size} end)
  end
end
