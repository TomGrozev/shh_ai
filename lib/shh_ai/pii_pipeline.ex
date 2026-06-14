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
  - Store and retrieve mappings via Conversation (ConversationStore)
  """

  require Logger

  alias ShhAi.{Conversation, PII}

  @type mapping :: %{String.t() => String.t()}

  @nil_pii %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}

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
  - Stores new mapping entries back into the conversation via `ConversationStore`
  - Touches the conversation to reset its sliding TTL

  When `:conversation` is nil, the function performs a fresh sanitization
  without storing results.

  ## Returns

    * `{:ok, sanitized_body, mapping, reverse_index, pii_info}` where pii_info contains:
      - `:detected_count` - Total PII items detected
      - `:sanitized_count` - PII items actually sanitized
      - `:preserved_count` - PII items preserved via context rules
      - `:types` - List of PII types detected

  ## Examples

      iex> body = %{"messages" => [%{"role" => "user", "content" => "My email is john@example.com"}]}
      iex> {:ok, sanitized, mapping, _reverse_index, pii_info} = ShhAi.PIIPipeline.sanitize_openai_request(body)
      iex> sanitized
      %{"messages" => [%{"role" => "user", "content" => "My email is <EMAIL_1>"}]}
      iex> pii_info.detected_count
      1

  """
  @spec sanitize_openai_request(
          body :: map(),
          conversation :: Conversation.t(),
          opts :: keyword()
        ) ::
          {:ok, sanitized_body :: map(), mapping :: mapping(), reverse_index :: map(),
           pii_info :: map()}
  def sanitize_openai_request(body, conversation, opts \\ []) do
    if pii_enabled?(opts) do
      do_sanitize_openai_request(body, conversation, opts)
    else
      {:ok, body, %{}, %{}, @nil_pii}
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

    {:ok, sanitized, mapping, reverse_index, _counts} =
      PII.Sanitizer.sanitize(json, sanitizer_opts)

    case Jason.decode(sanitized) do
      {:ok, decoded} ->
        {:ok, decoded, mapping, reverse_index, @nil_pii}

      {:error, _} ->
        Logger.warning(
          "PII pipeline: JSON decode failed after sanitization, returning sanitized string"
        )

        {:ok, sanitized, mapping, reverse_index, @nil_pii}
    end
  end

  defp sanitize_messages(key, messages, body, conversation, _opts) do
    # Get existing mapping/reverse_index from conversation if provided
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

        %Conversation{} = conv ->
          PII.Sanitizer.sanitize_with_cache(messages, conv.conversation_id, base_sanitizer_opts)
      end

    case result do
      {:ok, sanitized_messages, mapping, reverse_index, detection_counts} ->
        sanitized_body = Map.put(body, key, sanitized_messages)

        # Store new mapping entries back into conversation if provided
        maybe_update_conversation(conversation, mapping, reverse_index)

        # Build PII info
        pii_info = build_pii_info(mapping, detection_counts)

        {:ok, sanitized_body, mapping, reverse_index, pii_info}

      {:error, reason} ->
        Logger.error("PII sanitization failed: #{inspect(reason)}")

        {:error, :pii_sanitization_failed}
    end
  end

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
  - `new_state` is a map containing:
    - `:buffer` - buffered text that might contain split placeholders

  ## Examples

      iex> mapping = %{"PERSON_1" => "John"}
      iex> chunk1 = "data: {\\"delta\\":\\"Hello <PERS\\"}\\n\\n"
      iex> {output, state} = ShhAi.PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)
      iex> output
      []
      iex> chunk2 = "data: {\\"delta\\":\\"ON_1>!\\"}\\n\\n"
      iex> {output, _state} = ShhAi.PIIPipeline.restore_stream_chunk(chunk2, state, mapping)
      iex> hd(output)
      "data: {\\"delta\\":\\"Hello John!\\"}\\n\\n"

  """
  @spec restore_stream_chunk(chunk :: String.t(), state :: map(), mapping :: mapping()) ::
          {output :: [String.t()], new_state :: map()}
  def restore_stream_chunk(chunk, state, mapping) when is_binary(chunk) and is_map(state) do
    if map_size(mapping) == 0 do
      {[chunk], state}
    else
      # Get current buffer from state
      buffer = Map.get(state, :buffer, "")

      # Process the chunk
      process_sse_chunk(chunk, buffer, mapping)
    end
  end

  # Private helpers for streaming restoration

  # Process an SSE chunk, handling split placeholders
  defp process_sse_chunk(chunk, buffer, mapping) do
    with {:ok, event_type, json_data} <- parse_sse_chunk(chunk),
         {:ok, text_field, text} <- extract_text_from_json(json_data),
         {restored, remaining_buffer} <- restore_complete_placeholders(buffer <> text, mapping) do
      restored_json = put_text_in_json(json_data, text_field, restored)

      new_chunk = reconstruct_sse_chunk(event_type, restored_json)

      {[new_chunk], %{buffer: remaining_buffer}}
    else
      _ ->
        # Parse error - pass through unchanged
        {[chunk], %{buffer: buffer}}
    end
  end

  # Parse an SSE chunk into event type and JSON data
  defp parse_sse_chunk(chunk) do
    # SSE format: "event: type\ndata: {...}\n\n" or "data: {...}\n\n"
    lines = String.split(chunk, "\n")

    {event_type, data_lines} =
      case lines do
        ["event: " <> event | rest] -> {event, rest}
        rest -> {nil, rest}
      end

    # Find and parse the data line
    data =
      Enum.find_value(data_lines, fn
        "data: " <> data -> data
        _ -> nil
      end)

    case data do
      nil ->
        {:error, :no_data}

      "[DONE]" ->
        {:ok, event_type, %{}}

      _ ->
        case Jason.decode(data) do
          {:ok, json} -> {:ok, event_type, json}
          {:error, _} -> {:error, :invalid_json}
        end
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
        if Regex.match?(~r/^[A-Z]+_\d+>.*/, rest) do
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
    Regex.match?(~r/^[A-Z]*_?[0-9]*$/, text)
  end

  defp pii_enabled?(opts) do
    case Keyword.get(opts, :enabled) do
      nil -> ShhAi.Config.pii_enabled()
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
      case ShhAi.ConversationStore.get_reverse_index(conversation.conversation_id) do
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
end
