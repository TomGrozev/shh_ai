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
        "PERSON_1" => "John Smith",
        "LOCATION_1" => "New York",
        "EMAIL_1" => "john@example.com"
      }
  """
  require Logger

  alias ShhAi.PII.{Detector, Patterns}

  @type pii_type :: Patterns.pii_type()

  @type mapping :: %{String.t() => String.t()}

  @type context :: %{
          message_type: :system | :user | :assistant,
          has_location_context: boolean(),
          has_data_context: boolean(),
          has_role_definition: boolean()
        }

  @type sanitize_result :: {:ok, sanitized :: String.t(), mapping :: mapping()}

  @doc """
  Sanitizes PII in text with context-aware preservation rules.

  Returns `{:ok, sanitized_text, mapping}` where:
  - `sanitized_text` is the text with PII replaced by placeholders
  - `mapping` maps placeholders to original values for restoration

  ## Options

    * `:context` - Context map for preservation rules (default: `%{}`)
    * `:types` - List of PII types to sanitize (default: from config)

  ## Examples

      iex> ShhAi.PII.Sanitizer.sanitize("My email is john@example.com")
      {:ok, "My email is <EMAIL_1>", %{"<EMAIL_1>" => "john@example.com"}}

      iex> ShhAi.PII.Sanitizer.sanitize("I live in New York", context: %{has_location_context: true})
      {:ok, "I live in New York", %{}}

  """
  @spec sanitize(text :: String.t(), opts :: keyword()) :: sanitize_result()
  def sanitize(text, opts \\ []) when is_binary(text) do
    context = Keyword.get(opts, :context, %{})
    types = Keyword.get(opts, :types, config_types())

    detections = Detector.detect(text, types: types)

    # Filter detections based on context rules
    {detections_to_sanitize, detections_to_preserve} =
      Enum.split_with(detections, fn detection ->
        should_sanitize?(detection, context)
      end)

    # Generate placeholders for detections to sanitize
    {sanitized_text, mapping} = apply_sanitization(text, detections_to_sanitize)

    # Log preserved detections for transparency
    if detections_to_preserve != [] do
      Logger.debug("Preserved PII: #{inspect(Enum.map(detections_to_preserve, & &1.type))}")
    end

    {:ok, sanitized_text, mapping}
  end

  @doc """
  Sanitizes PII in a message structure (for chat completions).

  Handles the message array format used by OpenAI and Anthropic APIs,
  applying appropriate context rules based on message role.

  ## Examples

      iex> messages = [%{"role" => "user", "content" => "My email is john@example.com"}]
      iex> ShhAi.PII.Sanitizer.sanitize_messages(messages)
      {:ok, [%{"role" => "user", "content" => "My email is <EMAIL_1>"}], %{"EMAIL_1" => "john@example.com"}}

  """
  @spec sanitize_messages(messages :: [map()], opts :: keyword()) ::
          {:ok, sanitized_messages :: [map()], mapping :: mapping()}
  def sanitize_messages(messages, opts \\ []) when is_list(messages) do
    initial_acc = {:ok, [], %{}}

    Enum.reduce(messages, initial_acc, fn message, {:ok, acc_messages, acc_mapping} ->
      context = build_message_context(message)

      case sanitize_message_content(message, context, opts) do
        {:ok, sanitized_message, message_mapping} ->
          {:ok, acc_messages ++ [sanitized_message], Map.merge(acc_mapping, message_mapping)}

        error ->
          error
      end
    end)
  end

  @doc """
  Restores original PII values in text using the provided mapping.

  ## Examples

      iex> ShhAi.PII.Sanitizer.restore("My email is <EMAIL_1>", %{"<EMAIL_1>" => "john@example.com"})
      {:ok, "My email is john@example.com"}

      iex> ShhAi.PII.Sanitizer.restore("No PII here", %{})
      {:ok, "No PII here"}

  """
  @spec restore(text :: String.t(), mapping :: mapping()) :: {:ok, String.t()}
  def restore(text, mapping) when is_binary(text) and is_map(mapping) do
    restored =
      Enum.reduce(mapping, text, fn {key, original}, acc ->
        placeholder = "<#{key}>"
        String.replace(acc, placeholder, original)
      end)

    {:ok, restored}
  end

  @doc """
  Restores PII in a response structure.

  Handles both plain text and structured responses (JSON objects).

  ## Examples

      iex> ShhAi.PII.Sanitizer.restore_response(%{"choices" => [%{"message" => %{"content" => "Hello <PERSON_1>"}}]}, %{"<PERSON_1>" => "John"})
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

  defp apply_sanitization(text, detections) do
    # Sort detections by position (descending) to replace from end to start
    # This prevents position shifts from affecting earlier replacements
    sorted_detections = Enum.sort_by(detections, & &1.start_pos, :desc)

    # Generate placeholders and build mapping
    {sanitized_text, mapping, _counters} =
      Enum.reduce(sorted_detections, {text, %{}, %{}}, fn detection, {txt, map, counters} ->
        {placeholder, key} = generate_placeholder(detection.type, counters)
        new_text = replace_at_position(txt, detection.start_pos, detection.end_pos, placeholder)
        # Store mapping with placeholder as key (e.g., "<EMAIL_1>" => "john@example.com")
        new_map = Map.put(map, key, detection.value)
        new_counters = increment_counter(counters, detection.type)

        {new_text, new_map, new_counters}
      end)

    {sanitized_text, mapping}
  end

  defp generate_placeholder(type, counters) do
    count = Map.get(counters, type, 0) + 1
    type_name = type |> to_string() |> String.upcase()
    key = "#{type_name}_#{count}"

    {"<#{key}>", key}
  end

  defp increment_counter(counters, type) do
    Map.update(counters, type, 1, &(&1 + 1))
  end

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

    # Handle multi-part content (list of parts)
    content_text =
      case content do
        text when is_binary(text) ->
          text

        parts when is_list(parts) ->
          # Extract text from parts
          parts
          |> Enum.filter(fn
            %{"type" => "text"} -> true
            %{"text" => _} -> true
            _ -> false
          end)
          |> Enum.map(fn
            %{"type" => "text", "text" => text} -> text
            %{"text" => text} -> text
            _ -> ""
          end)
          |> Enum.join(" ")

        _ ->
          ""
      end

    downcased = String.downcase(content_text)

    %{
      message_type: String.to_existing_atom(role),
      has_location_context: has_location_context?(downcased),
      has_data_context: has_data_context?(downcased),
      has_role_definition: has_role_definition?(downcased)
    }
  rescue
    ArgumentError ->
      %{
        message_type: :user,
        has_location_context: false,
        has_data_context: false,
        has_role_definition: false
      }
  end

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
        {:ok, sanitized, mapping} = sanitize(text, Keyword.put(opts, :context, context))

        sanitized_message = Map.put(message, "content", sanitized)

        {:ok, sanitized_message, mapping}

      # Handle multi-part content (e.g., with images)
      parts when is_list(parts) ->
        sanitize_content_parts(parts, context, opts, message)

      _ ->
        {:ok, message, %{}}
    end
  end

  defp sanitize_content_parts(parts, context, opts, original_message) do
    {sanitized_parts, mapping} =
      Enum.reduce(parts, {[], %{}}, fn part, {acc_parts, acc_mapping} ->
        case part do
          %{"text" => text} = text_part ->
            {:ok, sanitized, part_mapping} =
              sanitize(text, Keyword.put(opts, :context, context))

            sanitized_part = Map.put(text_part, "text", sanitized)
            {acc_parts ++ [sanitized_part], Map.merge(acc_mapping, part_mapping)}

          other ->
            {acc_parts ++ [other], acc_mapping}
        end
      end)

    sanitized_message = Map.put(original_message, "content", sanitized_parts)

    {:ok, sanitized_message, mapping}
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
