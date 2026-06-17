defmodule ShhAi.PII.Sanitizer do
  @moduledoc """
  Context-aware PII sanitization and restoration.

  This module handles the replacement of detected PII with placeholders
  and the restoration of original values from placeholders.

  ## Context-Aware Sanitization

  The sanitizer analyzes the prompt structure to determine if PII should
  be preserved based on context:

  | Context | Action | Rationale |
  |---------|--------|-----------|
  | System message with location context | Preserve location | Location may be required for query |
  | User message with "my location is..." | Preserve location | User explicitly providing context |
  | System message with role definition | Preserve names | Names in role definitions are intentional |
  | General user query | Sanitize PII | User may have accidentally included PII |
  | Code/data analysis requests | Preserve structured data | Data context is intentional |

  ## Placeholder Format

  Placeholders use the format: `<PII_TYPE_INDEX>`

  Examples:
  - `<PERSON_1>` - First detected person name
  - `<LOCATION_2>` - Second detected location
  - `<EMAIL_1>` - First detected email

  ## Mapping Structure

  The mapping stores the relationship between placeholders and original values:

      %{
        {:person, 1} => "John Smith",
        {:location, 1} => "New York",
        {:email, 1} => "john@example.com"
      }
  """
  require Logger

  alias ShhAi.PII.{Detector, Patterns}

  @type pii_type :: Patterns.pii_type()

  @type mapping :: %{{atom(), pos_integer()} => String.t()}

  @type reverse_index :: %{{String.t(), atom()} => {atom(), pos_integer()}}

  @type count_detections :: {count_sanitized :: integer(), count_preserved :: integer()}

  @type context :: %{
          message_type: :system | :user | :assistant,
          has_location_context: boolean(),
          has_data_context: boolean(),
          has_role_definition: boolean()
        }

  @doc """
  Sanitizes PII in text with context-aware preservation rules.

  Returns `{:ok, sanitized_text, mapping, reverse_index, count}` where:
  - `sanitized_text` is the text with PII replaced by placeholders
  - `mapping` maps placeholder keys to original values for restoration
  - `reverse_index` maps `{original_value, pii_type}` to placeholder keys for O(1) reuse
  - `count` is `{sanitized_count, preserved_count}`

  ## Options

    * `:context` - Context map for preservation rules (default: `%{}`)
    * `:types` - List of PII types to sanitize (default: from config)
    * `:existing_mapping` - Mapping from a prior sanitization pass to seed counters and merge into result
    * `:reverse_index` - Reverse index from a prior pass for O(1) placeholder reuse

  ## Examples

      iex> ShhAi.PII.Sanitizer.sanitize("My email is john@example.com")
      {:ok, "My email is <EMAIL_1>", %{{:email, 1} => "john@example.com"}, %{{"john@example.com", :email} => {:email, 1}}, {1, 0}}

      iex> ShhAi.PII.Sanitizer.sanitize("I live in New York", context: %{has_location_context: true})
      {:ok, "I live in New York", %{}, %{}, {0, 0}}

  """
  @spec sanitize(text :: String.t(), opts :: keyword()) ::
          {:ok, sanitized :: String.t(), mapping :: mapping(), reverse_index :: reverse_index(),
           count_detections()}
  def sanitize(text, opts \\ []) when is_binary(text) do
    context = Keyword.get(opts, :context, %{})
    types = Keyword.get(opts, :types, config_types())
    existing_mapping = Keyword.get(opts, :existing_mapping, %{})
    reverse_index = Keyword.get(opts, :reverse_index, %{})

    detections = Detector.detect(text, types: types)

    # Filter detections based on context rules
    {detections_to_sanitize, detections_to_preserve} =
      Enum.split_with(detections, fn detection ->
        should_sanitize?(detection, context)
      end)

    # Generate placeholders for detections to sanitize, reusing existing mapping
    {sanitized_text, mapping, new_reverse_index} =
      apply_sanitization(text, detections_to_sanitize, existing_mapping, reverse_index)

    # Log preserved detections for transparency
    if detections_to_preserve != [] do
      Logger.debug("Preserved PII: #{inspect(Enum.map(detections_to_preserve, & &1.type))}")
    end

    {:ok, sanitized_text, mapping, new_reverse_index,
     {length(detections_to_sanitize), length(detections_to_preserve)}}
  end

  @doc """
  Sanitizes PII in a message structure (for chat completions).

  Handles the message array format used by OpenAI and Anthropic APIs,
  applying appropriate context rules based on message role.

  ## Options

    * `:existing_mapping` - Mapping from prior turns to seed counters and merge
    * `:reverse_index` - Reverse index from prior turns for O(1) placeholder reuse

  ## Examples

      iex> messages = [%{"role" => "user", "content" => "My email is john@example.com"}]
      iex> ShhAi.PII.Sanitizer.sanitize_messages(messages)
      {:ok, [%{"role" => "user", "content" => "My email is <EMAIL_1>"}], %{{:email, 1} => "john@example.com"}, %{{"john@example.com", :email} => {:email, 1}}, {1, 0}}

  """
  @spec sanitize_messages(messages :: [map()], opts :: keyword()) ::
          {:ok, sanitized_messages :: [map()], mapping :: mapping(),
           reverse_index :: reverse_index(), count_detections()}
  def sanitize_messages(messages, opts \\ []) when is_list(messages) do
    existing_mapping = Keyword.get(opts, :existing_mapping, %{})
    reverse_index = Keyword.get(opts, :reverse_index, %{})

    handler = fn message, acc_mapping, acc_ri, handler_opts ->
      context = build_message_context(message)

      message_opts =
        Keyword.merge(handler_opts,
          existing_mapping: acc_mapping,
          reverse_index: acc_ri
        )

      case sanitize_message_content(message, context, message_opts) do
        {:ok, sanitized_message, message_mapping, message_reverse_index, {s_count, p_count}} ->
          {:ok, sanitized_message, message_mapping, message_reverse_index, {s_count, p_count}}

        error ->
          error
      end
    end

    reduce_messages(messages, existing_mapping, reverse_index, opts, handler)
  end

  @doc """
  Sanitizes PII in messages with per-message caching.

  For each message, checks the conversation's message cache before running
  detection. On a cache hit, reuses the sanitized text and skips NER/regex.
  On a cache miss, sanitizes normally and stores the result for future turns.

  ## Options

  Same as `sanitize_messages/2`, plus:
    * `:conversation_id` — required; the conversation ID for cache operations

  ## Returns

  Same shape as `sanitize_messages/2`:
    `{:ok, sanitized_messages, mapping, reverse_index, counts}`
  """
  @spec sanitize_with_cache([map()], String.t(), keyword()) ::
          {:ok, [map()], mapping(), reverse_index(), count_detections()}
  def sanitize_with_cache(messages, conversation_id, opts \\ [])
      when is_list(messages) and is_binary(conversation_id) do
    existing_mapping = Keyword.get(opts, :existing_mapping, %{})
    existing_reverse_index = Keyword.get(opts, :reverse_index, %{})

    handler = fn message, acc_mapping, acc_ri, handler_opts ->
      hash = ShhAi.Conversation.Fingerprinter.hash_message(message)

      case ShhAi.Conversation.lookup_message(conversation_id, hash) do
        {:ok, {:user_message, cached_text, cached_new_mapping, cached_new_ri, _cached_counts}} ->
          # Cache hit: reuse sanitized text, merge cached deltas.
          # Counts are {0, 0} because no new detection was performed.
          sanitized_msg = Map.put(message, "content", cached_text)
          new_mapping = Map.merge(acc_mapping, cached_new_mapping)
          new_ri = Map.merge(acc_ri, cached_new_ri)

          {:ok, sanitized_msg, new_mapping, new_ri, {0, 0}}

        {:ok, {:assistant_message, cached_text}} ->
          # Assistant response cache hit (cached by streaming response caching)
          # The cached value is just the sanitized text (pre-restored content)
          sanitized_msg = Map.put(message, "content", cached_text)

          {:ok, sanitized_msg, acc_mapping, acc_ri, {0, 0}}

        {:error, :not_found} ->
          # Cache miss: sanitize normally
          context = build_message_context(message)

          message_opts =
            Keyword.merge(handler_opts,
              context: context,
              existing_mapping: acc_mapping,
              reverse_index: acc_ri
            )

          do_sanitize_and_cache(
            conversation_id,
            hash,
            message,
            context,
            message_opts,
            acc_mapping,
            acc_ri
          )
      end
    end

    reduce_messages(messages, existing_mapping, existing_reverse_index, opts, handler)
  end

  defp do_sanitize_and_cache(
         conversation_id,
         hash,
         message,
         context,
         message_opts,
         acc_mapping,
         acc_ri
       ) do
    case sanitize_message_content(message, context, message_opts) do
      {:ok, sanitized_msg, full_mapping, full_ri, {s_count, p_count}} ->
        # Compute new entries (delta from accumulated)
        new_mapping = Map.drop(full_mapping, Map.keys(acc_mapping))
        new_ri = Map.drop(full_ri, Map.keys(acc_ri))

        # Cache the result
        sanitized_text = sanitized_msg["content"]

        ShhAi.Conversation.cache_message(
          conversation_id,
          hash,
          {:user_message, sanitized_text, new_mapping, new_ri, {s_count, p_count}}
        )

        {:ok, sanitized_msg, full_mapping, full_ri, {s_count, p_count}}

      error ->
        error
    end
  end

  @doc """
  Restores original PII values in text using the provided mapping.

  ## Examples

      iex> ShhAi.PII.Sanitizer.restore("My email is <EMAIL_1>", %{{:email, 1} => "john@example.com"})
      {:ok, "My email is john@example.com"}

      iex> ShhAi.PII.Sanitizer.restore("No PII here", %{})
      {:ok, "No PII here"}

  """
  @spec restore(text :: String.t(), mapping :: mapping()) :: {:ok, String.t()}
  def restore(text, mapping) when is_binary(text) and is_map(mapping) do
    restored =
      Enum.reduce(mapping, text, fn {key, original}, acc ->
        placeholder = "<#{format_placeholder_key(key)}>"
        String.replace(acc, placeholder, original)
      end)

    {:ok, restored}
  end

  @doc """
  Restores PII in a response structure.

  Handles both plain text and structured responses (JSON objects).

  ## Examples

      iex> ShhAi.PII.Sanitizer.restore_response(%{"choices" => [%{"message" => %{"content" => "Hello <PERSON_1>"}}]}, %{{:person, 1} => "John"})
      {:ok, %{"choices" => [%{"message" => %{"content" => "Hello John"}}]}}

  """
  @spec restore_response(response :: term(), mapping :: mapping()) :: {:ok, term()}
  def restore_response(response, mapping) when is_map(mapping) do
    if map_size(mapping) == 0 do
      {:ok, response}
    else
      case response do
        text when is_binary(text) ->
          restore(text, mapping)

        json when is_map(json) ->
          {:ok, restore_in_map(json, mapping)}

        json when is_list(json) ->
          {:ok, Enum.map(json, &restore_value(&1, mapping))}

        other ->
          {:ok, other}
      end
    end
  end

  # Private functions

  # Shared reduce logic for both sanitize_messages/2 and sanitize_with_cache/3.
  # The message_handler callback receives (message, acc_mapping, acc_ri, opts)
  # and must return {:ok, sanitized_msg, new_mapping, new_ri, {s, p}} or an error.
  defp reduce_messages(messages, initial_mapping, initial_ri, opts, message_handler) do
    initial_acc = {:ok, [], initial_mapping, initial_ri, {0, 0}}

    Enum.reduce(messages, initial_acc, fn
      message, {:ok, acc_msgs, acc_mapping, acc_ri, {acc_s, acc_p}} ->
        case message_handler.(message, acc_mapping, acc_ri, opts) do
          {:ok, sanitized_msg, new_mapping, new_ri, {s, p}} ->
            {:ok, acc_msgs ++ [sanitized_msg], new_mapping, new_ri, {acc_s + s, acc_p + p}}

          error ->
            error
        end
    end)
  end

  defp config_types do
    ShhAi.Config.pii_types()
  end

  defp config_always_sanitize do
    ShhAi.Config.always_sanitize()
  end

  defp config_preserve_in_system do
    ShhAi.Config.preserve_in_system_messages()
  end

  defp should_sanitize?(detection, context) do
    always_sanitize = config_always_sanitize()
    preserve_in_system = config_preserve_in_system()

    cond do
      # Always sanitize certain types regardless of context
      detection.type in always_sanitize ->
        true

      # Preserve certain types in system messages with context
      detection.type in preserve_in_system and
          context[:message_type] == :system ->
        false

      # Preserve if explicitly providing location context
      detection.type == :location and context[:has_location_context] ->
        false

      # Preserve if in a data/code analysis context
      context[:has_data_context] and detection.type in [:url, :ip_address] ->
        false

      # Default: sanitize
      true ->
        true
    end
  end

  defp apply_sanitization(text, detections, existing_mapping, reverse_index) do
    # Sort detections by position (descending) to replace from end to start
    # This prevents position shifts from affecting earlier replacements
    sorted_detections = Enum.sort_by(detections, & &1.start_pos, :desc)

    # Seed counters from existing_mapping so new placeholders start after existing ones
    initial_counters = seed_counters_from_mapping(existing_mapping)

    # Generate placeholders and build mapping, reusing from reverse_index when possible
    {sanitized_text, new_mapping, _counters, new_reverse_index} =
      Enum.reduce(
        sorted_detections,
        {text, %{}, initial_counters, reverse_index},
        fn detection, {txt, map, counters, ri} ->
          reverse_key = {detection.value, detection.type}

          case Map.get(ri, reverse_key) do
            nil ->
              # Generate new placeholder
              {placeholder, key} = generate_placeholder(detection.type, counters)

              new_text =
                replace_at_position(txt, detection.start_pos, detection.end_pos, placeholder)

              new_map = Map.put(map, key, detection.value)
              new_counters = increment_counter(counters, detection.type)
              new_ri = Map.put(ri, reverse_key, key)

              {new_text, new_map, new_counters, new_ri}

            existing_key ->
              # Reuse existing placeholder
              placeholder = "<#{format_placeholder_key(existing_key)}>"

              new_text =
                replace_at_position(txt, detection.start_pos, detection.end_pos, placeholder)

              {new_text, map, counters, ri}
          end
        end
      )

    # Merge existing_mapping with new entries for the full accumulated mapping
    full_mapping = Map.merge(existing_mapping, new_mapping)

    {sanitized_text, full_mapping, new_reverse_index}
  end

  defp seed_counters_from_mapping(mapping) do
    Enum.reduce(mapping, %{}, fn
      {{type, num}, _value}, counters when is_atom(type) and is_integer(num) ->
        Map.update(counters, type, num, &max(&1, num))
    end)
  end

  defp generate_placeholder(type, counters) do
    count = Map.get(counters, type, 0) + 1
    type_name = type |> to_string() |> String.upcase()

    {"<#{type_name}_#{count}>", {type, count}}
  end

  defp increment_counter(counters, type) do
    Map.update(counters, type, 1, &(&1 + 1))
  end

  defp format_placeholder_key({type, count}) when is_atom(type) and is_integer(count) do
    "#{type |> to_string() |> String.upcase()}_#{count}"
  end

  defp format_placeholder_key(str) when is_binary(str), do: str

  defp replace_at_position(text, start_pos, end_pos, replacement) do
    # Calculate the length of the text to replace
    length = end_pos - start_pos

    # Build the new string
    binary_part(text, 0, start_pos) <>
      replacement <>
      binary_part(text, end_pos, byte_size(text) - length - start_pos)
  end

  defp build_message_context(message) do
    role = message["role"] || message[:role] || "user"
    content = message["content"] || message[:content] || ""
    content_text = extract_content_text(content)
    downcased = String.downcase(content_text)
    role_atom = role_to_atom(role)

    %{
      message_type: role_atom,
      has_location_context: has_location_context?(downcased),
      has_data_context: has_data_context?(downcased),
      has_role_definition: has_role_definition?(downcased)
    }
  end

  defp extract_content_text(text) when is_binary(text), do: text

  defp extract_content_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      %{"text" => _} -> true
      _ -> false
    end)
    |> Enum.map_join(" ", fn
      %{"type" => "text", "text" => text} -> text
      %{"text" => text} -> text
      _ -> ""
    end)
  end

  defp extract_content_text(_), do: ""

  defp role_to_atom("system"), do: :system
  defp role_to_atom("user"), do: :user
  defp role_to_atom("assistant"), do: :assistant
  defp role_to_atom(_), do: :user

  defp has_location_context?(content) when is_binary(content) do
    String.contains?(content, ["my location is", "i live in", "i'm in", "i am in", "weather in"]) ||
      Regex.match?(~r/(?:my location|i live|i'm from|i am from|weather in)/i, content)
  end

  defp has_location_context?(_), do: false

  defp has_data_context?(content) when is_binary(content) do
    String.contains?(content, ["analyze this data", "process this file", "code:", "```"]) ||
      Regex.match?(~r/(?:analyze|process|parse|data|json|csv|xml)/i, content)
  end

  defp has_data_context?(_), do: false

  defp has_role_definition?(content) when is_binary(content) do
    String.contains?(content, ["you are", "your role is", "act as"]) ||
      Regex.match?(~r/(?:you are|your role|act as)/i, content)
  end

  defp has_role_definition?(_), do: false

  defp sanitize_message_content(message, context, opts) do
    content = message["content"] || message[:content]

    case content do
      text when is_binary(text) ->
        {:ok, sanitized, mapping, reverse_index, counts} =
          sanitize(text, Keyword.put(opts, :context, context))

        sanitized_message = Map.put(message, "content", sanitized)

        {:ok, sanitized_message, mapping, reverse_index, counts}

      # Handle multi-part content (e.g., with images)
      parts when is_list(parts) ->
        sanitize_content_parts(parts, context, opts, message)

      _ ->
        {:ok, message, %{}, %{}, {0, 0}}
    end
  end

  defp sanitize_content_parts(parts, context, opts, original_message) do
    existing_mapping = Keyword.get(opts, :existing_mapping, %{})
    reverse_index = Keyword.get(opts, :reverse_index, %{})

    {sanitized_parts, mapping, new_reverse_index, counts} =
      Enum.reduce(parts, {[], existing_mapping, reverse_index, {0, 0}}, fn
        part, {acc_parts, acc_mapping, acc_reverse_index, {acc_sanitized, acc_preserved}} ->
          case part do
            %{"text" => text} = text_part ->
              part_opts =
                Keyword.merge(opts,
                  context: context,
                  existing_mapping: acc_mapping,
                  reverse_index: acc_reverse_index
                )

              {:ok, sanitized, part_mapping, part_reverse_index,
               {sanitized_count, preserve_count}} =
                sanitize(text, part_opts)

              sanitized_part = Map.put(text_part, "text", sanitized)

              {acc_parts ++ [sanitized_part], part_mapping, part_reverse_index,
               {sanitized_count + acc_sanitized, preserve_count + acc_preserved}}

            other ->
              {acc_parts ++ [other], acc_mapping, acc_reverse_index,
               {acc_sanitized, acc_preserved}}
          end
      end)

    sanitized_message = Map.put(original_message, "content", sanitized_parts)

    {:ok, sanitized_message, mapping, new_reverse_index, counts}
  end

  defp restore_in_map(map, mapping) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      restored_value = restore_value(value, mapping)
      Map.put(acc, key, restored_value)
    end)
  end

  defp restore_value(value, mapping) do
    case value do
      text when is_binary(text) ->
        {:ok, restored} = restore(text, mapping)
        restored

      nested_map when is_map(nested_map) ->
        restore_in_map(nested_map, mapping)

      list when is_list(list) ->
        Enum.map(list, &restore_value(&1, mapping))

      other ->
        other
    end
  end
end
