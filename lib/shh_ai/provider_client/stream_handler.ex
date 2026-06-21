defmodule ShhAi.ProviderClient.StreamHandler do
  @moduledoc """
  Owns the streaming lifecycle end-to-end.

  The public interface is:

    * `handle_chunk/3` — processes one raw chunk. Returns
      `{:cont, handle, done?}` or `{:halt, handle, done?}` so the
      caller can call `finalize/2` when `done?` is true.

    * `finalize/2` — emits the final `Metrics.emit_stream_stop/6` event
      and persists the assistant turn via `Conversation`.

  The caller (`ShhAi.ProviderClient.perform_stream/3`) is responsible
  for constructing the `%Handle{}` struct at the start of the stream
  and capturing the `backend_start` monotonic timestamp immediately
  before `Req.request/1` is called — there is no `init/1` helper. The
  handle is the per-chunk mutable state passed to `handle_chunk/3`;
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
      (transient map: `%{buffer: binary}`) and `accumulator`
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
      * `pii_state` — transient PII restore state (`%{buffer: binary}`).
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
            pii_state: %{buffer: binary()},
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
  """
  @spec handle_chunk(handle(), iodata(), Plug.Conn.t() | nil) ::
          {:cont, handle(), boolean()} | {:halt, handle(), boolean()}
  def handle_chunk(%Handle{} = handle, chunk, _original_conn) do
    chunk = IO.iodata_to_binary(chunk)

    a_conn = init_stream(handle.conn, %Req.Response{status: 200})
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
  """
  @spec finalize(handle(), integer()) :: {:ok, handle(), String.t()}
  def finalize(%Handle{} = handle, backend_start) when is_integer(backend_start) do
    acc = handle.accumulator
    ctx = handle.request_context

    assistant_content =
      acc.assistant_content_chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    assistant_message = %{"role" => "assistant", "content" => assistant_content}
    full_messages = (ctx.openai_body["messages"] || []) ++ [assistant_message]

    final_id =
      if ctx.conversation.new? do
        Conversation.persist_turn_1(
          ctx.conversation,
          full_messages,
          ctx.mapping,
          ctx.reverse_index
        )
      else
        Conversation.finalize_response(ctx.conversation, full_messages)
      end

    Conversation.cache_assistant_response(final_id, assistant_content, ctx.mapping)

    Metrics.emit_stream_stop(200, ctx, backend_start, acc, final_id, assistant_content)

    updated = %{
      handle
      | request_context: %{
          ctx
          | conversation: %{ctx.conversation | new?: false}
        }
    }

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

  # Ensures the Plug.Conn is in `:chunked` state; no-op if already chunked.
  defp init_stream(%{state: :chunked} = conn, _resp), do: conn

  defp init_stream(conn, resp) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(resp.status)
  end

  defp convert_and_restore_stream_chunk(
         chunk,
         target_converter,
         source_converter,
         source_path,
         mapping,
         pii_state
       ) do
    # Parse the SSE bytes ONCE via the converter's events API and re-use the
    # events when restoring PII and extracting content. The previous
    # implementation parsed twice per chunk (once in the target_converter,
    # once in PIIPipeline.restore_stream_chunk/3) plus a third parse in
    # `extract_content_from_openai_chunks/1` for content accumulation.
    case target_converter.to_openai_stream_events(chunk, source_path) do
      :done ->
        {[], pii_state, true, ""}

      {:error, reason} ->
        Logger.warning("Stream chunk conversion failed: #{inspect(reason)}")
        {[], pii_state, false, ""}

      [] ->
        convert_via_chunks(
          chunk,
          target_converter,
          source_converter,
          source_path,
          mapping,
          pii_state
        )

      parsed_events ->
        convert_via_events(parsed_events, source_converter, source_path, mapping, pii_state)
    end
  end

  # Fallback path: events are empty (Ollama's JSON-per-line wire format or
  # Anthropic's per-frame parse-error fallback that returns the raw frame).
  # Re-uses the original double-parse semantics for these cases because
  # the events list carries no information we can drive the restore from.
  defp convert_via_chunks(
         chunk,
         target_converter,
         source_converter,
         source_path,
         mapping,
         pii_state
       ) do
    openai_chunks = target_converter.to_openai_stream_chunk(chunk, source_path)
    chunks = extract_chunks_list(openai_chunks)
    {converted, final} = process_chunks(chunks, mapping, source_converter, source_path, pii_state)
    content = PIIPipeline.extract_content_from_openai_chunks(chunks)
    {converted, final, false, content}
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

  defp process_chunks(chunks, mapping, source_converter, source_path, pii_state) do
    Enum.flat_map_reduce(chunks, pii_state, fn openai_chunk, state ->
      {restored, new_state} = PIIPipeline.restore_stream_chunk(openai_chunk, state, mapping)
      {convert_restored_chunks(restored, source_converter, source_path), new_state}
    end)
  end

  # Hot-path driver: process events directly. Returns
  # `{converted, new_state, content}` where `content` is the extracted
  # text content for the accumulator (computed from the events without
  # re-parsing).
  defp process_chunks_with_events(events, mapping, source_converter, source_path, pii_state) do
    content = PIIPipeline.extract_content_from_openai_events(events)

    {converted, final} =
      Enum.flat_map_reduce(events, pii_state, fn event, state ->
        {restored, new_state} =
          PIIPipeline.restore_stream_events([event], event_to_chunk(event), state, mapping)

        {convert_restored_chunks(restored, source_converter, source_path), new_state}
      end)

    {converted, final, content}
  end

  # Re-serialise a typed event back to its SSE wire form. Used as the
  # `chunk` argument to `restore_stream_events/4` so the PII pipeline can
  # produce the same restored wire output it would have produced from
  # the original raw bytes.
  defp event_to_chunk(%SSEParser{type: :done}), do: "data: [DONE]\n\n"

  defp event_to_chunk(%SSEParser{type: :data, payload: payload}),
    do: "data: #{Jason.encode!(payload)}\n\n"

  defp event_to_chunk(%SSEParser{type: :event, event_name: name, payload: payload}),
    do: "event: #{name}\ndata: #{Jason.encode!(payload)}\n\n"

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

  # Sends each chunk through the stream function. Returns
  # `{:cont, conn}` to keep streaming or `{:halt, conn}` if the stream
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
