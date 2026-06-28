defmodule ShhAi.ProviderClient.StreamTransport do
  @moduledoc false

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.Metrics
  alias ShhAi.ProviderClient.StreamHandler

  @doc """
  Builds the streaming `Req.Request` with an `into:` callback that
  dispatches each chunk to `StreamHandler.handle_chunk/2`.

  `handle` owns the streaming lifecycle (per-chunk accumulator, PII
  restore state, Plug.Conn). `backend_start` is the monotonic
  timestamp captured by the caller immediately before `Req.request/1`
  — the per-chunk callback reads it from the process dictionary
  (`Process.get`) so it can pass it through to `finalize/2` at done
  time. `base_request` is the fully-built `Req.Request` (url, method,
  headers, body, receive_timeout already set) — typically built by
  merging `HTTPTransport.base_request_opts()` with the
  request-specific options in the caller.

  The handle and `backend_start` are held in the **process
  dictionary** (not in Agents) so the `into:` callback can read the
  current handle on each chunk. Req's `into:` callback runs in the
  caller's process (per-request isolation is preserved), and the
  handle is an immutable struct replaced wholesale on every chunk
  (its `conn` / `accumulator` / `pii_state` are updated via map merge,
  not in-place mutation), so `Process.put` is sufficient. Removes 2
  process spawns + 2 mailboxes per stream request vs the previous
  Agent-based design.

  When `handle_chunk/2` signals `done?` true, the callback calls
  `StreamHandler.finalize/2` with `backend_start`. The dictionary
  cells are cleared after the request completes — see `do_stream/4`.
  """
  @spec build_stream_request(
          StreamHandler.handle(),
          integer(),
          Req.Request.t()
        ) :: Req.Request.t()
  def build_stream_request(handle, backend_start, base_request)
      when is_integer(backend_start) do
    # Stash the handle and backend_start in the process dictionary so
    # the into: callback can read the current handle on every chunk
    # and call finalize with backend_start on done. Req's into:
    # callback runs in the caller's process, so per-request
    # isolation is preserved (each request's process dict is
    # independent).
    Process.put({__MODULE__, :handle}, handle)
    Process.put({__MODULE__, :backend_start}, backend_start)

    Req.merge(base_request,
      into: fn {:data, chunk}, {req, resp} ->
        current = Process.get({__MODULE__, :handle})
        result = StreamHandler.handle_chunk(current, chunk)

        case result do
          {:cont, new_handle, true} ->
            Process.put({__MODULE__, :handle}, new_handle)
            start = Process.get({__MODULE__, :backend_start})
            {:ok, _final_id} = StreamHandler.finalize(new_handle, start)
            {:cont, {req, resp}}

          {:cont, new_handle, false} ->
            Process.put({__MODULE__, :handle}, new_handle)
            {:cont, {req, resp}}

          {:halt, new_handle, _done?} ->
            Process.put({__MODULE__, :handle}, new_handle)
            {:halt, {req, resp}}
        end
      end
    )
  end

  @doc """
  Executes the streaming request. On error, emits metrics from
  `initial_handle.request_context` (a `%RequestContext{}`) directly
  via `Metrics.emit_error_for_context/2` — all per-finalization
  values live on the request context, not on a separate wrapper
  struct. `conversation_id` is passed explicitly so the error path
  can touch the conversation without reading the handle. On success,
  returns `{:ok, final_handle, response}`.
  """
  @spec do_stream(Req.Request.t(), StreamHandler.handle(), integer(), String.t()) ::
          {:ok, StreamHandler.handle(), Req.Response.t()} | {:error, term()}
  def do_stream(request, initial_handle, backend_start, conversation_id)
      when is_integer(backend_start) and is_binary(conversation_id) do
    # NOTE: do NOT read the process dictionary handle here. The `into:`
    # callback in `build_stream_request/3` updates the dictionary on
    # every chunk with the new handle (with accumulated `resp_body`).
    # If we read it here (before `Req.request/1`), we get the stale
    # initial handle with `resp_body = ""` and lose all the streamed
    # chunks. Re-read the dictionary AFTER the request returns.

    case Req.request(request) do
      {:ok, response} ->
        final_handle = Process.get({__MODULE__, :handle}) || initial_handle
        cleanup_process_dict()
        {:ok, final_handle, response}

      {:error, reason} ->
        cleanup_process_dict()

        Logger.error("Backend stream request failed: #{inspect(reason)}")
        Conversation.touch(conversation_id)

        ctx = initial_handle.request_context

        Metrics.emit_error_for_context(ctx, %{
          error_type: :stream_error,
          error_message: inspect(reason),
          conversation_id: conversation_id
        })

        {:error, reason}
    end
  end

  defp cleanup_process_dict do
    Process.delete({__MODULE__, :handle})
    Process.delete({__MODULE__, :backend_start})
  end
end
