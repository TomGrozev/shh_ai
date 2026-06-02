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
  - Store and retrieve mappings via SessionStore
  """

  require Logger

  alias ShhAi.{SessionStore, PII}

  @type mapping :: %{String.t() => String.t()}

  @nil_pii %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}

  @doc """
  Sanitize PII from an OpenAI-format request body.

  This function expects the body to already be in OpenAI format.
  It handles:
  - Chat completion requests with `messages` array
  - Other request types (pass-through with empty mapping)

  ## Options

    * `:session_id` - Session ID to store the mapping (optional)
    * `:enabled` - Whether PII sanitization is enabled (default: from config)

  ## Returns

    * `{:ok, sanitized_body, mapping, pii_info}` where pii_info contains:
      - `:detected_count` - Total PII items detected
      - `:sanitized_count` - PII items actually sanitized
      - `:preserved_count` - PII items preserved via context rules
      - `:types` - List of PII types detected

  ## Examples

      iex> body = %{"messages" => [%{"role" => "user", "content" => "My email is john@example.com"}]}
      iex> {:ok, sanitized, mapping, pii_info} = ShhAi.PIIPipeline.sanitize_openai_request(body)
      iex> sanitized
      %{"messages" => [%{"role" => "user", "content" => "My email is <EMAIL_1>"}]}
      iex> pii_info.detected_count
      1

  """
  @spec sanitize_openai_request(body :: map(), opts :: keyword()) ::
          {:ok, sanitized_body :: map(), mapping :: mapping(), pii_info :: map()}
  def sanitize_openai_request(body, opts \\ []) do
    if pii_enabled?(opts) do
      do_sanitize_openai_request(body, opts)
    else
      {:ok, body, %{}, @nil_pii}
    end
  end

  defp do_sanitize_openai_request(%{"messages" => messages} = body, opts)
       when is_list(messages) do
    sanitize_messages("messages", messages, body, opts)
  end

  defp do_sanitize_openai_request(%{"input" => messages} = body, opts)
       when is_list(messages) do
    sanitize_messages("input", messages, body, opts)
  end

  defp do_sanitize_openai_request(body, _opts) do
    # For non-message bodies (e.g., embeddings, moderations), sanitize the entire text
    json = Jason.encode!(body)
    {:ok, sanitized, mapping, _counts} = PII.Sanitizer.sanitize(json)

    case Jason.decode(sanitized) do
      {:ok, decoded} -> {:ok, decoded, mapping, @nil_pii}
      {:error, _} -> {:ok, body, mapping, @nil_pii}
    end
  end

  defp sanitize_messages(key, messages, body, opts) do
    case PII.Sanitizer.sanitize_messages(messages) do
      {:ok, sanitized_messages, mapping, detection_counts} ->
        sanitized_body = Map.put(body, key, sanitized_messages)

        # Store mapping if session_id provided
        maybe_store_mapping(opts[:session_id], mapping)

        # Build PII info
        pii_info = build_pii_info(mapping, detection_counts)

        {:ok, sanitized_body, mapping, pii_info}

      {:error, reason} ->
        Logger.error("PII sanitization failed: #{inspect(reason)}")

        {:ok, body, %{}, @nil_pii}
    end
  end

  defp build_pii_info(mapping, {sanitized, preserved}) do
    types =
      Enum.map(mapping, fn {k, _v} ->
        [type | _] = String.split(k, ~r/_(?=\d)/, parts: 2)

        type |> String.downcase() |> String.to_existing_atom()
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

    * `:session_id` - Session ID to retrieve the mapping from (optional)
    * `:mapping` - Explicit mapping to use (overrides session lookup)

  ## Examples

      iex> response = %{"choices" => [%{"message" => %{"content" => "Hello <PERSON_1>"}}]}
      iex> mapping = %{"PERSON_1" => "John"}
      iex> {:ok, restored} = ShhAi.PIIPipeline.restore_openai_response(response, mapping: mapping)
      iex> restored
      %{"choices" => [%{"message" => %{"content" => "Hello John"}}]}

  """
  @spec restore_openai_response(response :: term(), opts :: keyword()) ::
          {:ok, restored :: term()}
  def restore_openai_response(response, opts \\ []) do
    mapping = get_mapping(opts)

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

  defp maybe_store_mapping(nil, _mapping), do: :ok
  defp maybe_store_mapping(session_id, mapping), do: SessionStore.put(session_id, mapping)

  defp get_mapping(opts) do
    case Keyword.get(opts, :mapping) do
      nil ->
        case Keyword.get(opts, :session_id) do
          nil -> %{}
          session_id -> get_session_mapping(session_id)
        end

      mapping ->
        mapping
    end
  end

  defp get_session_mapping(session_id) do
    case SessionStore.get(session_id) do
      {:ok, mapping} -> mapping
      {:error, _} -> %{}
    end
  end
end
