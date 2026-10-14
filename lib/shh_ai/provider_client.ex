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

  alias ShhAi.{
    ApiConverter,
    Config,
    Conversation,
    ErrorClass,
    Metrics,
    PIIPipeline,
    TargetProvider
  }

  alias ShhAi.Conversation.Fingerprinter
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
  Makes a request to the conversation's pinned provider instance, or — on a
  fresh conversation — the model-aware selection for the request's `model`
  (ADR-0013), with automatic format conversion and PII sanitization. Returns
  `{:ok, response}` or `{:error, reason}`; a `model` no configured provider
  instance serves yields `{:error, {:model_not_served, model}}`.
  """
  @spec request(
          provider(),
          String.t(),
          String.t(),
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
        # First attempt; a connection-class failure falls back inside
        # `attempt/2` (issue #72).
        attempt(ctx, [])

      {:error, reason} = error ->
        log_request_error(reason)
        error
    end
  end

  @doc """
  Makes a streaming request to the conversation's pinned provider instance,
  or — on a fresh conversation — the model-aware selection for the request's
  `model` (ADR-0013), and chunks the response to the given Plug.Conn. Returns
  `{:ok, conn}` or `{:error, reason}`.
  """
  @spec stream(
          Plug.Conn.t(),
          function(),
          provider(),
          String.t(),
          String.t(),
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
        perform_stream(conn, stream_fun, ctx, [])

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

    source_converter = ApiConverter.get_converter(source_provider)
    request_time = started_to_request_time(started)

    with {:ok, parsed_body} <- parse_body(body),
         {:ok, prepared} <-
           prepare_request(
             source_provider,
             source_converter,
             headers,
             parsed_body,
             source_path,
             request_time
           ) do
      ctx =
        struct!(
          RequestContext,
          Map.merge(prepared, %{
            source_provider: source_provider,
            source_path: source_path,
            method: method,
            source_converter: source_converter,
            streaming: streaming,
            started: started
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
         headers,
         parsed_body,
         source_path,
         request_time
       ) do
    {{openai_headers, openai_body}, source_conversion_duration} =
      with_timing(fn ->
        source_converter.to_openai_request(headers, parsed_body, source_path)
      end)

    pii_start = mono_time()

    with {:ok, conversation} <- find_or_create_conversation(openai_body, source_provider, headers),
         {:ok, {_idx, target_provider, config} = named_provider} <-
           TargetProvider.resolve(conversation, openai_body),
         {:ok, %SanitizationResult{} = result} <-
           PIIPipeline.sanitize_openai_request(openai_body, conversation,
             request_time: request_time
           ) do
      provider_instance = Config.provider_instance(named_provider)
      target_converter = ApiConverter.get_converter(target_provider)
      target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

      pii_end = mono_time()
      pii_duration = pii_end - pii_start

      # Reconstruct the full sanitized body for the target converter.
      # SanitizationResult.sanitized_messages contains only the messages list;
      # we re-inject it into the original body shape here. The result is kept
      # on the context so a connection-failure retry can re-run only the
      # target-dialect conversion (issue #72).
      sanitized_body = reconstruct_sanitized_body(openai_body, result)

      {{target_headers, target_body}, target_conversion_duration} =
        with_timing(fn ->
          target_converter.from_openai_request(openai_headers, sanitized_body, target_path)
        end)

      # Built from the *resolved* instance's config, so the credential sent
      # outbound is the selected/pinned instance's own `api_key` (ADR-0013).
      final_headers = HTTPTransport.build_headers(target_provider, target_headers, config)

      timings = %{
        pii_duration: pii_duration,
        source_conversion_duration: source_conversion_duration,
        target_conversion_duration: target_conversion_duration
      }

      prepared = %{
        provider_instance: provider_instance,
        attempt_instance: provider_instance,
        target_provider: target_provider,
        target_converter: target_converter,
        target_path: target_path,
        config: config,
        final_headers: final_headers,
        conversation: conversation,
        openai_body: openai_body,
        openai_headers: openai_headers,
        sanitized_body: sanitized_body,
        mapping: result.mapping,
        reverse_index: result.reverse_index,
        pii_info: result.pii_info,
        target_headers: target_headers,
        target_body: target_body,
        timings: timings,
        sanitized_messages: result.sanitized_messages
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
    assistant_msg = PIIPipeline.extract_assistant_message(openai_response)
    restored_assistant = PIIPipeline.extract_assistant_message(restored_openai)
    request_time = started_to_request_time(ctx.started)

    # Compute first-exchange fingerprint and derive conversation_id.
    # The fingerprint is taken over the *restored* assistant message so it
    # matches the client-visible messages a subsequent turn will send back
    # (including any tool-call arguments). When there are fewer than 2
    # messages (e.g. empty body), fall back to the existing conversation_id
    # from find_or_create.
    {fingerprint, conversation_id} =
      Fingerprinter.fingerprint_conversation_id(
        messages ++ [restored_assistant],
        ctx.conversation.conversation_id
      )

    assistant_hash =
      restored_assistant
      |> Map.put("role", "assistant")
      |> Fingerprinter.hash_message()

    # Build sanitized_messages: user messages from pipeline + assistant
    sanitized_messages = ctx.sanitized_messages ++ [assistant_msg]

    {:ok, conversation_id} =
      Conversation.persist_turn(
        conversation: %{ctx.conversation | conversation_id: conversation_id},
        sanitized_messages: sanitized_messages,
        assistant_message_hash: assistant_hash,
        mapping: ctx.mapping,
        reverse_index: ctx.reverse_index,
        request_time: request_time,
        fingerprint: fingerprint,
        # The pin is the *first* attempt's resolution (issue #72): a
        # success-after-retry leaves it untouched, so the conversation stays
        # on the Provider Instance the selection/pin chose and retry never
        # re-pins.
        pinned_provider: ctx.provider_instance
      )

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

  defp handle_request_error(reason, %RequestContext{} = ctx, tried) do
    Conversation.touch(ctx.conversation.conversation_id)

    if retryable_failure?(reason) do
      retry_elsewhere(reason, ctx, tried)
    else
      emit_request_failure(ctx, reason)
      {:error, reason}
    end
  end

  # Records one bounded failure class for the request. `ErrorClass.classify/1`
  # never returns message content, so a persisted `error_message` can't leak a
  # raw reason or request detail (issue #56).
  defp emit_request_failure(%RequestContext{} = ctx, reason) do
    Metrics.emit_error_for_context(
      ctx,
      %{
        error_type: :request_error,
        error_message: ErrorClass.to_string(reason),
        conversation_id: ctx.conversation.conversation_id
      }
    )
  end

  # Connection-class transport failure only (issue #72, ADR-0013 §5).
  # Req surfaces transport errors as `%Req.TransportError{}` and Finch's
  # Mint layer may raise `%Mint.TransportError{}` — both carry the same
  # reason set. Receive-timeouts are deliberately excluded: they are hard
  # errors, and provider HTTP 4xx/5xx never reach here at all (they are
  # `{:ok, response}`), so the provider's answer is never hidden and the
  # request is never double-billed. Derived from `ErrorClass` so the two
  # cannot drift.
  @connection_failure_reasons ErrorClass.connection_failure_reasons()

  defguardp is_connection_failure(reason)
            when is_struct(reason, Req.TransportError) or is_struct(reason, Mint.TransportError)

  defp retryable_failure?(reason) when is_connection_failure(reason) do
    reason.reason in @connection_failure_reasons
  end

  defp retryable_failure?(_reason), do: false

  # Fall back once and again across the other Provider Instances serving the
  # model (random, excluding already-tried) until one succeeds or the capable
  # pool is exhausted. Only the target-dialect conversion re-runs per new
  # target — the sanitised canonical body and conversation mapping are reused,
  # so detection never re-runs. The pin belongs to the *first* attempt
  # (`ctx.provider_instance`) and is never mutated by a retry; only
  # `ctx.attempt_instance` tracks the Provider Instance currently being tried.
  defp retry_elsewhere(_reason, %RequestContext{} = ctx, tried) do
    case resolve_retry_context(ctx, tried) do
      {:ok, retry_ctx} ->
        attempt(retry_ctx, tried)

      {:error, reason} = error ->
        emit_request_failure(ctx, reason)
        error
    end
  end

  # Shared by both retry paths: resolve the next untried Provider Instance for
  # the request's model and rebuild the attempt context for it, or return the
  # terminal `{:error, {:pool_exhausted, model}}` with the request's model
  # attached (issue #72).
  defp resolve_retry_context(%RequestContext{} = ctx, tried) do
    case TargetProvider.resolve_alternate(ctx.openai_body, tried) do
      {:ok, named_provider} -> {:ok, build_retry_context(ctx, named_provider)}
      {:error, {:pool_exhausted, _model}} = exhausted -> exhausted
    end
  end

  # Rebuilds the attempt context for a new target Provider Instance: the
  # target-dialect
  # conversion (headers + body + path) re-runs for the new converter, while
  # the canonical request state (sanitised body, mapping, conversation,
  # source side) and the first-attempt pin are carried over untouched.
  defp build_retry_context(%RequestContext{} = ctx, {_idx, target_provider, config} = named) do
    target_converter = ApiConverter.get_converter(target_provider)

    target_path =
      ApiConverter.get_target_path(ctx.source_path, ctx.source_provider, target_provider)

    {{target_headers, target_body}, target_conversion_duration} =
      with_timing(fn ->
        target_converter.from_openai_request(
          ctx.openai_headers,
          ctx.sanitized_body,
          target_path
        )
      end)

    final_headers = HTTPTransport.build_headers(target_provider, target_headers, config)

    %{
      ctx
      | target_provider: target_provider,
        attempt_instance: Config.provider_instance(named),
        target_converter: target_converter,
        target_path: target_path,
        config: config,
        target_headers: target_headers,
        target_body: target_body,
        final_headers: final_headers,
        timings: %{ctx.timings | target_conversion_duration: target_conversion_duration}
    }
  end

  # One Provider Instance attempt: the HTTP call plus the retry hand-off on
  # failure. `tried` counts only genuine attempts — this call's target is
  # appended before any further fallback is considered.
  defp attempt(%RequestContext{} = ctx, tried) do
    url = HTTPTransport.build_url(ctx.config.base_url, ctx.target_path)
    backend_start = mono_time()

    case http_client().do_request(
           ctx.method,
           url,
           ctx.target_body,
           ctx.final_headers,
           ctx.config.timeout
         ) do
      {:ok, response} ->
        handle_request_success(response, ctx, backend_start)

      {:error, reason} ->
        handle_request_error(reason, ctx, [ctx.attempt_instance | tried])
    end
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
  defp perform_stream(conn, stream_fun, %RequestContext{} = ctx, tried) do
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
      {:ok, final_handle, _response} ->
        {:ok, final_handle.conn}

      # Only a connection-class failure before the first byte is retried;
      # `{:error, {:stream_failed_after_first_byte, reason}}` and every
      # other error terminate the stream (issue #72).
      {:error, reason} ->
        tried = [ctx.attempt_instance | tried]

        case retry_stream(conn, stream_fun, ctx, reason, tried) do
          {:retry, retry_ctx} -> perform_stream(conn, stream_fun, retry_ctx, tried)
          error -> error
        end
    end
  end

  # Streaming retry decision (issue #72): the stream may be restarted only
  # when the failure was a connection-class transport error before the first
  # byte reached the client. A mid-stream failure
  # (`{:stream_failed_after_first_byte, _}`) terminates the stream — no
  # silent restart, no duplicated chunks. Returns `{:retry, ctx}` with the
  # context rebuilt for the next Provider Instance, or the terminal error.
  defp retry_stream(_conn, _stream_fun, %RequestContext{} = ctx, reason, tried) do
    if retryable_failure?(reason) do
      case resolve_retry_context(ctx, tried) do
        {:ok, retry_ctx} -> {:retry, retry_ctx}
        {:error, _} = error -> error
      end
    else
      {:error, reason}
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
          method: HTTPTransport.req_method(ctx.method),
          headers: stream_headers,
          body: stream_body,
          receive_timeout: ctx.config.timeout
        ]
    )
  end

  defp log_request_error(reason) do
    Logger.error("ProviderClient request failed: #{inspect(reason)}")
  end

  defp find_or_create_conversation(parsed_body, source_provider, headers) do
    messages = extract_messages(parsed_body)
    provider_conversation_id = extract_provider_id(parsed_body)
    opt_out = Enum.any?(headers, fn {k, _} -> String.downcase(k) == "x-no-audit" end)

    Conversation.find_or_create(messages, %{
      provider_conversation_id: provider_conversation_id,
      source_provider: source_provider,
      opted_out: opt_out
    })
  end

  defp extract_provider_id(body) when not is_map(body), do: nil
  defp extract_provider_id(%{"thread_id" => id}) when is_binary(id), do: id
  defp extract_provider_id(%{"conversation" => id}) when is_binary(id), do: id
  defp extract_provider_id(_), do: nil

  defp extract_messages(body) when is_map(body), do: body["messages"] || []
  defp extract_messages(_), do: []

  # Convert the `started.system` microseconds timestamp to a
  # NaiveDateTime suitable for the cold-store audit rows.
  defp started_to_request_time(%{system: system_us}) do
    DateTime.from_unix!(system_us, :microsecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
  end

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
