defmodule ShhAi.ProviderClient.StreamHandler do
  @moduledoc """
  Owns the streaming lifecycle end-to-end.

  The public interface is:

    * `chunked_conn/1` — puts a `Plug.Conn` into chunked response state
      (no-op if already chunked). Called once by
      `ShhAi.ProviderClient.build_handle/3` so the handle's `conn`
      enters `handle_chunk/2` already in `:chunked` state — no need
      to re-check on every chunk.

    * `handle_chunk/2` — processes one raw chunk. Returns
      `{:cont, handle, done?}` or `{:halt, handle, done?}` so the
      caller can call `finalize/2` when `done?` is true.

    * `finalize/2` — emits the final `Metrics.emit_stream_stop/6` event
      and persists the assistant turn via `Conversation`.

  The caller (`ShhAi.ProviderClient.perform_stream/3`) is responsible
  for constructing the `%Handle{}` struct at the start of the stream
  and capturing the `backend_start` monotonic timestamp immediately
  before `Req.request/1` is called — there is no `init/1` helper. The
  handle is the per-chunk mutable state passed to `handle_chunk/2`;
  `backend_start` is a plain integer the caller threads through
  `StreamTransport` and passes to `finalize/2` at stream end.

  ## Three concerns, three structs

  Per the design (`docs/architecture/03-streaming-handler.md`,
  `docs/architecture/04-request-context.md` and
  `docs/architecture/05-stream-accumulator.md`), the streaming state is
  split into two typed structs:

    * `%RequestContext{}` — per-request static state, shared with the
      non-streaming request path. The handle nests one via the
      `request_context` field. Holds the timings that flow into
      `Metrics.emit_stream_stop/6` and the typed fields (`source_provider`,
      `config.name`, `source_path`, `method`, `streaming`, `started`)
      that drive its metadata.

    * `%StreamHandler.Handle{}` — per-chunk mutable state. The
      streaming-specific fields are `conn`, `stream_fun`, `pii_state`
      (typed `%PIIPipeline.RestoreState{}`) and `accumulator`
      (`%StreamHandler.Accumulator{}`).

    * `%StreamHandler.Accumulator{}` — per-chunk accumulator (2 fields,
      mutated every chunk).

  Per-finalization values are read directly from
  `handle.request_context` (a `%RequestContext{}`); the only piece of
  state that lives outside the handle is `backend_start` (a monotonic
  integer), captured by the caller and passed in.

  The `accumulator` field on the handle has a plain-map default in
  `defstruct` (cross-module `defstruct` defaults cannot call
  `Accumulator.new/0`). The caller must construct the handle with an
  explicit `accumulator: Accumulator.new()`.
  """

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.Metrics
  alias ShhAi.PIIPipeline
  alias ShhAi.PIIPipeline.RestoreState
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.SSEParser
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.Handle

  @type handle :: %Handle{}

  defmodule Handle do
    @moduledoc """
    Per-chunk mutable handle for streaming.

    Composes a `%RequestContext{}` (per-request static data, shared with
    the non-streaming request path) with 4 streaming-specific fields:

      * `request_context` — the typed `ShhAi.ProviderClient.RequestContext{}`
        holding all per-request static values (source/target provider,
        path, method, config, converters, conversation, openai_body,
        PII mapping/reverse_index/info, timings, started timestamp).
      * `conn` — the `Plug.Conn` carrying the chunked response.
      * `stream_fun` — caller-supplied function that consumes one
        chunk at a time and returns `{:cont, conn}` or `:halt`.
      * `pii_state` — transient PII restore state (`%PIIPipeline.RestoreState{}`).
      * `accumulator` — typed `%StreamHandler.Accumulator{}` with
        per-chunk restore duration and assistant content chunks.

    The handle does NOT carry per-finalization values; the only piece
    of per-finalization state not in `request_context` is
    `backend_start` (the monotonic instant the backend HTTP call
    begins), which the caller passes to `finalize/2` directly.
    """

    @enforce_keys [:request_context, :conn, :stream_fun, :pii_state, :accumulator]

    defstruct [:request_context, :conn, :stream_fun, :pii_state, :accumulator]

    @type t :: %__MODULE__{
            request_context: RequestContext.t(),
            conn: Plug.Conn.t(),
            stream_fun: (... -> any()),
            pii_state: RestoreState.t(),
            accumulator: Accumulator.t()
          }
  end

  @doc """
  Processes one raw SSE chunk. Returns `{:cont, handle, done?}` to
  continue or `{:halt, handle, done?}` to stop. When `done?` is true
  the caller should call `finalize/2` next.

  The `Plug.Conn` is owned by the handle and is mutated in place via
  `stream_fun`. The per-chunk state (`pii_state`, `accumulator`,
  `conn`) is mutated on the handle. Per-request static state is read
  from `handle.request_context` (the `ShhAi.ProviderClient.RequestContext{}`
  shared with the non-streaming path). No per-finalization fields are
  touched.

  Assumes `handle.conn` is already in `:chunked` response state —
  `ProviderClient.build_handle/3` runs `chunked_conn/1` once at
  construction time, so this function does not re-check the conn
  state on every chunk.
  """
  @spec handle_chunk(handle(), iodata()) ::
          {:cont, handle(), boolean()} | {:halt, handle(), boolean()}
  def handle_chunk(%Handle{} = handle, chunk) do
    chunk = IO.iodata_to_binary(chunk)

    a_conn = handle.conn
    ctx = handle.request_context

    restore_start = System.monotonic_time(:microsecond)

    {converted_chunks, new_pii_state, done?, chunk_content} =
      convert_and_restore_stream_chunk(
        chunk,
        ctx.target_converter,
        ctx.source_converter,
        ctx.source_path,
        ctx.mapping,
        handle.pii_state
      )

    restore_end = System.monotonic_time(:microsecond)

    new_acc = update_accumulator(handle.accumulator, restore_start, restore_end, chunk_content)

    case stream_chunks_to_conn(converted_chunks, a_conn, handle.stream_fun) do
      {:halt, halted_conn} ->
        {:halt, %{handle | conn: halted_conn, accumulator: new_acc, pii_state: new_pii_state},
         done?}

      {:cont, new_conn} ->
        updated = %{handle | conn: new_conn, accumulator: new_acc, pii_state: new_pii_state}
        {:cont, updated, done?}
    end
  end

  @doc """
  Emits the final `Metrics.emit_stream_stop/6` event and persists the
  assistant turn via `Conversation`. Computes `conversation_id`
  internally; `backend_start` is the monotonic instant the backend
  HTTP call began, captured by the caller immediately before
  `Req.request/1`. All other per-finalization values
  (`source_provider`, `config.name`, `source_path`, `method`, timings,
  `pii_info`, `started_at`) are read from `handle.request_context`.

  Returns `{:ok, final_id}` — the finalised conversation ID.
  """
  @spec finalize(handle(), integer()) :: {:ok, String.t()}
  def finalize(%Handle{} = handle, backend_start) when is_integer(backend_start) do
    acc = handle.accumulator
    ctx = handle.request_context

    assistant_content =
      acc.assistant_content_chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    assistant_message = %{"role" => "assistant", "content" => assistant_content}
    full_messages = (ctx.openai_body["messages"] || []) ++ [assistant_message]
    request_time = started_to_request_time(ctx.started)

    final_id =
      if ctx.conversation.new? do
        Conversation.persist_turn_1(
          ctx.conversation,
          full_messages,
          ctx.mapping,
          ctx.reverse_index,
          request_time
        )
      else
        Conversation.finalize_response(ctx.conversation, full_messages)
      end

    Conversation.cache_assistant_response(final_id, assistant_content, ctx.mapping, request_time)

    Metrics.emit_stream_stop(200, ctx, backend_start, acc, final_id, assistant_content)

    {:ok, final_id}
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
  # Public — chunked-conn init
  # ---------------------------------------------------------------------------

  @doc """
  Puts a `Plug.Conn` into chunked response state for SSE streaming.
  No-op if the conn is already `:chunked`. Called once by
  `ShhAi.ProviderClient.build_handle/3` at handle construction time
  so the per-chunk path does not re-check the conn state on every
  chunk (which would also re-allocate a `%Req.Response{status: 200}`
  to feed the no-op guard).
  """
  @spec chunked_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def chunked_conn(%Plug.Conn{state: :chunked} = conn), do: conn

  def chunked_conn(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
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
    # Parse the SSE bytes ONCE via the converter's events API and re-use
    # the events when restoring PII, extracting content, and serializing
    # back to the source format. The restore and source-serialization
    # steps use an events-in/events-out contract, so the hot path does
    # exactly one `SSEParser.parse/1` per chunk on the OpenAI->OpenAI
    # path.
    case target_converter.to_openai_stream_events(chunk, source_path) do
      :done ->
        {[], pii_state, true, ""}

      {:error, reason} ->
        Logger.warning("Stream chunk conversion failed: #{inspect(reason)}")
        {[], pii_state, false, ""}

      # `:raw` is the explicit "this converter does not model this wire
      # format as typed SSE events" sentinel (e.g. Ollama's
      # newline-delimited JSON). Fall back to the chunk-based path that
      # re-parses the bytes via `to_openai_stream_chunk/2`.
      :raw ->
        convert_via_chunks(
          chunk,
          target_converter,
          source_converter,
          source_path,
          mapping,
          pii_state
        )

      # Genuine "no complete frame in this chunk" case — partial SSE
      # buffer. Emit nothing and let the next chunk complete the frame.
      [] ->
        {[], pii_state, false, ""}

      parsed_events ->
        convert_via_events(parsed_events, source_converter, source_path, mapping, pii_state)
    end
  end

  # Fallback path: only reached when the target converter returned `:raw`
  # (i.e. it does not model this wire format as typed SSE events — Ollama
  # newline-delimited JSON is the only production case today). The
  # target's `to_openai_stream_chunk/2` (a plain function on Ollama, not
  # a behaviour callback) parses the NDJSON bytes into OpenAI-format SSE
  # chunks; we then parse those chunks to typed events and feed them
  # through the events path (`process_chunks_with_events/5`), which
  # restores PII in place and serialises back to the source format via
  # `from_openai_stream_events/2` — same as the hot path, just with one
  # extra parse of the OpenAI-format bytes that the target's chunk
  # function produced.
  #
  # This is the `:raw` fallback path, NOT the "empty events" fallback —
  # an empty list from `to_openai_stream_events/2` means "no complete
  # frame in this chunk" and is handled earlier by returning
  # `{[], pii_state, false, ""}` without entering this function.
  defp convert_via_chunks(
         chunk,
         target_converter,
         source_converter,
         source_path,
         mapping,
         pii_state
       ) do
    openai_chunks =
      extract_chunks_list(target_converter.to_openai_stream_chunk(chunk, source_path))

    parsed_events =
      openai_chunks
      |> Enum.flat_map(&safe_parse_sse_chunk/1)

    {converted, final, content} =
      process_chunks_with_events(parsed_events, mapping, source_converter, source_path, pii_state)

    done? = Enum.any?(parsed_events, &match?(%SSEParser{type: :done}, &1))
    {converted, final, done?, content}
  end

  # Parse one OpenAI-format SSE chunk string into a list of typed
  # `%SSEParser{}` events. Malformed chunks contribute nothing; the
  # accumulator's `assistant_content_chunks` will not gain an entry
  # for that chunk.
  defp safe_parse_sse_chunk(chunk) do
    case SSEParser.parse(chunk) do
      events when is_list(events) -> events
      _ -> []
    end
  end

  # Hot path: events available — drive restore with the typed events.
  # We also pass the events directly to `extract_content_from_openai_events/1`
  # so the content accumulator never re-parses the wire format.
  defp convert_via_events(parsed_events, source_converter, source_path, mapping, pii_state) do
    {converted, final, content} =
      process_chunks_with_events(parsed_events, mapping, source_converter, source_path, pii_state)

    done? = Enum.any?(parsed_events, &match?(%SSEParser{type: :done}, &1))
    {converted, final, done?, content}
  end

  defp extract_chunks_list({:done, list}), do: list
  defp extract_chunks_list(list) when is_list(list), do: list
  defp extract_chunks_list(_), do: []

  # Hot-path driver: process events directly. Returns
  # `{converted, new_state, content}` where `content` is the extracted
  # text content for the accumulator (computed from the events without
  # re-parsing).
  #
  # Contract: the PII pipeline's restore uses an events-in/events-out
  # contract — `restore_stream_events/3` mutates the event's text payload
  # in place and returns the modified event. The modified events are then
  # handed to `from_openai_stream_events/2` (the converter's events-in,
  # source-format-bytes-out callback) for the final serialization to the
  # source wire format. No bytes-shaped re-serialization on this path.
  defp process_chunks_with_events(events, mapping, source_converter, source_path, pii_state) do
    content = PIIPipeline.extract_content_from_openai_events(events)

    {converted, final} =
      Enum.flat_map_reduce(events, pii_state, fn event, state ->
        {restored_events, new_state} =
          PIIPipeline.restore_stream_events([event], state, mapping)

        {convert_restored_events(restored_events, source_converter, source_path), new_state}
      end)

    {converted, final, content}
  end

  # Convert restored events back to source-format wire bytes via the
  # converter's `from_openai_stream_events/2` (events-in, source-bytes-out
  # callback). This is the single output-serialization point for the
  # events-based hot path — one `Jason.encode!` per event, no re-parse.
  #
  # All three source converters (OpenAI, Anthropic, Ollama) have a real
  # `from_openai_stream_events/2` implementation now — `:raw` is not
  # expected, but is handled defensively by logging a warning and dropping
  # the events.
  #
  # Accepts the same return shapes as the behaviour callback:
  #   * `:done` — stream end (carries no further chunks)
  #   * `{:done, chunks}` — stream end with trailing chunks to send
  #   * `[chunks]` — a list of source-format wire bytes
  #   * `:raw` — the converter does not model the inverse direction
  #   * `{:error, _}` — conversion failure
  defp convert_restored_events(restored_events, source_converter, source_path) do
    case source_converter.from_openai_stream_events(restored_events, source_path) do
      :raw ->
        Logger.warning("Unexpected from_openai_stream_events return: :raw")
        []

      {:done, new_chunks} when is_list(new_chunks) ->
        new_chunks

      :done ->
        []

      new_chunks when is_list(new_chunks) ->
        new_chunks

      other ->
        Logger.warning("Unexpected from_openai_stream_events return: #{inspect(other)}")
        []
    end
  end

  # Sends each chunk through the stream function. Returns
  # `{:cont, conn}` to keep streaming or `{:halt, conn}` if the stream
  # Convert the `started.system` microseconds timestamp to a
  # NaiveDateTime suitable for the cold-store audit rows.
  defp started_to_request_time(%{system: system_us}) do
    DateTime.from_unix!(system_us, :microsecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
  end

  # function signals to stop with `:halt`.
  #
  # Note: `Enum.reduce_while/3` returns the bare accumulator on halt, not
  # the `{:halt, acc}` tuple the reducer returned — so we drive the loop
  # with a tagged accumulator and unwrap here.
  defp stream_chunks_to_conn(chunks, conn, stream_fun) do
    chunks
    |> Enum.reduce_while({:cont, conn}, fn chunk, acc ->
      conn_inner = elem(acc, 1)

      case stream_fun.(chunk, conn_inner) do
        {:cont, new_conn} -> {:cont, {:cont, new_conn}}
        :halt -> {:halt, {:halt, conn_inner}}
      end
    end)
    |> case do
      {:halt, conn} -> {:halt, conn}
      {:cont, conn} -> {:cont, conn}
    end
  end
end
