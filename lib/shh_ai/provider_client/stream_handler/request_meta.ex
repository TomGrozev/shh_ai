defmodule ShhAi.ProviderClient.StreamHandler.RequestMeta do
  @moduledoc """
  Typed contract for per-finalization stream metadata.

  Per-finalization values (lifetime: only used at stream end) — passed to
  `Metrics.emit_stream_stop/4` at finalization. The struct is built at
  `StreamHandler.init/1` time but is **not** held on the streaming handle;
  the per-chunk data path never touches these fields.

  `conversation_id` is intentionally NOT a field — it is computed inside
  `StreamHandler.finalize/2` (via `Conversation.persist_turn_1/4` or
  `Conversation.finalize_response/2`) and passed as a separate argument to
  `Metrics.emit_stream_stop/4` at finalization time.
  """

  @type metrics_opts :: %{
          source_provider: atom(),
          target_provider: String.t(),
          request_path: String.t(),
          method: String.t(),
          streaming: boolean()
        }

  @type t :: %__MODULE__{
          start_time: integer(),
          started_at: integer(),
          backend_start: integer(),
          metrics_opts: map(),
          pii_info: map(),
          pre_stream_timings: map()
        }

  @enforce_keys [
    :start_time,
    :started_at,
    :backend_start,
    :metrics_opts,
    :pii_info,
    :pre_stream_timings
  ]

  defstruct [
    :start_time,
    :started_at,
    :backend_start,
    :metrics_opts,
    :pii_info,
    :pre_stream_timings
  ]

  @doc """
  Builds a RequestMeta from the six required fields.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      start_time: Keyword.fetch!(opts, :start_time),
      started_at: Keyword.fetch!(opts, :started_at),
      backend_start: Keyword.fetch!(opts, :backend_start),
      metrics_opts: Keyword.fetch!(opts, :metrics_opts),
      pii_info: Keyword.fetch!(opts, :pii_info),
      pre_stream_timings: Keyword.fetch!(opts, :pre_stream_timings)
    }
  end
end
