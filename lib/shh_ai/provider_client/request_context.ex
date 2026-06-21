defmodule ShhAi.ProviderClient.RequestContext do
  @moduledoc """
  Typed contract for the post-preparation request context shared by
  both the request (non-streaming) and stream paths.

  Returned by `ShhAi.ProviderClient.prepare_request/7` (via the
  caller) and consumed by:

    * the non-streaming response handlers (`handle_request_success/2`,
      `handle_request_error/2`)
    * the streaming execution (`perform_stream/3`) which nests it
      inside `%StreamHandler.Handle{}`

  This struct is the "per-request static" concern — values that never
  mutate during the request lifecycle. It pairs with:

    * `ShhAi.ProviderClient.StreamHandler.Accumulator` — per-chunk
      mutable state

  Together they implement the "two structs" design (this static
  context + the per-chunk accumulator) called out in
  `docs/architecture/03-streaming-handler.md`, with this struct
  additionally shared with the non-streaming request path.

  The struct carries a `streaming` flag (boolean) that distinguishes
  the request (non-streaming) path from the stream path — a single
  shared context shape, parameterized by intent.
  """

  alias ShhAi.Conversation
  alias ShhAi.PII.SanitizationResult

  @typedoc "Pre-stream timing breakdown (microseconds, `System.monotonic_time/1` units)."
  @type pre_stream_timings :: %{
          pii_duration: integer(),
          source_conversion_duration: integer(),
          target_conversion_duration: integer()
        }

  @type started :: %{monotonic: integer(), system: integer()}

  @enforce_keys [
    :source_provider,
    :target_provider,
    :source_path,
    :target_path,
    :method,
    :config,
    :source_converter,
    :target_converter,
    :conversation,
    :openai_body,
    :mapping,
    :reverse_index,
    :pii_info,
    :timings,
    :target_headers,
    :target_body,
    :streaming,
    :started
  ]
  defstruct @enforce_keys

  @typedoc "Converter-emitted headers for the target backend (auth/content-type applied later)."
  @type target_headers :: [{String.t(), String.t()}]

  @typedoc "Converter-emitted body for the target backend (encoded downstream)."
  @type target_body :: binary() | map()

  @type t :: %__MODULE__{
          source_provider: atom(),
          target_provider: atom(),
          source_path: String.t(),
          target_path: String.t(),
          method: atom(),
          config: map(),
          source_converter: module(),
          target_converter: module(),
          conversation: Conversation.t(),
          openai_body: map(),
          mapping: SanitizationResult.mapping(),
          reverse_index: SanitizationResult.reverse_index(),
          pii_info: SanitizationResult.pii_info(),
          timings: pre_stream_timings(),
          target_headers: target_headers(),
          target_body: target_body(),
          streaming: boolean(),
          started: started()
        }
end
