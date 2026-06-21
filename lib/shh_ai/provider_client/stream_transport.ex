defmodule ShhAi.ProviderClient.StreamTransport do
  @moduledoc false

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.Metrics
  alias ShhAi.ProviderClient.StreamHandler

  @doc """
  Builds the streaming `Req.Request` with an `into:` callback that
  dispatches each chunk to `StreamHandler.handle_chunk/3`.

  `handle` owns the streaming lifecycle (per-chunk accumulator, PII
  restore state, Plug.Conn). `backend_start` is the monotonic
  timestamp captured by the caller immediately before `Req.request/1`
  — the per-chunk callback reads it from a process-local mutable ref
  so it can pass it through to `finalize/2` at done time. `base_request`
  is the fully-built `Req.Request` (url, method, headers, body,
  receive_timeout already set) — typically built by merging
  `HTTPTransport.base_request_opts()` with the request-specific
  options in the caller.

  The handle and `backend_start` are held in Agents so the `into:`
  callback can update the handle's `conn`/`accumulator`/`pii_state` on
  each chunk (immutable handle struct; need a mutable cell). When
  `handle_chunk/3` signals `done?` true, the callback calls
  `StreamHandler.finalize/2` with `backend_start`. The agents are
  stopped after the request completes — see `do_stream/3`.
  """
  @spec build_stream_request(
          StreamHandler.handle(),
          integer(),
          Req.Request.t()
        ) :: Req.Request.t()
  def build_stream_request(handle, backend_start, base_request)
      when is_integer(backend_start) do
    # Store the handle and backend_start in Agents so the into: callback
    # can update the handle on each chunk and call finalize with the
    # backend_start on done.
    {:ok, handle_agent} = Agent.start_link(fn -> handle end)
    {:ok, start_agent} = Agent.start_link(fn -> backend_start end)
    Process.put({__MODULE__, :handle_agent}, handle_agent)
    Process.put({__MODULE__, :start_agent}, start_agent)

    Req.merge(base_request,
      into: fn {:data, chunk}, {req, resp} ->
        current = Agent.get(handle_agent, & &1)
        result = StreamHandler.handle_chunk(current, chunk, nil)

        case result do
          {:cont, new_handle, true} ->
            Agent.update(handle_agent, fn _ -> new_handle end)
            start = Agent.get(start_agent, & &1)
            {:ok, _final_handle, _final_id} = StreamHandler.finalize(new_handle, start)
            {:cont, {req, resp}}

          {:cont, new_handle, false} ->
            Agent.update(handle_agent, fn _ -> new_handle end)
            {:cont, {req, resp}}

          {:halt, new_handle, _done?} ->
            Agent.update(handle_agent, fn _ -> new_handle end)
            {:halt, {req, resp}}
        end
      end
    )
  end

  @doc """
  Executes the streaming request. On error, emits metrics from
  `initial_handle.request_context` (a `%RequestContext{}`) directly
  — all per-finalization values live on the request context, not on
  a separate wrapper struct. `conversation_id` is passed explicitly
  so the error path can touch the conversation without reading the
  handle. On success, returns `{:ok, final_handle, response}`.
  """
  @spec do_stream(Req.Request.t(), StreamHandler.handle(), integer(), String.t()) ::
          {:ok, StreamHandler.handle(), Req.Response.t()} | {:error, term()}
  def do_stream(request, initial_handle, backend_start, conversation_id)
      when is_integer(backend_start) and is_binary(conversation_id) do
    handle_agent = Process.get({__MODULE__, :handle_agent})
    start_agent = Process.get({__MODULE__, :start_agent})

    case Req.request(request) do
      {:ok, response} ->
        final_handle =
          if handle_agent, do: Agent.get(handle_agent, & &1), else: initial_handle

        cleanup_agents(handle_agent, start_agent)
        {:ok, final_handle, response}

      {:error, reason} ->
        cleanup_agents(handle_agent, start_agent)

        Logger.error("Backend stream request failed: #{inspect(reason)}")
        Conversation.touch(conversation_id)

        ctx = initial_handle.request_context

        Metrics.emit_error(
          ctx.started,
          source_provider: ctx.source_provider,
          target_provider: ctx.config.name,
          request_path: ctx.source_path,
          method: ctx.method,
          streaming: ctx.streaming,
          error_type: :stream_error,
          error_message: inspect(reason),
          pii_info: ctx.pii_info,
          pii_duration: ctx.timings.pii_duration,
          source_conversion_duration: ctx.timings.source_conversion_duration,
          target_conversion_duration: ctx.timings.target_conversion_duration,
          conversation_id: conversation_id
        )

        {:error, reason}
    end
  end

  defp cleanup_agents(handle_agent, start_agent) do
    if handle_agent, do: Agent.stop(handle_agent)
    if start_agent, do: Agent.stop(start_agent)
    Process.delete({__MODULE__, :handle_agent})
    Process.delete({__MODULE__, :start_agent})
  end
end
