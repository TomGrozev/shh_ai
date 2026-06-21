defmodule ShhAi.PII.SanitizationResult do
  @moduledoc """
  Typed contract for the PII Pipeline return value.
  Replaces the positional 5-tuple with a named struct for compile-time field access.
  """

  # Future reassessment:
  # `detection_counts` and `pii_info` carry overlapping information.
  # `pii_info` is a strict superset (it includes `types` and the derived `detected_count`).
  # Both are kept for now because `detection_counts` is the raw tuple from Sanitizer
  # (cheap, pattern-matchable) while `pii_info` is the enriched map for metrics.
  # If a future slice confirms no consumer needs the raw tuple form, collapse to a
  # single field — likely just `pii_info` with an accessor for the counts.

  @type mapping :: %{{atom(), pos_integer()} => String.t()}
  @type reverse_index :: %{{String.t(), atom()} => {atom(), pos_integer()}}
  @type detection_counts :: {non_neg_integer(), non_neg_integer()}
  @type pii_info :: %{
          detected_count: non_neg_integer(),
          sanitized_count: non_neg_integer(),
          preserved_count: non_neg_integer(),
          types: [atom()]
        }
  @type sanitized_messages :: [map()]

  @type t :: %__MODULE__{
          sanitized_messages: sanitized_messages(),
          mapping: mapping(),
          reverse_index: reverse_index(),
          detection_counts: detection_counts(),
          pii_info: pii_info()
        }

  @enforce_keys [:sanitized_messages, :mapping, :reverse_index, :detection_counts, :pii_info]

  defstruct [:sanitized_messages, :mapping, :reverse_index, :detection_counts, :pii_info]
end
