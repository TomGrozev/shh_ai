defmodule ShhAi.ProviderClient.StreamHandler do
  @moduledoc """
  Owns the streaming lifecycle end-to-end.

  The public interface is:

    * `init/1` — takes a per-request spec map, returns
      `{handle, request_meta}`. `handle` is the per-chunk handle used by
      `handle_chunk/3`. `request_meta` is the per-finalization typed
      spec used at stream end; it is held by the caller, NOT on the
      handle.

    * `handle_chunk/3` — processes one raw chunk. Returns
      `{:cont, handle, done?}` or `{:halt, handle, done?}` so the
      caller can call `finalize/2` when `done?` is true.

    * `finalize/2` — emits the final `Metrics.emit_stream_stop/4` event
      and persists the assistant turn via `Conversation`.

  ## Three concerns, three structs

  Per the design (`docs/architecture/03-streaming-handler.md` and
  `docs/architecture/05-stream-accumulator.md`), the streaming state is
  split into three typed structs:

    * `%StreamHandler.Handle{}` — per-request static state + per-chunk
      mutable state. The per-chunk fields are `pii_state` (transient
      map: `%{buffer: binary}`) and `accumulator`
      (`%StreamHandler.Accumulator{}`).

    * `%StreamHandler.Accumulator{}` — per-chunk accumulator (2 fields,
      mutated every chunk).

    * `%StreamHandler.RequestMeta{}` — per-finalization values
      (`start_time`, `started_at`, `backend_start`, `metrics_opts`,
      `pii_info`, `pre_stream_timings`). The handle does NOT carry
      these — they are returned from `init/1` and passed to `finalize/2`.

  The `accumulator` field on the handle has a plain-map default in
  `defstruct` (cross-module `defstruct` defaults cannot call
  `Accumulator.new/0`). The public interface always goes through
  `init/1`, which constructs a proper `%Accumulator{}`.
  """

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.Metrics
  alias ShhAi.PIIPipeline
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.Handle
  alias ShhAi.ProviderClient.StreamHandler.RequestMeta
  alias ShhAi.ProviderClient.StreamTransport

  @type handle :: %Handle{}

  defmodule Handle do
    @moduledoc """
    Per-request static state + per-chunk mutable state.

    Per-request fields (static after `init/1`): `source_converter`,
    `target_converter`, `source_path`, `source_provider`, `method`,
    `conversation`, `openai_body`, `mapping`, `reverse_index`,
    `stream_fun`.

    Per-chunk fields (mutated every chunk): `conn`, `pii_state`,
    `accumulator`.

    The handle does NOT carry per-finalization values — those live in
    `%StreamHandler.RequestMeta{}`, built at `init/1` and held by the
    caller.
    """

    @enforce_keys [
      :source_converter,
      :target_converter,
      :source_path,
      :source_provider,
      :method,
      :conversation,
      :openai_body,
      :mapping,
      :reverse_index,
      :stream_fun,
      :conn,
      :pii_state,
      :accumulator
    ]

    defstruct [
      :source_converter,
      :target_converter,
      :source_path,
      :source_provider,
      :method,
      :conversation,
      :openai_body,
      :mapping,
      :reverse_index,
      :stream_fun,
      :conn,
      :pii_state,
      :accumulator
    ]
  end

  @doc """
  Wraps the per-request spec into a `{handle, request_meta}` tuple.

  `handle` is used for the per-chunk data path (`handle_chunk/3`).
  `request_meta` is held by the caller and passed to `finalize/2` at
  stream end.
  """
  @spec init(map()) :: {handle(), RequestMeta.t()}
  def init(spec) do
    handle = %Handle{
      source_converter: spec.source_converter,
      target_converter: spec.target_converter,
      source_path: spec.source_path,
      source_provider: spec.source_provider,
      method: spec.method,
      conversation: spec.conversation,
      openai_body: spec.openai_body,
      mapping: spec.mapping,
      reverse_index: spec.reverse_index,
      stream_fun: spec.stream_fun,
      conn: spec.conn,
      pii_state: %{buffer: ""},
      accumulator: Accumulator.new()
    }

    request_meta =
      RequestMeta.new(
        start_time: spec.start_time,
        started_at: spec.started_at,
        backend_start: spec.backend_start,
        metrics_opts: spec.metrics_opts,
        pii_info: spec.pii_info,
        pre_stream_timings: spec.pre_stream_timings
      )

    {handle, request_meta}
  end

  @doc """
  Processes one raw SSE chunk. Returns `{:cont, handle, done?}` to
  continue or `{:halt, handle, done?}` to stop. When `done?` is true
  the caller should call `finalize/2` next.

  The `Plug.Conn` is owned by the handle and is mutated in place via
  `stream_fun`. The per-chunk state (`pii_state`, `accumulator`,
  `conn`) is mutated on the handle. No per-finalization fields are
  touched.
  """
  @spec handle_chunk(handle(), iodata(), Plug.Conn.t() | nil) ::
          {:cont, handle(), boolean()} | {:halt, handle(), boolean()}
  def handle_chunk(%Handle{} = handle, chunk, _original_conn) do
    chunk = IO.iodata_to_binary(chunk)

    a_conn = StreamTransport.init_stream(handle.conn, %Req.Response{status: 200})

    restore_start = System.monotonic_time(:microsecond)

    {converted_chunks, new_pii_state, done?, openai_chunks} =
      convert_and_restore_stream_chunk(
        chunk,
        handle.target_converter,
        handle.source_converter,
        handle.source_path,
        handle.mapping,
        handle.pii_state
      )

    chunk_content = PIIPipeline.extract_content_from_openai_chunks(openai_chunks)
    restore_end = System.monotonic_time(:microsecond)

    new_acc = update_accumulator(handle.accumulator, restore_start, restore_end, chunk_content)

    case stream_chunks_to_conn(converted_chunks, a_conn, handle.stream_fun) do
      {:halt, _halted_conn} ->
        {:halt, %{handle | accumulator: new_acc, pii_state: new_pii_state}, done?}

      new_conn ->
        updated = %{handle | conn: new_conn, accumulator: new_acc, pii_state: new_pii_state}
        {:cont, updated, done?}
    end
  end

  @doc """
  Emits the final `Metrics.emit_stream_stop/4` event and persists the
  assistant turn via `Conversation`. Computes `conversation_id`
  internally; the 4th arg of `Metrics.emit_stream_stop/4` is passed
  here.
  """
  @spec finalize(handle(), RequestMeta.t()) :: {:ok, handle(), String.t()}
  def finalize(%Handle{} = handle, %RequestMeta{} = request_meta) do
    acc = handle.accumulator

    assistant_content =
      acc.assistant_content_chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    assistant_message = %{"role" => "assistant", "content" => assistant_content}
    full_messages = (handle.openai_body["messages"] || []) ++ [assistant_message]

    final_id =
      if handle.conversation.new? do
        Conversation.persist_turn_1(
          handle.conversation,
          full_messages,
          handle.mapping,
          handle.reverse_index
        )
      else
        Conversation.finalize_response(handle.conversation, full_messages)
      end

    Conversation.cache_assistant_response(final_id, assistant_content, handle.mapping)

    Metrics.emit_stream_stop(200, acc, request_meta, final_id)

    updated = %{handle | conversation: %{handle.conversation | new?: false}}
    {:ok, updated, final_id}
  end

  # ---------------------------------------------------------------------------
  # Accumulator mutation (public for testability)
  # ---------------------------------------------------------------------------

  @doc false
  def update_accumulator(%Accumulator{} = acc, restore_start, restore_end, chunk_content) do
    %{
      acc
      | restore_duration: acc.restore_duration + (restore_end - restore_start),
        assistant_content_chunks: [chunk_content | acc.assistant_content_chunks]
    }
  end

  # ---------------------------------------------------------------------------
  # Private — chunk processing
  # ---------------------------------------------------------------------------

  defp convert_and_restore_stream_chunk(
         chunk,
         target_converter,
         source_converter,
         source_path,
         mapping,
         pii_state
       ) do
    case target_converter.to_openai_stream_chunk(chunk, source_path) do
      {:done, chunks} ->
        {converted, final} =
          process_chunks(chunks, mapping, source_converter, source_path, pii_state)

        {converted, final, true, chunks}

      :done ->
        {[], pii_state, true, []}

      {:error, reason} ->
        Logger.warning("Stream chunk conversion failed: #{inspect(reason)}")
        {[], pii_state, false, []}

      openai_chunks when is_list(openai_chunks) ->
        {converted, final} =
          process_chunks(openai_chunks, mapping, source_converter, source_path, pii_state)

        {converted, final, false, openai_chunks}
    end
  end

  defp process_chunks(chunks, mapping, source_converter, source_path, pii_state) do
    Enum.flat_map_reduce(chunks, pii_state, fn openai_chunk, state ->
      {restored, new_state} = PIIPipeline.restore_stream_chunk(openai_chunk, state, mapping)
      {convert_restored_chunks(restored, source_converter, source_path), new_state}
    end)
  end

  defp convert_restored_chunks(restored_chunks, source_converter, source_path) do
    Enum.flat_map(restored_chunks, fn chunk ->
      case source_converter.from_openai_stream_chunk(chunk, source_path) do
        {:done, new_chunks} ->
          new_chunks

        new_chunks when is_list(new_chunks) ->
          new_chunks

        other ->
          Logger.warning("Unexpected from_openai_stream_chunk return: #{inspect(other)}")
          []
      end
    end)
  end

  # Sends each chunk through the stream function. Returns the updated conn
  # or `{:halt, halted_conn}` if the stream function signals to stop.
  defp stream_chunks_to_conn(chunks, conn, stream_fun) do
    Enum.reduce_while(chunks, conn, fn chunk, conn_inner ->
      case stream_fun.(chunk, conn_inner) do
        {:cont, new_conn} -> {:cont, new_conn}
        :halt -> {:halt, conn_inner}
      end
    end)
  end
end
