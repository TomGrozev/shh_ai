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
  """

  require Logger

  alias ShhAi.{ApiConverter, Config, Conversation, Metrics, PIIPipeline}
  alias ShhAi.PII.SanitizationResult
  alias ShhAi.ProviderClient.HTTPTransport
  alias ShhAi.ProviderClient.StreamHandler
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
    started = Keyword.get_lazy(opts, :start_time, fn -> Metrics.capture_started() end)
    {_idx, target_provider, config} = Config.select_provider()

    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)
    target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

    with {:ok, parsed_body} <- parse_body(body),
         {:ok, prep} <-
           prepare_request_context(
             source_provider,
             source_converter,
             target_converter,
             headers,
             parsed_body,
             source_path,
             target_path
           ) do
      {:ok, url} = HTTPTransport.build_url(config.base_url, target_path)
      processed_headers = HTTPTransport.build_headers(target_provider, prep.target_headers, config)

      case http_client().do_request(method, url, prep.target_body, processed_headers, config.timeout) do
        {:ok, response} ->
          ctx =
            build_request_context(
              prep,
              config,
              started,
              source_path,
              method,
              source_converter,
              target_converter,
              target_path
            )

          handle_request_success(response, ctx)

        {:error, reason} ->
          handle_request_error(reason, prep, config, started, source_path, method)
      end
    else
      {:error, reason} = error ->
        log_request_error(reason)
        error
    end
  end

  defp build_request_context(
         prep,
         config,
         started,
         request_path,
         request_method,
         source_converter,
         target_converter,
         target_path
       ) do
    %{
      prep: prep,
      config: config,
      started: started,
      request_path: request_path,
      request_method: request_method,
      source_converter: source_converter,
      target_converter: target_converter,
      target_path: target_path
    }
  end

  defp log_request_error(reason) do
    Logger.error("ProviderClient request failed: #{inspect(reason)}")
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
    started = Keyword.get_lazy(opts, :start_time, fn -> Metrics.capture_started() end)
    {_idx, target_provider, config} = Config.select_provider()

    source_converter = ApiConverter.get_converter(source_provider)
    target_converter = ApiConverter.get_converter(target_provider)
    target_path = ApiConverter.get_target_path(source_path, source_provider, target_provider)

    case parse_body(body) do
      {:ok, parsed_body} ->
        case prepare_request_context(
               source_provider,
               source_converter,
               target_converter,
               headers,
               parsed_body,
               source_path,
               target_path
             ) do
          {:ok, prep} ->
            {:ok, url} = HTTPTransport.build_url(config.base_url, target_path)

            processed_headers =
              HTTPTransport.build_headers(target_provider, prep.target_headers, config)

            {handle, request_meta} =
              StreamHandler.init(%{
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
                  request_path: source_path,
                  method: method,
                  streaming: true
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
                mapping: prep.mapping,
                reverse_index: prep.reverse_index
              })

            request_fields = %{
              url: url,
              method: method,
              headers: processed_headers,
              body: prep.target_body,
              timeout: config.timeout
            }

            base_request = Req.new(HTTPTransport.base_request_opts())

            request =
              StreamTransport.build_stream_request(
                handle,
                request_meta,
                request_fields,
                base_request
              )

            case StreamTransport.do_stream(
                   request,
                   handle,
                   request_meta,
                   prep.conversation.conversation_id
                 ) do
              {:ok, final_handle, _response} -> {:ok, final_handle.conn}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            Logger.error("ProviderClient stream failed early: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("ProviderClient stream failed: invalid body: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — request pipeline
  # ---------------------------------------------------------------------------

  defp now, do: System.monotonic_time(:microsecond)

  defp prepare_request_context(
         source_provider,
         source_converter,
         target_converter,
         headers,
         parsed_body,
         source_path,
         target_path
       ) do
    conversion_start = now()

    {openai_headers, openai_body} =
      source_converter.to_openai_request(headers, parsed_body, source_path)

    conversion_end = now()

    pii_start = now()

    with {:ok, conversation} <- find_or_create_conversation(openai_body, source_provider),
         {:ok, %SanitizationResult{} = result} <-
           PIIPipeline.sanitize_openai_request(openai_body, conversation) do
      pii_end = now()
      target_start = now()

      # Reconstruct the full sanitized body for the target converter.
      # SanitizationResult.sanitized_messages contains only the messages list;
      # we re-inject it into the original body shape here.
      sanitized_body = reconstruct_sanitized_body(openai_body, result)

      {target_headers, target_body} =
        target_converter.from_openai_request(openai_headers, sanitized_body, target_path)

      target_end = now()

      {:ok,
       %{
         conversation: conversation,
         openai_body: openai_body,
         mapping: result.mapping,
         reverse_index: result.reverse_index,
         pii_info: result.pii_info,
         target_headers: target_headers,
         target_body: target_body,
         source_conversion_duration: conversion_end - conversion_start,
         pii_duration: pii_end - pii_start,
         target_conversion_duration: target_end - target_start
       }}
    end
  end

  defp handle_request_success(response, ctx) do
    prep = ctx.prep
    config = ctx.config
    started = ctx.started
    request_path = ctx.request_path
    request_method = ctx.request_method
    source_converter = ctx.source_converter
    target_converter = ctx.target_converter
    target_path = ctx.target_path
    openai_body = prep.openai_body

    backend_end_response_start = now()
    openai_response = target_converter.to_openai_response(response.body, target_path)

    {:ok, restored_openai} =
      PIIPipeline.restore_openai_response(openai_response, prep.conversation,
        mapping: prep.mapping
      )

    source_response =
      source_converter.from_openai_response(restored_openai, request_path)

    restore_end = now()

    messages = extract_messages(openai_body)
    all_messages = messages ++ [PIIPipeline.extract_assistant_message(openai_response)]

    conversation_id =
      if prep.conversation.new? do
        Conversation.persist_turn_1(
          prep.conversation,
          all_messages,
          prep.mapping,
          prep.reverse_index
        )
      else
        Conversation.finalize_response(prep.conversation, all_messages)
      end

    backend_start =
      started.monotonic + prep.pii_duration + prep.source_conversion_duration +
        prep.target_conversion_duration

    Metrics.emit_success(
      duration: restore_end - started.monotonic,
      pii_duration: prep.pii_duration,
      source_conversion_duration: prep.source_conversion_duration,
      target_conversion_duration: prep.target_conversion_duration,
      backend_duration: backend_end_response_start - backend_start,
      restore_duration: restore_end - backend_end_response_start,
      pii_info: prep.pii_info,
      source_provider: prep.conversation.source_provider,
      target_provider: config.name,
      request_path: request_path,
      method: request_method,
      streaming: false,
      started_at: started.system,
      status: response.status,
      conversation_id: conversation_id
    )

    {:ok, %{response | body: source_response}}
  end

  defp handle_request_error(
         reason,
         prep,
         config,
         started,
         request_path,
         request_method
       ) do
    Conversation.touch(prep.conversation.conversation_id)

    Metrics.emit_error(started,
      source_provider: prep.conversation.source_provider,
      target_provider: config.name,
      request_path: request_path,
      method: request_method,
      streaming: false,
      error_type: :request_error,
      error_message: inspect(reason),
      pii_info: prep.pii_info,
      conversation_id: prep.conversation.conversation_id
    )

    {:error, reason}
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
