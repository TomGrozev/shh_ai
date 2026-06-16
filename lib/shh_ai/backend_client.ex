defmodule ShhAi.BackendClient do
  @moduledoc """
  HTTP client for LLM backend providers.
  Uses Req with Finch connection pooling for high performance.
  Supports OpenAI, Anthropic, and Ollama APIs with automatic format conversion.

  ## PII Sanitization Pipeline

  All PII operations happen in OpenAI (canonical) format:

      Request (source format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  This ensures consistent PII handling regardless of source/target provider formats.
  """

  require Logger

  alias ShhAi.Config
  alias ShhAi.ApiConverter
  alias ShhAi.PIIPipeline
  alias ShhAi.Conversation

  alias ShhAi.BackendClient.HTTPTransport
  alias ShhAi.BackendClient.StreamTransport
  alias ShhAi.BackendClient.FingerprintMigration
  alias ShhAi.BackendClient.MetricsEmitter
  alias ShhAi.BackendClient.SSEParser
  alias ShhAi.BackendClient.ConversationHelpers

  defmodule StreamContext do
    @moduledoc false
    defstruct [
      :conn,
      :stream_fun,
      :source_provider,
      :source_path,
      :method,
      :conversation,
      :start_time,
      :started_at,
      :backend_start,
      :metrics_opts,
      :pii_info,
      :pre_stream_timings,
      :openai_body,
      :source_converter,
      :target_converter,
      :mapping
    ]
  end

  @type provider :: :openai | :anthropic | :ollama
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t() | map()
        }

  @doc """
  Makes a request to a randomly selected LLM provider with automatic format
  conversion and PII sanitization. Returns `{:ok, response, measurements}` or
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
          {:ok, response(), map()} | {:error, term()}
  def request(source_provider, source_path, method, body, headers, opts \\ []) do
    started = resolve_start_time(opts)
    request_path = Keyword.get(opts, :request_path, source_path)
    request_method = Keyword.get(opts, :method, "POST")
    streaming = Keyword.get(opts, :streaming, false)
    {_idx, target_provider, config} = Config.select_provider()

    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)
    target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

    case prepare_request_context(
           source_provider,
           source_converter,
           target_converter,
           headers,
           parse_body(body),
           source_path,
           target_path
         ) do
      {:ok, prep} ->
        {:ok, url} = HTTPTransport.build_url(config.base_url, target_path)

        processed_headers =
          HTTPTransport.build_headers(target_provider, prep.target_headers, config)

        case HTTPTransport.do_request(
               method,
               url,
               prep.target_body,
               processed_headers,
               config.timeout
             ) do
          {:ok, response} ->
            handle_request_success(
              response,
              prep,
              config,
              started,
              request_path,
              request_method,
              streaming
            )

          {:error, reason} ->
            handle_request_error(
              reason,
              prep,
              config,
              started,
              request_path,
              request_method,
              streaming
            )
        end

      {:error, reason} ->
        Logger.error("BackendClient request failed early: #{inspect(reason)}")
        {:error, reason}
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
    started = resolve_start_time(opts)
    request_path = Keyword.get(opts, :request_path, source_path)
    request_method = Keyword.get(opts, :method, "POST")
    streaming = Keyword.get(opts, :streaming, true)
    {_idx, target_provider, config} = Config.select_provider()

    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)
    target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

    case prepare_request_context(
           source_provider,
           source_converter,
           target_converter,
           headers,
           parse_body(body),
           source_path,
           target_path
         ) do
      {:ok, prep} ->
        mapping = ConversationHelpers.get_mapping(prep.conversation)
        {:ok, url} = HTTPTransport.build_url(config.base_url, prep.target_path)

        processed_headers =
          HTTPTransport.build_headers(target_provider, prep.target_headers, config)

        ctx = %StreamContext{
          conn: conn,
          stream_fun: stream_fun,
          source_provider: source_provider,
          source_path: source_path,
          method: method,
          conversation: prep.conversation,
          start_time: started.monotonic,
          started_at: started.system,
          backend_start: System.monotonic_time(:microsecond),
          metrics_opts: %{
            source_provider: source_provider,
            target_provider: config.name,
            request_path: request_path,
            method: request_method,
            streaming: streaming
          },
          pii_info: prep.pii_info,
          pre_stream_timings: %{
            pii_duration: prep.pii_duration,
            source_conversion_duration: prep.source_conversion_duration,
            target_conversion_duration: prep.target_conversion_duration
          },
          openai_body: prep.openai_body,
          source_converter: source_converter,
          target_converter: target_converter,
          mapping: mapping
        }

        request_fields = %{
          url: url,
          method: method,
          headers: processed_headers,
          body: prep.target_body,
          timeout: config.timeout
        }

        base_request = Req.new(HTTPTransport.base_request_opts())
        request = StreamTransport.build_stream_request(ctx, request_fields, base_request)
        StreamTransport.do_stream(request, ctx)

      {:error, reason} ->
        Logger.error("BackendClient stream failed early: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Stream chunk handler (public — called by StreamTransport's `into:` callback)
  # ---------------------------------------------------------------------------

  @doc false
  def handle_stream_chunk(chunk, req, resp, ctx) do
    pii_state = Req.Response.get_private(resp, :pii_state, %{})
    metrics_ctx = Req.Response.get_private(resp, :metrics_context, build_initial_metrics(ctx))

    a_conn =
      Req.Response.get_private(resp, :req_conn, ctx.conn) |> StreamTransport.init_stream(resp)

    if resp.status >= 400, do: Logger.debug("Bad response from backend: #{inspect(chunk)}")

    restore_start = System.monotonic_time(:microsecond)

    {converted_chunks, new_pii_state, done?, openai_chunks} =
      convert_and_restore_stream_chunk(
        chunk,
        ctx.target_converter,
        ctx.source_converter,
        ctx.source_path,
        ctx.mapping,
        pii_state
      )

    chunk_content = SSEParser.extract_content_from_openai_chunks(openai_chunks)
    restore_end = System.monotonic_time(:microsecond)

    metrics_ctx =
      metrics_ctx
      |> Map.update!(:restore_duration, &(&1 + restore_end - restore_start))
      |> Map.update!(:assistant_content, &(&1 <> chunk_content))

    metrics_ctx = if done?, do: finalize_stream(metrics_ctx, resp.status, ctx), else: metrics_ctx

    StreamTransport.send_chunks_to_conn(
      converted_chunks,
      a_conn,
      req,
      resp,
      new_pii_state,
      metrics_ctx,
      ctx.stream_fun
    )
  end

  # ---------------------------------------------------------------------------
  # Private — request pipeline
  # ---------------------------------------------------------------------------

  defp resolve_start_time(opts) do
    case Keyword.get(opts, :start_time) do
      %{} = started ->
        started

      monotonic when is_integer(monotonic) ->
        # backward-compat: someone passed a raw monotonic time
        %{
          monotonic: monotonic,
          system:
            System.system_time(:microsecond) - (System.monotonic_time(:microsecond) - monotonic)
        }

      nil ->
        MetricsEmitter.now()
    end
  end

  defp prepare_request_context(
         source_provider,
         source_converter,
         target_converter,
         headers,
         parsed_body,
         source_path,
         target_path
       ) do
    conversion_start = System.monotonic_time(:microsecond)

    {openai_headers, openai_body} =
      source_converter.to_openai_request(headers, parsed_body, source_path)

    conversion_end = System.monotonic_time(:microsecond)

    pii_start = System.monotonic_time(:microsecond)

    with {:ok, conversation} <- ConversationHelpers.find_or_create(openai_body, source_provider),
         {:ok, sanitized_body, mapping, _ri, pii_info} <-
           PIIPipeline.sanitize_openai_request(openai_body, conversation) do
      pii_end = System.monotonic_time(:microsecond)
      target_start = System.monotonic_time(:microsecond)

      {target_headers, target_body} =
        target_converter.from_openai_request(openai_headers, sanitized_body, target_path)

      target_end = System.monotonic_time(:microsecond)

      {:ok,
       %{
         conversation: conversation,
         openai_body: openai_body,
         mapping: mapping,
         pii_info: pii_info,
         target_headers: target_headers,
         target_body: target_body,
         target_path: target_path,
         source_converter: source_converter,
         target_converter: target_converter,
         source_path: source_path,
         source_conversion_duration: conversion_end - conversion_start,
         pii_duration: pii_end - pii_start,
         target_conversion_duration: target_end - target_start
       }}
    end
  end

  defp handle_request_success(
         response,
         prep,
         config,
         started,
         request_path,
         request_method,
         streaming
       ) do
    backend_end = System.monotonic_time(:microsecond)
    restore_start = System.monotonic_time(:microsecond)
    openai_response = prep.target_converter.to_openai_response(response.body, prep.target_path)

    {:ok, restored_openai} =
      PIIPipeline.restore_openai_response(openai_response, prep.conversation)

    source_response =
      prep.source_converter.from_openai_response(restored_openai, prep.source_path)

    restore_end = System.monotonic_time(:microsecond)

    conversation_id =
      ConversationHelpers.update_fingerprint(prep.conversation, prep.openai_body, openai_response)

    Conversation.touch(conversation_id)

    backend_start =
      started.monotonic + prep.pii_duration + prep.source_conversion_duration +
        prep.target_conversion_duration

    measurements =
      MetricsEmitter.build_measurements(
        duration: restore_end - started.monotonic,
        pii_duration: prep.pii_duration,
        source_conversion_duration: prep.source_conversion_duration,
        target_conversion_duration: prep.target_conversion_duration,
        backend_duration: backend_end - backend_start,
        restore_duration: restore_end - restore_start,
        pii_info: prep.pii_info
      )

    metadata =
      MetricsEmitter.build_metadata(
        source_provider: prep.conversation.source_provider,
        target_provider: config.name,
        request_path: request_path,
        method: request_method,
        streaming: streaming,
        started_at: started.system,
        status: response.status,
        conversation_id: conversation_id
      )

    MetricsEmitter.emit_stop(measurements, metadata)
    {:ok, %{response | body: source_response}, measurements}
  end

  defp handle_request_error(
         reason,
         prep,
         config,
         started,
         request_path,
         request_method,
         streaming
       ) do
    Conversation.touch(prep.conversation.conversation_id)

    measurements =
      MetricsEmitter.build_measurements(
        duration: System.monotonic_time(:microsecond) - started.monotonic,
        pii_duration: prep.pii_duration,
        source_conversion_duration: prep.source_conversion_duration,
        target_conversion_duration: prep.target_conversion_duration,
        backend_duration: 0,
        restore_duration: 0,
        pii_info: prep.pii_info
      )

    metadata =
      MetricsEmitter.build_metadata(
        source_provider: prep.conversation.source_provider,
        target_provider: config.name,
        request_path: request_path,
        method: request_method,
        streaming: streaming,
        started_at: started.system,
        status: 0,
        error: %{type: :request_error, message: inspect(reason)},
        conversation_id: prep.conversation.conversation_id
      )

    MetricsEmitter.emit_stop(measurements, metadata)
    {:error, reason}
  end

  # ---------------------------------------------------------------------------
  # Private — stream finalization
  # ---------------------------------------------------------------------------

  defp finalize_stream(metrics_ctx, resp_status, ctx) do
    assistant_message = %{"role" => "assistant", "content" => metrics_ctx.assistant_content}
    full_messages = (metrics_ctx.openai_body["messages"] || []) ++ [assistant_message]
    full_fingerprint = ShhAi.ConversationFingerprinter.fingerprint_messages(full_messages)
    final_id = FingerprintMigration.migrate_or_update(ctx.conversation, full_fingerprint)
    Conversation.cache_assistant_response(final_id, metrics_ctx.assistant_content, ctx.mapping)
    updated = %{metrics_ctx | conversation_id: final_id}
    MetricsEmitter.emit_stream_stop(resp_status, updated, ctx)
    updated
  end

  defp build_initial_metrics(%StreamContext{} = ctx) do
    %{
      start_time: ctx.start_time,
      metrics_opts: ctx.metrics_opts,
      pii_info: ctx.pii_info,
      restore_duration: 0,
      method: ctx.method,
      source_path: ctx.source_path,
      assistant_content: "",
      openai_body: ctx.openai_body,
      conversation_id: ctx.conversation.conversation_id
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

      {:error, _} ->
        {[chunk], pii_state, false, []}

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
        {:done, new_chunks} -> new_chunks
        new_chunks when is_list(new_chunks) -> new_chunks
        _ -> []
      end
    end)
  end

  # Body parsing

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_body(body), do: body
end
