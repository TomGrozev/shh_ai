defmodule ShhAi.ErrorClass do
  @moduledoc """
  Maps a failure reason to a bounded **error class**.

  Failure reasons reaching logs and persisted metrics are raw terms —
  `inspect/1` of an exception, a `%Mint.TransportError{}`/`%Req.TransportError{}`,
  or a tagged tuple — and can embed message content (request bodies, provider
  responses, PII). `classify/1` collapses a reason to a small, documented set of
  transport-class / clean atoms, so a log reader or dashboard viewer can never
  harvest sensitive detail from a persisted `error_message` or a redacted log
  line. See issue #56.

  The transport classes mirror the retryable connection failures in
  ADR-0013 §5; the ShhAi-originated classes reuse the metric error vocabulary.
  An exception struct is classed by its module (e.g. `RuntimeError`), which is
  likewise bounded by the modules that exist in the system.
  """

  @typedoc "A bounded error class."
  @type t :: atom()

  # Connection-class transport failures (ADR-0013 §5): already bounded atoms,
  # passed through unchanged.
  @transport_classes [:econnrefused, :nxdomain, :econnreset, :closed, :timeout]

  # ShhAi-originated / clean classes from the metric error vocabulary.
  @clean_classes @transport_classes ++
                   [:transport_error, :http_error, :model_not_served, :pii_sanitization_failed]

  @doc """
  Returns the bounded error class for `reason`.

  Never returns message content: strings, tuples with payloads, and any other
  unrecognised term collapse to `:unknown`.
  """
  @spec classify(term()) :: t()
  def classify(%Mint.TransportError{reason: reason}), do: transport_class(reason)
  def classify(%Req.TransportError{reason: reason}), do: transport_class(reason)
  def classify(%Mint.HTTPError{}), do: :http_error
  def classify(%Req.HTTPError{}), do: :http_error
  def classify({:model_not_served, _model}), do: :model_not_served
  def classify(reason) when reason in @clean_classes, do: reason
  def classify(%{__struct__: module}) when is_atom(module), do: module
  def classify(_reason), do: :unknown

  defp transport_class(reason) when reason in @transport_classes, do: reason
  defp transport_class(_reason), do: :transport_error
end
