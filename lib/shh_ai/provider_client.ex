defmodule ShhAi.ProviderClient do
  @moduledoc """
  HTTP client for LLM backend providers.
  Uses Req with Finch connection pooling for high performance.
  Supports OpenAI, Anthropic, and Ollama APIs with automatic format conversion.

  ## PII Sanitization Pipeline

  All PII operations happen in OpenAI (canonical) format:

      Request (source format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  This ensures consistent PII handling regardless of source/target provider formats.

  ## Per-request state

  The post-preparation request state is held in a typed
  `ShhAi.ProviderClient.RequestContext{}` struct. Both the request
  (non-streaming) and stream paths build one at the top of their entry
  point and pass it forward. The streaming path additionally nests the
  struct inside a `%StreamHandler.Handle{}` for per-chunk state. See
  `docs/architecture/04-request-context.md` for the design note.
  """

  require Logger

  alias ShhAi.{ApiConverter, Config, Conversation, Metrics, PIIPipeline}
  alias ShhAi.PII.SanitizationResult
  alias ShhAi.PIIPipeline.RestoreState
  alias ShhAi.ProviderClient.HTTPTransport
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.{Accumulator, Handle}
  alias ShhAi.ProviderClient.StreamTransport

  @doc false
  def http_client do
    Application.get_env(:shh_ai, :http_client, HTTPTransport)
  end

  @type provider :: :openai | :anthropic | :ollama
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t() | map()
        }

  @doc """
  Makes a request to a randomly selected LLM provider with automatic format
  conversion and PII sanitization. Returns `{:ok, response}` or
  `{:error, reason}`.
  """
  @spec request(
          provider(),
          String.t(),
          atom(),
          map() | String.t(),
          [{String.t(), String.t()}],
          keyword()
        ) ::
          {:ok, response()} | {:error, term()}
  def request(source_provider, source_path, method, body, headers, opts \\ []) do
    case setup_context(
           source_provider,
           source_path,
           method,
           headers,
           body,
           [streaming: false] ++ opts
         ) do
      {:ok, ctx} ->
        url = HTTPTransport.build_url(ctx.config.base_url, ctx.target_path)

        # Captured immediately before the backend HTTP call so
        # `backend_duration` measures the backend round-trip directly,
        # not as a sum of the pre-stream phases (which would drift if a
        # new timing phase is ever added to `prepare_request`).
        backend_start = mono_time()

        case http_client().do_request(
               method,
               url,
               ctx.target_body,
               ctx.final_headers,
               ctx.config.timeout
             ) do
          {:ok, response} ->
            handle_request_success(response, ctx, backend_start)

          {:error, reason} ->
            handle_request_error(reason, ctx)
        end

      {:error, reason} = error ->
        log_request_error(reason)
        error
    end
  end

  @doc """
  Makes a streaming request to a randomly selected LLM provider and chunks the
  response to the given Plug.Conn. Returns `{:ok, conn}` or `{:error, reason}`.
  """
  @spec stream(
          Plug.Conn.t(),
          function(),
          provider(),
          String.t(),
          atom(),
          map(),
          [{String.t(), String.t()}],
          keyword()
        ) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def stream(conn, stream_fun, source_provider, source_path, method, body, headers, opts \\ []) do
    case setup_context(
           source_provider,
           source_path,
           method,
           headers,
           body,
           [streaming: true] ++ opts
         ) do
      {:ok, ctx} ->
        perform_stream(conn, stream_fun, ctx)

      {:error, reason} ->
        Logger.error("ProviderClient stream failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — request pipeline
  # ---------------------------------------------------------------------------

  defp mono_time, do: System.monotonic_time(:microsecond)

  # Wraps a fun in monotonic-time start/stop. Returns `{result, duration}`.
  defp with_timing(fun) do
    start = mono_time()
    result = fun.()
    finish = mono_time()
    {result, finish - start}
  end

  # Shared context setup for `request/6` and `stream/8`. Returns
  # `{:ok, %RequestContext{}}` carrying the post-preparation request
  # state (source/target provider, paths, method, config, converters,
  # conversation, PII mapping, target headers/body, timings, started
  # timestamp) or `{:error, reason}`.
  #
  # The two entry points diverge only in what they do with the ctx
  # (HTTP request vs. streaming pipeline), so all the boilerplate
  # lives here.
  defp setup_context(source_provider, source_path, method, headers, body, opts) do
    started = Keyword.get_lazy(opts, :start_time, fn -> Metrics.capture_started() end)
    streaming = Keyword.get_lazy(opts, :streaming, fn -> false end)
    {_idx, target_provider, config} = Config.select_provider()

    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)
    target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

    with {:ok, parsed_body} <- parse_body(body),
         {:ok, prepared} <-
           prepare_request(
             source_provider,
             source_converter,
             target_converter,
             headers,
             parsed_body,
             source_path,
             target_path
           ) do
      final_headers =
        HTTPTransport.build_headers(target_provider, prepared.target_headers, config)

      ctx =
        struct!(
          RequestContext,
          Map.merge(prepared, %{
            source_provider: source_provider,
            target_provider: target_provider,
            source_path: source_path,
            target_path: target_path,
            method: method,
            config: config,
            source_converter: source_converter,
            target_converter: target_converter,
            streaming: streaming,
            started: started,
            final_headers: final_headers
          })
        )

      {:ok, ctx}
    end
  end

  # Reconstruct the full sanitized request body from the SanitizationResult.
  # For messages/input bodies, re-injects the sanitized messages into the original body.
  # For non-message bodies (embeddings, moderations), unwraps the single-element list.
  defp reconstruct_sanitized_body(openai_body, %SanitizationResult{sanitized_messages: msgs}) do
    cond do
      is_list(openai_body["messages"]) -> Map.put(openai_body, "messages", msgs)
      is_list(openai_body["input"]) -> Map.put(openai_body, "input", msgs)
      true -> hd(msgs)
    end
  end

  defp prepare_request(
         source_provider,
         source_converter,
         target_converter,
         headers,
         parsed_body,
         source_path,
         target_path
       ) do
    {{openai_headers, openai_body}, source_conversion_duration} =
      with_timing(fn ->
        source_converter.to_openai_request(headers, parsed_body, source_path)
      end)

    pii_start = mono_time()

    with {:ok, conversation} <- find_or_create_conversation(openai_body, source_provider),
         {:ok, %SanitizationResult{} = result} <-
           PIIPipeline.sanitize_openai_request(openai_body, conversation) do
      pii_end = mono_time()
      pii_duration = pii_end - pii_start

      # Reconstruct the full sanitized body for the target converter.
      # SanitizationResult.sanitized_messages contains only the messages list;
      # we re-inject it into the original body shape here.
      sanitized_body = reconstruct_sanitized_body(openai_body, result)

      {{target_headers, target_body}, target_conversion_duration} =
        with_timing(fn ->
          target_converter.from_openai_request(openai_headers, sanitized_body, target_path)
        end)

      timings = %{
        pii_duration: pii_duration,
        source_conversion_duration: source_conversion_duration,
        target_conversion_duration: target_conversion_duration
      }

      prepared = %{
        conversation: conversation,
        openai_body: openai_body,
        mapping: result.mapping,
        reverse_index: result.reverse_index,
        pii_info: result.pii_info,
        target_headers: target_headers,
        target_body: target_body,
        timings: timings
      }

      {:ok, prepared}
    end
  end

  defp handle_request_success(response, %RequestContext{} = ctx, backend_start) do
    backend_end_response_start = mono_time()

    openai_response =
      ctx.target_converter.to_openai_response(response.body, ctx.target_path)

    {:ok, restored_openai} =
      PIIPipeline.restore_openai_response(
        openai_response,
        ctx.conversation,
        mapping: ctx.mapping
      )

    source_response =
      ctx.source_converter.from_openai_response(restored_openai, ctx.source_path)

    restore_end = mono_time()

    messages = extract_messages(ctx.openai_body)
    all_messages = messages ++ [PIIPipeline.extract_assistant_message(openai_response)]

    conversation_id =
      if ctx.conversation.new? do
        Conversation.persist_turn_1(
          ctx.conversation,
          all_messages,
          ctx.mapping,
          ctx.reverse_index
        )
      else
        Conversation.finalize_response(ctx.conversation, all_messages)
      end

    Metrics.emit_success_for_context(
      ctx,
      backend_start,
      %{
        duration: restore_end - ctx.started.monotonic,
        backend_duration: backend_end_response_start - backend_start,
        restore_duration: restore_end - backend_end_response_start,
        status: response.status,
        conversation_id: conversation_id
      }
    )

    {:ok, %{response | body: source_response}}
  end

  defp handle_request_error(reason, %RequestContext{} = ctx) do
    Conversation.touch(ctx.conversation.conversation_id)

    Metrics.emit_error_for_context(
      ctx,
      %{
        error_type: :request_error,
        error_message: inspect(reason),
        conversation_id: ctx.conversation.conversation_id
      }
    )

    {:error, reason}
  end

  # ---------------------------------------------------------------------------
  # Private — streaming pipeline
  # ---------------------------------------------------------------------------

  # Streaming entry point. Splits into 3 named phases so each one can
  # be reasoned about independently:
  #
  #   1. `build_handle/3`     — per-chunk mutable state wrapper.
  #   2. `backend_start`      — monotonic timestamp captured here,
  #      immediately before `StreamTransport.build_stream_request/3`
  #      and `StreamTransport.do_stream/3`. Threaded through to
  #      `StreamHandler.finalize/2` so the streaming
  #      `Metrics.emit_stream_stop/6` can compute `backend_duration`.
  #   3. `build_base_request/1` — the `Req.Request` with url/method/
  #      headers/body/receive_timeout.
  #
  # Then `StreamTransport.build_stream_request/3` wires the
  # `into:` callback that dispatches each chunk to
  # `StreamHandler.handle_chunk/2`, and `StreamTransport.do_stream/4`
  # executes the request. The result is unwrapped to a bare
  # `Plug.Conn` for the entry-point return.
  defp perform_stream(conn, stream_fun, %RequestContext{} = ctx) do
    handle = build_handle(conn, stream_fun, ctx)
    backend_start = mono_time()
    base_request = build_base_request(ctx)

    request =
      StreamTransport.build_stream_request(handle, backend_start, base_request)

    case StreamTransport.do_stream(
           request,
           handle,
           backend_start,
           ctx.conversation.conversation_id
         ) do
      {:ok, final_handle, _response} -> {:ok, final_handle.conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_handle(conn, stream_fun, %RequestContext{} = ctx) do
    # Put the conn into chunked state once at construction time so the
    # per-chunk `handle_chunk/2` hot path doesn't re-check the conn
    # state on every chunk (which would also re-allocate a
    # `%Req.Response{status: 200}` to feed the no-op guard).
    chunked = StreamHandler.chunked_conn(conn)

    %Handle{
      request_context: ctx,
      conn: chunked,
      stream_fun: stream_fun,
      pii_state: RestoreState.new(),
      accumulator: Accumulator.new()
    }
  end

  defp build_base_request(%RequestContext{} = ctx) do
    url = HTTPTransport.build_url(ctx.config.base_url, ctx.target_path)

    # Stream path applies its two extra transformations (filter
    # `connection`, add `accept: text/event-stream`) on top of the
    # shared `ctx.final_headers` already built in `setup_context/6`.
    stream_headers =
      Enum.reject(ctx.final_headers, fn {k, _v} -> k in ["connection"] end) ++
        [{"accept", "text/event-stream"}]

    stream_body = HTTPTransport.stream_encode_body(ctx.target_body)

    Req.new(
      HTTPTransport.base_request_opts() ++
        [
          url: url,
          method: ctx.method,
          headers: stream_headers,
          body: stream_body,
          receive_timeout: ctx.config.timeout
        ]
    )
  end

  defp log_request_error(reason) do
    Logger.error("ProviderClient request failed: #{inspect(reason)}")
  end

  defp find_or_create_conversation(parsed_body, source_provider) do
    messages = extract_messages(parsed_body)
    provider_conversation_id = extract_provider_id(parsed_body)

    Conversation.find_or_create(messages, %{
      provider_conversation_id: provider_conversation_id,
      source_provider: source_provider
    })
  end

  defp extract_provider_id(body) when not is_map(body), do: nil
  defp extract_provider_id(%{"thread_id" => id}) when is_binary(id), do: id
  defp extract_provider_id(%{"conversation" => id}) when is_binary(id), do: id
  defp extract_provider_id(_), do: nil

  defp extract_messages(body) when is_map(body), do: body["messages"] || []
  defp extract_messages(_), do: []

  # Body parsing

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_body(body) when is_map(body), do: {:ok, body}
  defp parse_body(body), do: {:ok, body}
end
