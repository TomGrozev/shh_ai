defmodule ShhAi.ProviderClient.StreamHandler.RequestMeta do
  @moduledoc """
  Typed contract for per-request stream metadata.

  Static for the request duration — passed to Metrics.emit_stream_stop/3
  at stream finalization. Distinct from Accumulator which mutates per chunk.
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
          metrics_opts: metrics_opts(),
          conversation_id: String.t()
        }

  @enforce_keys [:start_time, :metrics_opts, :conversation_id]

  defstruct [:start_time, :metrics_opts, :conversation_id]

  @doc """
  Builds a RequestMeta from the three required fields.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      start_time: Keyword.fetch!(opts, :start_time),
      metrics_opts: Keyword.fetch!(opts, :metrics_opts),
      conversation_id: Keyword.fetch!(opts, :conversation_id)
    }
  end
end
