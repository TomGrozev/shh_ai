defmodule ShhAi.BackendClient.StreamTransport do
  @moduledoc false

  require Logger

  alias ShhAi.BackendClient.HTTPTransport
  alias ShhAi.BackendClient.MetricsEmitter
  alias ShhAi.Conversation

  @doc """
  Builds the streaming `Req.Request` with an `into:` callback that dispatches
  each chunk to `BackendClient.handle_stream_chunk/4`.

  `base_request` is expected to come from `Req.new(HTTPTransport.base_request_opts())`
  so connection-pool config stays in sync.
  """
  @spec build_stream_request(map(), map(), Req.Request.t()) :: Req.Request.t()
  def build_stream_request(ctx, request_fields, base_request) do
    stream_body = HTTPTransport.stream_encode_body(request_fields.body)

    headers =
      Enum.reject(request_fields.headers, fn {k, _v} -> k in ["connection"] end) ++
        [{"accept", "text/event-stream"}]

    Req.merge(base_request,
      url: request_fields.url,
      method: request_fields.method,
      headers: headers,
      body: stream_body,
      receive_timeout: request_fields.timeout,
      into: fn
        {:data, ""}, {req, resp} ->
          {:cont, {req, resp}}

        {:data, chunk}, {req, resp} ->
          ShhAi.BackendClient.handle_stream_chunk(chunk, req, resp, ctx)
      end
    )
  end

  @doc """
  Executes the streaming request. On error, emits metrics and touches the
  conversation before returning.
  """
  @spec do_stream(Req.Request.t(), map()) :: {:ok, Req.Response.t()} | {:error, term()}
  def do_stream(request, ctx) do
    case Req.request(request) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("Backend stream request failed: #{inspect(reason)}")
        Conversation.touch(ctx.conversation.conversation_id)

        now = System.monotonic_time(:microsecond)

        measurements =
          MetricsEmitter.build_measurements(
            duration: now - ctx.start_time,
            pii_duration: ctx.pre_stream_timings.pii_duration,
            source_conversion_duration: ctx.pre_stream_timings.source_conversion_duration,
            target_conversion_duration: ctx.pre_stream_timings.target_conversion_duration,
            backend_duration: 0,
            restore_duration: 0,
            pii_info: ctx.pii_info
          )

        metadata =
          MetricsEmitter.build_metadata(
            source_provider: ctx.metrics_opts[:source_provider],
            target_provider: ctx.metrics_opts[:target_provider],
            request_path: ctx.metrics_opts[:request_path],
            method: ctx.metrics_opts[:method],
            streaming: ctx.metrics_opts[:streaming],
            started_at: ctx.started_at,
            status: 0,
            error: %{type: :stream_error, message: inspect(reason)},
            conversation_id: ctx.conversation.conversation_id
          )

        MetricsEmitter.emit_stop(measurements, metadata)

        {:error, reason}
    end
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

  @doc """
  Dispatches converted chunks to the client via `stream_fun`, updating
  Req response private fields (`:req_conn`, `:pii_state`, `:metrics_context`)
  for the next chunk callback invocation.
  """
  @spec send_chunks_to_conn(
          [term()],
          Plug.Conn.t(),
          Req.Request.t(),
          Req.Response.t(),
          map(),
          map(),
          (term(), Plug.Conn.t() -> {:cont, Plug.Conn.t()} | :halt)
        ) ::
          {:cont, {Req.Request.t(), Req.Response.t()}}
          | {:halt, {Req.Request.t(), Req.Response.t()}}
  def send_chunks_to_conn(chunks, conn, req, resp, pii_state, metrics_context, stream_fun) do
    case stream_chunks_to_conn(chunks, conn, stream_fun) do
      :halt ->
        {:halt, {req, resp}}

      new_conn ->
        new_resp =
          resp
          |> Req.Response.put_private(:req_conn, new_conn)
          |> Req.Response.put_private(:pii_state, pii_state)
          |> Req.Response.put_private(:metrics_context, metrics_context)

        {:cont, {req, new_resp}}
    end
  end

  # Sends each chunk through the stream function. Returns the updated conn
  # or `:halt` if the stream function signals to stop.
  defp stream_chunks_to_conn(chunks, conn, stream_fun) do
    Enum.reduce_while(chunks, conn, fn chunk, conn_inner ->
      case stream_fun.(chunk, conn_inner) do
        {:cont, new_conn} -> {:cont, new_conn}
        :halt -> {:halt, :halt}
      end
    end)
  end
end
