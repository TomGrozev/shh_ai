defmodule ShhAi.ProviderClient.StreamTransport do
  @moduledoc false

  require Logger

  alias ShhAi.Conversation
  alias ShhAi.Metrics
  alias ShhAi.ProviderClient.HTTPTransport
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.RequestMeta

  @doc """
  Builds the streaming `Req.Request` with an `into:` callback that
  dispatches each chunk to `StreamHandler.handle_chunk/3`.

  `handle` is the opaque handle produced by `StreamHandler.init/1` and
  owns the streaming lifecycle (per-chunk accumulator, PII restore state,
  Plug.Conn). `request_meta` is the per-finalization spec; it is held
  in a process-local mutable ref so the per-chunk callback can pass it
  through to `finalize/2` at done time. `base_request` is expected to
  come from `Req.new(HTTPTransport.base_request_opts())` so
  connection-pool config stays in sync.

  The handle and request_meta are held in Agents so the `into:`
  callback can update the handle's `conn`/`accumulator`/`pii_state` on
  each chunk (immutable handle struct; need a mutable cell). When
  `handle_chunk/3` signals `done?` true, the callback calls
  `StreamHandler.finalize/2` with the request_meta. The agents are
  stopped after the request completes — see `do_stream/3`.
  """
  @spec build_stream_request(
          StreamHandler.handle(),
          RequestMeta.t(),
          map(),
          Req.Request.t()
        ) :: Req.Request.t()
  def build_stream_request(handle, request_meta, request_fields, base_request) do
    stream_body = HTTPTransport.stream_encode_body(request_fields.body)

    headers =
      Enum.reject(request_fields.headers, fn {k, _v} -> k in ["connection"] end) ++
        [{"accept", "text/event-stream"}]

    # Store the handle and request_meta in Agents so the into: callback
    # can update the handle on each chunk and call finalize with the
    # request_meta on done.
    {:ok, handle_agent} = Agent.start_link(fn -> handle end)
    {:ok, meta_agent} = Agent.start_link(fn -> request_meta end)
    Process.put({__MODULE__, :handle_agent}, handle_agent)
    Process.put({__MODULE__, :meta_agent}, meta_agent)

    Req.merge(base_request,
      url: request_fields.url,
      method: request_fields.method,
      headers: headers,
      body: stream_body,
      receive_timeout: request_fields.timeout,
      into: fn {:data, chunk}, {req, resp} ->
        current = Agent.get(handle_agent, & &1)
        result = StreamHandler.handle_chunk(current, chunk, nil)

        case result do
          {:cont, new_handle, true} ->
            Agent.update(handle_agent, fn _ -> new_handle end)
            meta = Agent.get(meta_agent, & &1)
            {:ok, _final_handle, _final_id} = StreamHandler.finalize(new_handle, meta)
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
  `request_meta` (per-finalization spec) — `StreamTransport` does not
  read handle fields. `conversation_id` is passed explicitly so the
  error path can touch the conversation without reading the handle.
  On success, returns `{:ok, final_handle, response}`.
  """
  @spec do_stream(Req.Request.t(), StreamHandler.handle(), RequestMeta.t(), String.t()) ::
          {:ok, StreamHandler.handle(), Req.Response.t()} | {:error, term()}
  def do_stream(request, initial_handle, %RequestMeta{} = request_meta, conversation_id)
      when is_binary(conversation_id) do
    handle_agent = Process.get({__MODULE__, :handle_agent})
    meta_agent = Process.get({__MODULE__, :meta_agent})

    case Req.request(request) do
      {:ok, response} ->
        final_handle =
          if handle_agent, do: Agent.get(handle_agent, & &1), else: initial_handle

        cleanup_agents(handle_agent, meta_agent)
        {:ok, final_handle, response}

      {:error, reason} ->
        cleanup_agents(handle_agent, meta_agent)

        Logger.error("Backend stream request failed: #{inspect(reason)}")
        Conversation.touch(conversation_id)

        Metrics.emit_error(
          %{monotonic: request_meta.start_time, system: request_meta.started_at},
          source_provider: request_meta.metrics_opts[:source_provider],
          target_provider: request_meta.metrics_opts[:target_provider],
          request_path: request_meta.metrics_opts[:request_path],
          method: request_meta.metrics_opts[:method],
          streaming: request_meta.metrics_opts[:streaming],
          error_type: :stream_error,
          error_message: inspect(reason),
          pii_info: request_meta.pii_info,
          pii_duration: request_meta.pre_stream_timings.pii_duration,
          source_conversion_duration: request_meta.pre_stream_timings.source_conversion_duration,
          target_conversion_duration: request_meta.pre_stream_timings.target_conversion_duration,
          conversation_id: conversation_id
        )

        {:error, reason}
    end
  end

  defp cleanup_agents(handle_agent, meta_agent) do
    if handle_agent, do: Agent.stop(handle_agent)
    if meta_agent, do: Agent.stop(meta_agent)
    Process.delete({__MODULE__, :handle_agent})
    Process.delete({__MODULE__, :meta_agent})
  end

  @doc """
  Ensures the Plug.Conn is in `:chunked` state. On first call, sends the
  chunked response headers; subsequent calls are a no-op.
  """
  @spec init_stream(Plug.Conn.t(), Req.Response.t()) :: Plug.Conn.t()
  def init_stream(%{state: :chunked} = conn, _resp), do: conn

  def init_stream(conn, resp) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(resp.status)
  end
end
