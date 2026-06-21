defmodule ShhAi.PIIPipeline do
  @moduledoc """
  PII sanitization pipeline that works exclusively in OpenAI (canonical) format.

  This module ensures all PII operations happen in a consistent format,
  regardless of the source or target provider format.

  ## Pipeline Flow

      Request (any format) → Convert to OpenAI → Sanitize → Convert to target
      Response (target) → Convert to OpenAI → Restore → Convert to source

  ## Responsibilities

  - Sanitize PII in OpenAI-format request bodies
  - Restore PII in OpenAI-format response bodies
  - Store and retrieve mappings via Conversation (Conversation.Store)
  """

  require Logger

  alias ShhAi.{Conversation, PII}
  alias ShhAi.PII.SanitizationResult
  alias ShhAi.PIIPipeline.RestoreState
  alias ShhAi.ProviderClient.SSEParser

  @type mapping :: %{String.t() => String.t()}

  @nil_pii %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}

  # Hoisted module attributes so the regexes are compiled once at module load
  # time, not on every SSE chunk. Hot path: restore_stream_chunk/3 is called
  # once per chunk.
  @placeholder_complete_regex ~r/^[A-Z]+_\d+>.*/
  @placeholder_partial_regex ~r/^[A-Z]*_?[0-9]*$/

  @doc """
  Sanitize PII from an OpenAI-format request body.

  This function expects the body to already be in OpenAI format.
  It handles:
  - Chat completion requests with `messages` array
  - Other request types (pass-through with empty mapping)

  ## Options

    * `:enabled` - Whether PII sanitization is enabled (default: from config)

  When `:conversation` is provided, the function:
  - Reads the existing mapping and reverse index from the conversation
  - Passes them to the Sanitizer for placeholder reuse
  - Stores new mapping entries back into the conversation via `Conversation.Store`
  - Touches the conversation to reset its sliding TTL

  When `:conversation` is nil, the function performs a fresh sanitization
  without storing results.

  ## Returns

    * `{:ok, %SanitizationResult{}}` with fields:
      - `:sanitized_messages` - The sanitized messages list (or `[body]` for non-message bodies)
      - `:mapping` - Placeholder key → original value mapping
      - `:reverse_index` - Original value → placeholder key index
      - `:detection_counts` - `{sanitized_count, preserved_count}` tuple
      - `:pii_info` - Enriched PII info map for metrics

  ## Examples

      iex> body = %{"messages" => [%{"role" => "user", "content" => "My email is john@example.com"}]}
      iex> {:ok, result} = ShhAi.PIIPipeline.sanitize_openai_request(body)
      iex> hd(result.sanitized_messages)["content"]
      "My email is <EMAIL_1>"
      iex> result.pii_info.detected_count
      1

  """
  @spec sanitize_openai_request(
          body :: map(),
          conversation :: Conversation.t(),
          opts :: keyword()
        ) ::
          {:ok, SanitizationResult.t()}
  def sanitize_openai_request(body, conversation, opts \\ []) do
    if resolve_pii_enabled?(opts) do
      do_sanitize_openai_request(body, conversation, opts)
    else
      {:ok,
       %SanitizationResult{
         sanitized_messages: extract_body_messages(body),
         mapping: %{},
         reverse_index: %{},
         detection_counts: {0, 0},
         pii_info: @nil_pii
       }}
    end
  end

  defp do_sanitize_openai_request(%{"messages" => messages} = body, conversation, opts)
       when is_list(messages) do
    sanitize_messages("messages", messages, body, conversation, opts)
  end

  defp do_sanitize_openai_request(%{"input" => messages} = body, conversation, opts)
       when is_list(messages) do
    sanitize_messages("input", messages, body, conversation, opts)
  end

  defp do_sanitize_openai_request(body, conversation, _opts) do
    # Get existing mapping/reverse_index from conversation if provided
    {existing_mapping, existing_reverse_index} = get_conversation_state(conversation)

    sanitizer_opts =
      if map_size(existing_mapping) > 0 do
        [existing_mapping: existing_mapping, reverse_index: existing_reverse_index]
      else
        []
      end

    # For non-message bodies (e.g., embeddings, moderations), sanitize the entire text
    json = Jason.encode!(body)

    {:ok, sanitized, mapping, reverse_index, detection_counts} =
      PII.Sanitizer.sanitize(json, sanitizer_opts)

    case Jason.decode(sanitized) do
      {:ok, decoded} ->
        {:ok,
         %SanitizationResult{
           sanitized_messages: [decoded],
           mapping: mapping,
           reverse_index: reverse_index,
           detection_counts: detection_counts,
           pii_info: build_pii_info(mapping, detection_counts)
         }}

      {:error, _} ->
        Logger.warning(
          "PII pipeline: JSON decode failed after sanitization, returning sanitized string"
        )

        # NOTE: sanitized_messages contains a raw string (not a map) in this edge case.
        # The JSON payload couldn't be decoded after PII placeholder replacement.
        {:ok,
         %SanitizationResult{
           sanitized_messages: [sanitized],
           mapping: mapping,
           reverse_index: reverse_index,
           detection_counts: detection_counts,
           pii_info: build_pii_info(mapping, detection_counts)
         }}
    end
  end

  defp sanitize_messages(_key, messages, _body, conversation, _opts) do
    {existing_mapping, existing_reverse_index} = get_conversation_state(conversation)

    base_sanitizer_opts =
      if map_size(existing_mapping) > 0 do
        [existing_mapping: existing_mapping, reverse_index: existing_reverse_index]
      else
        []
      end

    result =
      case conversation do
        nil ->
          PII.Sanitizer.sanitize_messages(messages, base_sanitizer_opts)

        %Conversation{new?: true} ->
          # Turn 1: no cache, no ETS writes. The mapping will be returned
          # to the caller and persisted later by Conversation.persist_turn_1/4.
          PII.Sanitizer.sanitize_messages(messages, base_sanitizer_opts)

        %Conversation{} = conv ->
          # Turn 2+: Pipeline owns the cache loop.
          # For each message: lookup → sanitize-or-reuse → store.
          reduce_with_cache(
            messages,
            existing_mapping,
            existing_reverse_index,
            conv.conversation_id,
            base_sanitizer_opts
          )
      end

    case result do
      {:ok, sanitized_messages, mapping, reverse_index, detection_counts} ->
        if conversation != nil and not conversation.new? do
          maybe_update_conversation(conversation, mapping, reverse_index)
        end

        pii_info = build_pii_info(mapping, detection_counts)

        {:ok,
         %SanitizationResult{
           sanitized_messages: sanitized_messages,
           mapping: mapping,
           reverse_index: reverse_index,
           detection_counts: detection_counts,
           pii_info: pii_info
         }}

      {:error, reason} ->
        Logger.error("PII sanitization failed: #{inspect(reason)}")
        {:error, :pii_sanitization_failed}
    end
  end

  # Pipeline-owned cache loop: per-message lookup → sanitize-or-reuse → store.
  # Calls Conversation.lookup_message/2, Sanitizer.sanitize_messages/2 (pure),
  # and Conversation.cache_message/3 (facade) — never Store.* directly.
  #
  # The reduce prepends new sanitized messages to the accumulator (O(1)) and
  # reverses once at the end, instead of using `acc_msgs ++ [sanitized_msg]`
  # (O(n)) per message. For a conversation with N messages, that drops the
  # work from O(n²) to O(n).
  defp reduce_with_cache(messages, initial_mapping, initial_ri, conversation_id, base_opts) do
    initial_acc = {:ok, [], initial_mapping, initial_ri, {0, 0}}

    final_acc =
      Enum.reduce(messages, initial_acc, fn
        message, {:ok, acc_msgs, acc_mapping, acc_ri, {acc_s, acc_p}} ->
          handle_message_with_cache(
            message,
            {acc_msgs, acc_mapping, acc_ri, acc_s, acc_p},
            conversation_id,
            base_opts
          )
      end)

    case final_acc do
      {:ok, acc_msgs, acc_mapping, acc_ri, counts} ->
        {:ok, Enum.reverse(acc_msgs), acc_mapping, acc_ri, counts}

      error ->
        error
    end
  end

  # Per-message cache handling. Returns the same accumulator shape as the
  # reduce so the loop body stays small and the reduce-with-cache
  # function reads as a 3-step pipeline (loop → reverse → return).
  defp handle_message_with_cache(
         message,
         {acc_msgs, acc_mapping, acc_ri, acc_s, acc_p},
         conversation_id,
         base_opts
       ) do
    hash = Conversation.hash_message(message)

    case Conversation.lookup_message(conversation_id, hash) do
      {:ok, {:user_message, cached_text, cached_new_mapping, cached_new_ri, _cached_counts}} ->
        # Cache hit: reuse sanitized text, merge cached deltas
        sanitized_msg = Map.put(message, "content", cached_text)
        new_mapping = Map.merge(acc_mapping, cached_new_mapping)
        new_ri = Map.merge(acc_ri, cached_new_ri)

        {:ok, [sanitized_msg | acc_msgs], new_mapping, new_ri, {acc_s, acc_p}}

      {:ok, {:assistant_message, cached_text}} ->
        # Assistant response cache hit (cached by streaming response caching)
        sanitized_msg = Map.put(message, "content", cached_text)

        {:ok, [sanitized_msg | acc_msgs], acc_mapping, acc_ri, {acc_s, acc_p}}

      {:error, :not_found} ->
        # Cache miss: sanitize with accumulated mapping/ri via pure Sanitizer
        message_opts =
          Keyword.merge(base_opts,
            existing_mapping: acc_mapping,
            reverse_index: acc_ri
          )

        case PII.Sanitizer.sanitize_messages([message], message_opts) do
          {:ok, [sanitized_msg], full_mapping, full_ri, {s, p}} ->
            # Compute delta (new entries only) and cache via Conversation facade
            new_mapping_delta = Map.drop(full_mapping, Map.keys(acc_mapping))
            new_ri_delta = Map.drop(full_ri, Map.keys(acc_ri))
            sanitized_text = sanitized_msg["content"]

            Conversation.cache_message(
              conversation_id,
              hash,
              {:user_message, sanitized_text, new_mapping_delta, new_ri_delta, {s, p}}
            )

            {:ok, [sanitized_msg | acc_msgs], full_mapping, full_ri, {acc_s + s, acc_p + p}}

          error ->
            error
        end
    end
  end

  # Extract the messages list from a body for the SanitizationResult.
  # For "messages"/"input" bodies with a list value, returns the list directly.
  # For non-message bodies (embeddings, moderations), wraps the body in a single-element list
  # to conform to the sanitized_messages :: [map()] type.
  defp extract_body_messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp extract_body_messages(%{"input" => input}) when is_list(input), do: input
  defp extract_body_messages(body), do: [body]

  defp build_pii_info(mapping, {sanitized, preserved}) do
    types =
      Enum.map(mapping, fn {k, _v} ->
        case k do
          {t, _num} when is_atom(t) -> t
        end
      end)

    %{
      detected_count: sanitized + preserved,
      sanitized_count: sanitized,
      preserved_count: preserved,
      types: types
    }
  end

  @doc """
  Restore PII in an OpenAI-format response body.

  This function restores PII placeholders with their original values.
  It should be called after converting the response to OpenAI format.

  ## Options

    * `:mapping` - Explicit mapping to use (overrides conversation lookup)

  When `:mapping` is provided explicitly, it takes priority.
  When `:conversation` is provided (without explicit `:mapping`), the mapping
  is retrieved from the conversation's stored state.
  When neither is provided, an empty mapping is used (no restoration).

  ## Examples

      iex> response = %{"choices" => [%{"message" => %{"content" => "Hello <PERSON_1>"}}]}
      iex> mapping = %{"PERSON_1" => "John"}
      iex> {:ok, restored} = ShhAi.PIIPipeline.restore_openai_response(response, mapping: mapping)
      iex> restored
      %{"choices" => [%{"message" => %{"content" => "Hello John"}}]}

  """
  @spec restore_openai_response(
          response :: term(),
          conversation :: Conversation.t(),
          opts :: keyword()
        ) ::
          {:ok, restored :: term()}
  def restore_openai_response(response, conversation, opts \\ []) do
    mapping = get_mapping(conversation, opts)

    if map_size(mapping) == 0 do
      {:ok, response}
    else
      PII.Sanitizer.restore_response(response, mapping)
    end
  end

  @doc """
  Restore PII in a streaming SSE chunk with state for handling split placeholders.

  When streaming, PII placeholders like `<PERSON_1>` can be split across
  chunks (e.g., `<PERS` in one chunk, `ON_1>` in the next). This function
  parses SSE chunks, buffers partial placeholders, and only returns content
  that is complete.

  This function handles SSE (Server-Sent Events) chunks in OpenAI format:
  - Parses the SSE format to extract JSON data
  - Restores PII in text fields (like `delta` content)
  - Reconstructs the SSE chunk with restored text
  - Preserves metadata (sequence_number, item_id, etc.) from the first chunk

  Returns `{output, new_state}` where:
  - `output` is a list of restored SSE chunks ready to send (may be empty if buffering)
  - `new_state` is a `%ShhAi.PIIPipeline.RestoreState{}` with field:
    - `:buffer` - buffered text that might contain split placeholders

  ## Examples

      iex> mapping = %{"PERSON_1" => "John"}
      iex> chunk1 = "data: {\\"delta\\":\\"Hello <PERS\\"}\\n\\n"
      iex> {output, state} = ShhAi.PIIPipeline.restore_stream_chunk(chunk1, ShhAi.PIIPipeline.RestoreState.new(), mapping)
      iex> output
      []
      iex> chunk2 = "data: {\\"delta\\":\\"ON_1>!\\"}\\n\\n"
      iex> {output, _state} = ShhAi.PIIPipeline.restore_stream_chunk(chunk2, state, mapping)
      iex> hd(output)
      "data: {\\"delta\\":\\"Hello John!\\"}\\n\\n"

  """
  @spec restore_stream_chunk(
          chunk :: String.t(),
          state :: RestoreState.t(),
          mapping :: mapping()
        ) :: {output :: [String.t()], new_state :: RestoreState.t()}
  def restore_stream_chunk(chunk, %RestoreState{} = state, mapping)
      when is_binary(chunk) and is_map(mapping) do
    if map_size(mapping) == 0 do
      {[chunk], state}
    else
      # Get current buffer from state
      buffer = state.buffer

      # Process the chunk
      process_sse_chunk(chunk, buffer, mapping)
    end
  end

  # Private helpers for streaming restoration

  # Process an SSE chunk, handling split placeholders
  defp process_sse_chunk(chunk, buffer, mapping) do
    case SSEParser.parse(chunk) do
      {:error, _} ->
        {[chunk], %RestoreState{buffer: buffer}}

      [] ->
        {[chunk], %RestoreState{buffer: buffer}}

      events when is_list(events) ->
        process_typed_events(events, chunk, buffer, mapping)
    end
  end

  @doc """
  Restore PII in a list of pre-parsed `%SSEParser{}` events, returning the
  restored events in the same shape.

  This is the events-in/events-out PII restore contract. The caller
  (e.g. `StreamHandler`) has already parsed the SSE bytes once via
  `target_converter.to_openai_stream_events/2` and reuses the same
  `%SSEParser{}` events here. The function mutates the text payload of
  any event with PII to restore and returns the modified events, leaving
  non-text events (`:done`, tool-use deltas, etc.) and events without
  PII unchanged.

  Split-placeholder handling: the `:buffer` field of `state` accumulates a
  partial placeholder across chunks. When the chunk ends with a `<` that
  might start a placeholder, the rest is buffered; the next chunk
  completes it.

  Pass-through semantics: an empty list, an empty mapping, a single
  `:done` event, or an event with no extractable text all return the
  input events unchanged. The PII restore is only applied to events
  with a recognised text payload.

  Returns `{events, new_state}` where `events` is the (possibly
  modified) list of `%SSEParser{}` events and `new_state` is the
  updated `%ShhAi.PIIPipeline.RestoreState{}`.
  """
  @spec restore_stream_events(
          events :: [SSEParser.t()],
          state :: RestoreState.t(),
          mapping :: mapping()
        ) ::
          {output :: [SSEParser.t()], new_state :: RestoreState.t()}
  def restore_stream_events(events, %RestoreState{} = state, mapping)
      when is_list(events) and is_map(mapping) do
    if map_size(mapping) == 0 do
      {events, state}
    else
      process_typed_events(events, state.buffer, mapping)
    end
  end

  # Events-in/events-out variant: process events and return modified
  # events. The chunk parameter is gone — we mutate the event's payload
  # rather than reconstructing bytes. Note: only the *first* event with
  # an extractable text payload is mutated; the rest pass through
  # unchanged. This matches the bytes-shaped `process_typed_events/4`
  # which only acts on the head event.
  defp process_typed_events(events, buffer, mapping) do
    case events do
      [%SSEParser{type: :done}] ->
        # [DONE] marker — pass through, no text to restore
        {events, %RestoreState{buffer: buffer}}

      [%SSEParser{type: :data, payload: json_data} = event | _] ->
        process_typed_json_event(event, nil, json_data, buffer, mapping)

      [%SSEParser{type: :event, event_name: event_type, payload: json_data} = event | _] ->
        process_typed_json_event(event, event_type, json_data, buffer, mapping)

      _ ->
        {events, %RestoreState{buffer: buffer}}
    end
  end

  # Restore PII in a typed event by mutating its payload. The `event_type`
  # argument is unused here — the event itself encodes the structure
  # (`%SSEParser{type: :event, event_name: ..., payload: ...}`), and the
  # `reconstruct_sse_chunk/2` helper that used to consume the `event_type`
  # is no longer in this path. It's kept in the signature so the call
  # site is explicit about which type the event is.
  defp process_typed_json_event(event, _event_type, json_data, buffer, mapping) do
    case extract_text_from_json(json_data) do
      {:ok, text_field, text} ->
        case restore_complete_placeholders(buffer <> text, mapping) do
          {restored, remaining_buffer} ->
            restored_json = put_text_in_json(json_data, text_field, restored)
            restored_event = %{event | payload: restored_json}
            {[restored_event], %RestoreState{buffer: remaining_buffer}}
        end

      :no_text ->
        # No text content to restore — pass through
        {[event], %RestoreState{buffer: buffer}}
    end
  end

  # Bytes-shaped path: re-parse the chunk and re-serialise the restored
  # event back to bytes. Used by `restore_stream_chunk/3` (the
  # bytes-shaped public API) and by `process_sse_chunk/3` for the
  # `:raw` fallback path in `StreamHandler`.
  defp process_typed_events(events, chunk, buffer, mapping) do
    case events do
      [%SSEParser{type: :done}] ->
        # [DONE] marker — pass through, no text to restore
        {[chunk], %RestoreState{buffer: buffer}}

      [%SSEParser{type: :data, payload: json_data} | _] ->
        process_json_event(nil, json_data, chunk, buffer, mapping)

      [%SSEParser{type: :event, event_name: event_type, payload: json_data} | _] ->
        process_json_event(event_type, json_data, chunk, buffer, mapping)

      _ ->
        {[chunk], %RestoreState{buffer: buffer}}
    end
  end

  defp process_json_event(event_type, json_data, chunk, buffer, mapping) do
    case extract_text_from_json(json_data) do
      {:ok, text_field, text} ->
        case restore_complete_placeholders(buffer <> text, mapping) do
          {restored, remaining_buffer} ->
            restored_json = put_text_in_json(json_data, text_field, restored)
            new_chunk = reconstruct_sse_chunk(event_type, restored_json)
            {[new_chunk], %RestoreState{buffer: remaining_buffer}}
        end

      :no_text ->
        # No text content to restore — pass through
        {[chunk], %RestoreState{buffer: buffer}}
    end
  end

  # Extract text from JSON based on format
  # Supports both Responses API and Chat Completions API
  defp extract_text_from_json(json) do
    cond do
      # Responses API: {"delta": "text"}
      Map.has_key?(json, "delta") and is_binary(json["delta"]) ->
        {:ok, "delta", json["delta"]}

      # Chat Completions API: {"choices": [{"delta": {"content": "text"}}]}
      Map.has_key?(json, "choices") and is_list(json["choices"]) ->
        case json["choices"] do
          [%{"delta" => %{"content" => text}} | _] when is_binary(text) ->
            {:ok, "choices[0].delta.content", text}

          _ ->
            :no_text
        end

      true ->
        :no_text
    end
  end

  # Put restored text back into JSON structure
  defp put_text_in_json(json, "delta", text) do
    Map.put(json, "delta", text)
  end

  defp put_text_in_json(json, "choices[0].delta.content", text) do
    case json["choices"] do
      [choice | rest] ->
        updated_choice = put_in(choice, ["delta", "content"], text)
        Map.put(json, "choices", [updated_choice | rest])

      _ ->
        json
    end
  end

  defp put_text_in_json(json, _, _), do: json

  # Reconstruct an SSE chunk from event type and JSON
  defp reconstruct_sse_chunk(nil, json) do
    "data: #{Jason.encode!(json)}\n\n"
  end

  defp reconstruct_sse_chunk(event_type, json) do
    "event: #{event_type}\ndata: #{Jason.encode!(json)}\n\n"
  end

  defp restore_complete_placeholders(text, mapping) do
    case find_potential_split(text) do
      {:complete, content} ->
        # No potential split, restore everything
        {:ok, restored} = PII.Sanitizer.restore(content, mapping)
        {restored, ""}

      {:split, before, after_split} ->
        # Found '<' that might start a placeholder at the end
        # Buffer the potential partial and restore the rest
        if looks_like_partial_placeholder?(after_split) do
          {:ok, restored} = PII.Sanitizer.restore(before, mapping)

          {restored, "<" <> after_split}
        else
          # Doesn't look like a placeholder, restore everything
          {:ok, restored} = PII.Sanitizer.restore(text, mapping)

          {restored, ""}
        end
    end
  end

  defp find_potential_split(text) do
    case :binary.matches(text, "<") do
      [] ->
        {:complete, text}

      matches ->
        # Get the position of the last '<'
        {last_pos, _} = List.last(matches)

        rest = String.slice(text, (last_pos + 1)..-1//1)

        # Check if this is a complete placeholder or partial
        if Regex.match?(@placeholder_complete_regex, rest) do
          # Complete placeholder - no split needed
          {:complete, text}
        else
          # Might be partial - return the split
          before = String.slice(text, 0, last_pos)
          {:split, before, rest}
        end
    end
  end

  defp looks_like_partial_placeholder?(text) do
    # Check if text looks like it could be part of a placeholder
    # Placeholders are: PERSON_1, EMAIL_2, etc.
    Regex.match?(@placeholder_partial_regex, text)
  end

  defp resolve_pii_enabled?(opts) do
    case Keyword.get(opts, :enabled) do
      nil -> ShhAi.Config.pii_enabled?()
      enabled -> enabled
    end
  end

  # Get existing mapping and reverse_index from a Conversation struct.
  # Returns {mapping, reverse_index} or {%{}, %{}} when conversation is nil.
  defp get_conversation_state(nil), do: {%{}, %{}}

  defp get_conversation_state(%Conversation{} = conversation) do
    mapping =
      case Conversation.get_mapping(conversation.conversation_id) do
        {:ok, m} -> m
        {:error, _} -> %{}
      end

    reverse_index =
      case Conversation.get_reverse_index(conversation.conversation_id) do
        {:ok, ri} -> ri
        {:error, _} -> %{}
      end

    {mapping, reverse_index}
  end

  # Store new mapping entries back into the conversation.
  defp maybe_update_conversation(nil, _mapping, _reverse_index), do: :ok

  defp maybe_update_conversation(%Conversation{} = conversation, mapping, reverse_index) do
    Conversation.add_mapping(conversation.conversation_id, mapping, reverse_index)
  end

  # Get mapping for restore_openai_response. Priority: explicit mapping > conversation > empty.
  defp get_mapping(conversation, opts) do
    case Keyword.get(opts, :mapping) do
      nil ->
        case Conversation.get_mapping(conversation.conversation_id) do
          {:ok, mapping} -> mapping
          {:error, _} -> %{}
        end

      mapping ->
        mapping
    end
  end

  @doc """
  Extracts text content from a list of OpenAI-format SSE chunks.

  Only text content (`delta.content` / `message.content`) is returned.
  Tool calls and other non-text content are silently ignored.
  """
  @spec extract_content_from_openai_chunks(list()) :: String.t()
  def extract_content_from_openai_chunks(chunks) when is_list(chunks) do
    Enum.map_join(chunks, fn chunk ->
      case SSEParser.parse(chunk) do
        [%SSEParser{type: :data, payload: %{"choices" => _} = payload} | _] ->
          get_in(payload, ["choices", Access.at(0), "delta", "content"]) ||
            get_in(payload, ["choices", Access.at(0), "message", "content"]) || ""

        _ ->
          ""
      end
    end)
  end

  def extract_content_from_openai_chunks(_), do: ""

  @doc """
  Hot-path variant of `extract_content_from_openai_chunks/1` that accepts
  already-parsed `%SSEParser{}` events. Use this when the caller has the
  events in hand (e.g. the streaming handler already parsed the bytes via
  the target converter's `to_openai_stream_events/2`) to avoid re-parsing
  the SSE wire format a third time per chunk.
  """
  @spec extract_content_from_openai_events([SSEParser.t()]) :: String.t()
  def extract_content_from_openai_events(events) when is_list(events) do
    Enum.map_join(events, "", fn
      %SSEParser{type: :data, payload: %{"choices" => _} = payload} ->
        get_in(payload, ["choices", Access.at(0), "delta", "content"]) ||
          get_in(payload, ["choices", Access.at(0), "message", "content"]) || ""

      %SSEParser{type: :event, payload: %{"choices" => _} = payload} ->
        get_in(payload, ["choices", Access.at(0), "delta", "content"]) ||
          get_in(payload, ["choices", Access.at(0), "message", "content"]) || ""

      _ ->
        ""
    end)
  end

  def extract_content_from_openai_events(_), do: ""

  @doc """
  Extracts the assistant message from an OpenAI-format response.

  Matches a single-element `choices` list with either a `message` or `delta` key.
  Falls back to an empty assistant message.
  """
  @spec extract_assistant_message(map()) :: map()
  def extract_assistant_message(%{"choices" => [%{"message" => message} | _]}), do: message
  def extract_assistant_message(%{"choices" => [%{"delta" => delta} | _]}), do: delta
  def extract_assistant_message(_), do: %{"role" => "assistant", "content" => ""}
end
