defmodule ShhAi.ApiConverter.Anthropic do
  @moduledoc """
  Anthropic API format converter.
  Converts between OpenAI format (canonical) and Anthropic Messages API format.

  Supports:
  - Chat completions with text, images, and tools
  - System prompts
  - Streaming responses
  """

  @behaviour ShhAi.ApiConverter

  # Request conversion: Anthropic -> OpenAI
  @impl true
  def to_openai_request(headers, %{"messages" => messages} = request, _path) do
    # Convert Anthropic messages format to OpenAI format
    openai_messages = convert_messages_to_openai(messages)

    openai_request =
      %{
        "model" => request["model"],
        "messages" => openai_messages,
        "stream" => request["stream"],
        "temperature" => request["temperature"],
        "top_p" => request["top_p"],
        "max_tokens" => request["max_tokens"],
        "tools" => convert_anthropic_tools_to_openai(request["tools"])
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    # Handle system prompt
    openai_request =
      case request["system"] do
        nil ->
          openai_request

        system when is_binary(system) ->
          # Add system message at the beginning
          Map.put(openai_request, "messages", [
            %{"role" => "system", "content" => system}
            | openai_messages
          ])

        system when is_list(system) ->
          # Convert structured system prompt to text
          system_text = extract_system_text(system)

          Map.put(openai_request, "messages", [
            %{"role" => "system", "content" => system_text}
            | openai_messages
          ])
      end

    # Remove nil values
    body =
      openai_request
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Map.new()

    {headers_to_openai(headers), body}
  end

  def to_openai_request(headers, body, _path), do: {headers_to_openai(headers), body}

  # Request conversion: OpenAI -> Anthropic
  @impl true
  def from_openai_request(headers, %{"messages" => messages} = request, _path) do
    # Extract system message if present
    {system_messages, other_messages} =
      Enum.split_with(messages, fn m -> m["role"] == "system" end)

    system_prompt =
      case system_messages do
        [sys | _] -> sys["content"]
        [] -> nil
      end

    anthropic_messages = convert_messages_to_anthropic(other_messages)

    anthropic_request =
      %{
        "model" => request["model"],
        "messages" => anthropic_messages,
        "max_tokens" => request["max_tokens"] || request["max_completion_tokens"] || 4096,
        "stream" => request["stream"],
        "tools" => convert_openai_tools_to_anthropic(request["tools"])
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    anthropic_request =
      if system_prompt do
        Map.put(anthropic_request, "system", system_prompt)
      else
        anthropic_request
      end

    # Add optional parameters
    anthropic_request =
      anthropic_request
      |> maybe_add_param(request, "temperature")
      |> maybe_add_param(request, "top_p")
      |> maybe_add_param(request, "top_k")

    # Add tool_choice if present
    anthropic_request =
      case request["tool_choice"] do
        "auto" ->
          Map.put(anthropic_request, "tool_choice", %{"type" => "auto"})

        "none" ->
          Map.put(anthropic_request, "tool_choice", %{"type" => "any"})

        tool_choice when is_map(tool_choice) ->
          Map.put(anthropic_request, "tool_choice", tool_choice)

        _ ->
          anthropic_request
      end

    # Remove nil values
    body =
      anthropic_request
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Map.new()

    {headers_from_openai(headers), body}
  end

  def from_openai_request(headers, body, _path), do: {headers_from_openai(headers), body}

  # Response conversion: Anthropic -> OpenAI
  @impl true
  def to_openai_response(%{"content" => content} = response, _path) do
    # Convert Anthropic response to OpenAI format
    {text_content, tool_calls} = extract_content_and_tool_calls(content)

    message =
      if tool_calls != [] do
        %{
          "role" => "assistant",
          "content" => text_content || nil,
          "tool_calls" => tool_calls
        }
      else
        %{
          "role" => "assistant",
          "content" => text_content
        }
      end

    %{
      "id" => response["id"] || generate_id("chatcmpl"),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => map_finish_reason_to_openai(response["stop_reason"])
        }
      ],
      "usage" => map_usage_to_openai(response["usage"])
    }
  end

  def to_openai_response(response, path) when is_binary(response) do
    # Try to parse as JSON
    case Jason.decode(response) do
      {:ok, decoded} -> to_openai_response(decoded, path)
      {:error, _} -> response
    end
  end

  def to_openai_response(response, _path), do: response

  # Response conversion: OpenAI -> Anthropic
  @impl true
  def from_openai_response(%{"choices" => [_ | _] = choices} = response, _path) do
    # Convert OpenAI response to Anthropic format
    choice = List.first(choices)
    message = choice["message"]

    content_blocks = convert_openai_message_to_anthropic_content(message)

    %{
      "id" => response["id"] || generate_id("msg"),
      "type" => "message",
      "role" => "assistant",
      "content" => content_blocks,
      "model" => response["model"],
      "stop_reason" => map_finish_reason_to_anthropic(choice["finish_reason"]),
      "stop_sequence" => nil,
      "usage" => map_usage_to_anthropic(response["usage"])
    }
  end

  def from_openai_response(response, _path) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> from_openai_response(decoded, "/v1/messages")
      {:error, _} -> response
    end
  end

  def from_openai_response(response, _path), do: response

  # Streaming conversion: Anthropic -> OpenAI
  @impl true
  def to_openai_stream_chunk(chunk, _path) do
    # Parse SSE data
    case parse_sse_chunk(chunk) do
      {:data, data} when is_binary(data) ->
        case Jason.decode(data) do
          {:ok, decoded} -> handle_anthropic_stream_event(decoded)
          {:error, _} -> [chunk]
        end

      :done ->
        :done

      {:error, _} ->
        [chunk]
    end
  end

  # Streaming conversion: OpenAI -> Anthropic
  @impl true
  def from_openai_stream_chunk(chunk, _path) do
    case parse_sse_chunk(chunk) do
      {:data, data} when is_binary(data) ->
        case data do
          "[DONE]" ->
            :done

          _ ->
            case Jason.decode(data) do
              {:ok, decoded} -> handle_openai_stream_event(decoded)
              {:error, _} -> [chunk]
            end
        end

      :done ->
        data = "event: message_stop\ndata: #{Jason.encode!(%{type: "message_stop"})}\n\n"
        {:done, [data]}

      {:error, _} ->
        [chunk]
    end
  end

  # Path conversion
  @impl true
  def to_openai_path("/v1/messages"), do: "/v1/chat/completions"
  def to_openai_path(_path), do: "/v1/chat/completions"

  @impl true
  def from_openai_path("/v1/chat/completions"), do: "/v1/messages"
  def from_openai_path("/v1/completions"), do: "/v1/messages"
  def from_openai_path(_path), do: "/v1/messages"

  @impl true
  def get_path_type("/v1/messages"), do: {:chat, "/v1/messages"}
  def get_path_type(path), do: {:other, path}

  # Private helpers

  defp headers_to_openai(headers) do
    Stream.reject(headers, &(elem(&1, 0) == "anthropic-version"))
    |> Enum.map(fn
      {"x-api-key", key} ->
        {"Authorization", "Bearer #{key}"}

      other ->
        other
    end)
  end

  defp headers_from_openai(headers) do
    Enum.map(headers, fn
      {"Authorization", "Bearer " <> key} ->
        {"x-api-key", key}

      other ->
        other
    end)
    |> List.insert_at(0, {"anthropic-version", "2023-06-01"})
  end

  # Message conversion helpers

  defp convert_messages_to_openai(messages) do
    Enum.map(messages, &convert_anthropic_message_to_openai/1)
  end

  defp convert_anthropic_message_to_openai(%{"role" => role, "content" => content} = message) do
    # Handle Anthropic content blocks
    {text_content, images, tool_calls, tool_use_content} =
      parse_anthropic_content_blocks(content)

    base = %{"role" => role}

    # Build the content
    base =
      cond do
        # Tool result message
        role == "user" and tool_use_content != [] ->
          Map.put(base, "content", tool_use_content)

        # Message with tool calls
        tool_calls != [] ->
          base
          |> Map.put("content", text_content)
          |> Map.put("tool_calls", tool_calls)

        # Message with images
        images != [] ->
          content_parts = [%{"type" => "text", "text" => text_content}]

          image_parts =
            Enum.map(images, fn image_data ->
              %{
                "type" => "image_url",
                "image_url" => %{
                  "url" => image_data
                }
              }
            end)

          Map.put(base, "content", content_parts ++ image_parts)

        # Plain text message
        true ->
          Map.put(base, "content", text_content)
      end

    # Add tool_call_id for tool response messages
    base =
      case message["tool_call_id"] do
        nil -> base
        tool_call_id -> Map.put(base, "tool_call_id", tool_call_id)
      end

    base
  end

  defp convert_anthropic_message_to_openai(message), do: message

  # Parse Anthropic content blocks and extract text, images, tool calls
  defp parse_anthropic_content_blocks(content) when is_binary(content) do
    {content, [], [], nil}
  end

  defp parse_anthropic_content_blocks(content) when is_list(content) do
    Enum.reduce(content, {nil, [], [], []}, fn block, {text, images, tool_calls, tool_results} ->
      case block do
        %{"type" => "text", "text" => t} ->
          new_text = if text == nil, do: t, else: "#{text}\n#{t}"
          {new_text, images, tool_calls, tool_results}

        %{"type" => "image", "source" => source} ->
          image_url = extract_image_url_from_source(source)
          {text, images ++ [image_url], tool_calls, tool_results}

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          tool_call = %{
            "id" => id,
            "type" => "function",
            "function" => %{
              "name" => name,
              "arguments" => Jason.encode!(input)
            }
          }

          {text, images, tool_calls ++ [tool_call], tool_results}

        %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => result_content} ->
          # Tool result in Anthropic format -> tool message in OpenAI format
          result_text =
            case result_content do
              text when is_binary(text) ->
                text

              blocks when is_list(blocks) ->
                blocks
                |> Enum.filter(fn b -> b["type"] == "text" end)
                |> Enum.map(fn b -> b["text"] end)
                |> Enum.join("\n")
            end

          tool_result = %{
            "role" => "tool",
            "tool_call_id" => tool_use_id,
            "content" => result_text
          }

          {text, images, tool_calls, tool_results ++ [tool_result]}

        _ ->
          {text, images, tool_calls, tool_results}
      end
    end)
  end

  defp parse_anthropic_content_blocks(content), do: {content, [], [], []}

  defp extract_image_url_from_source(%{"type" => "url", "url" => url}), do: url

  defp extract_image_url_from_source(%{
         "type" => "base64",
         "media_type" => media_type,
         "data" => data
       }) do
    "data:#{media_type};base64,#{data}"
  end

  defp extract_image_url_from_source(source), do: source["url"] || ""

  defp convert_messages_to_anthropic(messages) do
    Enum.map(messages, &convert_openai_message_to_anthropic/1)
  end

  defp convert_openai_message_to_anthropic(%{"role" => role, "content" => content} = message) do
    # Convert OpenAI message to Anthropic format
    content_blocks = convert_openai_content_to_anthropic(content, message)

    %{"role" => role, "content" => content_blocks}
  end

  defp convert_openai_message_to_anthropic(%{"role" => role} = message) do
    # Handle messages without explicit content (e.g., tool calls)
    content_blocks = convert_openai_content_to_anthropic(nil, message)
    %{"role" => role, "content" => content_blocks}
  end

  defp convert_openai_content_to_anthropic(content, message) do
    # Start with text content
    blocks =
      case content do
        nil -> []
        text when is_binary(text) -> [%{"type" => "text", "text" => text}]
        parts when is_list(parts) -> convert_content_parts_to_anthropic(parts)
        _ -> []
      end

    # Handle tool calls
    blocks =
      case message["tool_calls"] do
        nil -> blocks
        tool_calls -> blocks ++ convert_tool_calls_to_anthropic(tool_calls)
      end

    # If no blocks, add empty text
    if blocks == [] do
      [%{"type" => "text", "text" => ""}]
    else
      blocks
    end
  end

  defp convert_content_parts_to_anthropic(parts) do
    Enum.reduce(parts, [], fn part, acc ->
      case part do
        %{"type" => "text", "text" => text} ->
          acc ++ [%{"type" => "text", "text" => text}]

        %{"type" => "image_url", "image_url" => %{"url" => url}} ->
          acc ++ [convert_image_url_to_anthropic(url)]

        _ ->
          acc
      end
    end)
  end

  defp convert_image_url_to_anthropic(url) do
    case String.split(url, ";base64,", parts: 2) do
      [media_type_with_prefix, base64_data] ->
        # Data URL format: data:image/png;base64,xxx
        media_type = String.trim_leading(media_type_with_prefix, "data:")

        %{
          "type" => "image",
          "source" => %{
            "type" => "base64",
            "media_type" => media_type,
            "data" => base64_data
          }
        }

      _ ->
        # Regular URL
        %{
          "type" => "image",
          "source" => %{
            "type" => "url",
            "url" => url
          }
        }
    end
  end

  defp convert_tool_calls_to_anthropic(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      %{
        "type" => "tool_use",
        "id" => tool_call["id"],
        "name" => tool_call["function"]["name"],
        "input" => parse_arguments(tool_call["function"]["arguments"])
      }
    end)
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args), do: args

  # Tool conversion helpers

  defp convert_anthropic_tools_to_openai(nil), do: nil

  defp convert_anthropic_tools_to_openai(tools) when is_list(tools) do
    Enum.map(tools, &convert_anthropic_tool_to_openai/1)
  end

  defp convert_anthropic_tools_to_openai(_), do: nil

  defp convert_anthropic_tool_to_openai(%{
         "name" => name,
         "description" => description,
         "input_schema" => input_schema
       }) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => input_schema
      }
    }
  end

  defp convert_anthropic_tool_to_openai(tool), do: tool

  defp convert_openai_tools_to_anthropic(nil), do: nil

  defp convert_openai_tools_to_anthropic(tools) when is_list(tools) do
    Enum.map(tools, &convert_openai_tool_to_anthropic/1)
  end

  defp convert_openai_tools_to_anthropic(_), do: nil

  defp convert_openai_tool_to_anthropic(%{"type" => "function", "function" => func}) do
    %{
      "name" => func["name"],
      "description" => func["description"],
      "input_schema" => func["parameters"]
    }
  end

  defp convert_openai_tool_to_anthropic(tool), do: tool

  # Extract content and tool calls from Anthropic response
  defp extract_content_and_tool_calls(content) when is_list(content) do
    {texts, tool_calls} =
      Enum.reduce(content, {[], []}, fn block, {texts, calls} ->
        case block do
          %{"type" => "text", "text" => text} ->
            {texts ++ [text], calls}

          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
            tool_call = %{
              "id" => id,
              "type" => "function",
              "function" => %{
                "name" => name,
                "arguments" => Jason.encode!(input)
              }
            }

            {texts, calls ++ [tool_call]}

          _ ->
            {texts, calls}
        end
      end)

    text_content = Enum.join(texts, "\n")
    final_text = if text_content == "", do: nil, else: text_content
    {final_text, tool_calls}
  end

  defp extract_content_and_tool_calls(content) when is_binary(content), do: {content, []}
  defp extract_content_and_tool_calls(_), do: {nil, []}

  # Convert OpenAI message content to Anthropic content blocks
  defp convert_openai_message_to_anthropic_content(%{"tool_calls" => tool_calls} = message) do
    # First add text content if present
    text_blocks =
      case message["content"] do
        nil -> []
        "" -> []
        text when is_binary(text) -> [%{"type" => "text", "text" => text}]
        _ -> []
      end

    # Then add tool use blocks
    tool_blocks = convert_tool_calls_to_anthropic(tool_calls)

    text_blocks ++ tool_blocks
  end

  defp convert_openai_message_to_anthropic_content(%{
         "role" => "tool",
         "tool_call_id" => tool_call_id,
         "content" => content
       }) do
    # Tool result in OpenAI format -> tool_result in Anthropic format
    [
      %{
        "type" => "tool_result",
        "tool_use_id" => tool_call_id,
        "content" => content || ""
      }
    ]
  end

  defp convert_openai_message_to_anthropic_content(message) do
    case message["content"] do
      nil -> [%{"type" => "text", "text" => ""}]
      text when is_binary(text) -> [%{"type" => "text", "text" => text}]
      parts when is_list(parts) -> convert_content_parts_to_anthropic(parts)
      _ -> [%{"type" => "text", "text" => ""}]
    end
  end

  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(fn block -> block["type"] == "text" end)
    |> Enum.map(fn block -> block["text"] end)
    |> Enum.join("\n")
  end

  defp extract_system_text(system) when is_list(system) do
    system
    |> Enum.map(fn
      %{"text" => text} -> text
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_system_text(_), do: ""

  defp map_finish_reason_to_openai("end_turn"), do: "stop"
  defp map_finish_reason_to_openai("max_tokens"), do: "length"
  defp map_finish_reason_to_openai("stop_sequence"), do: "stop"
  defp map_finish_reason_to_openai("tool_use"), do: "tool_calls"
  defp map_finish_reason_to_openai(reason), do: reason

  defp map_finish_reason_to_anthropic("stop"), do: "end_turn"
  defp map_finish_reason_to_anthropic("length"), do: "max_tokens"
  defp map_finish_reason_to_anthropic("tool_calls"), do: "tool_use"
  defp map_finish_reason_to_anthropic(reason), do: reason

  defp map_usage_to_openai(nil),
    do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  defp map_usage_to_openai(usage) do
    %{
      "prompt_tokens" => usage["input_tokens"] || 0,
      "completion_tokens" => usage["output_tokens"] || 0,
      "total_tokens" => (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
    }
  end

  defp map_usage_to_anthropic(nil), do: %{"input_tokens" => 0, "output_tokens" => 0}

  defp map_usage_to_anthropic(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || 0
    }
  end

  defp maybe_add_param(target, source, key) do
    case Map.get(source, key) do
      nil -> target
      value -> Map.put(target, key, value)
    end
  end

  defp generate_id(prefix) do
    random_suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    "#{prefix}-#{random_suffix}"
  end

  # SSE parsing helpers

  defp parse_sse_chunk(chunk) do
    cond do
      String.contains?(chunk, "[DONE]") ->
        :done

      String.starts_with?(chunk, "data:") ->
        case String.split(chunk, "data:", parts: 2) do
          [_, data] -> {:data, String.trim(data)}
          _ -> {:error, :invalid_format}
        end

      true ->
        {:error, :invalid_format}
    end
  end

  defp handle_anthropic_stream_event(%{"type" => "content_block_delta"} = event) do
    delta = event["delta"]
    text = delta["text"] || ""

    openai_chunk = %{
      "id" => Map.get(event, :id, generate_id("chatcmpl")),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => Map.get(event, :model, "claude"),
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"content" => text},
          "finish_reason" => nil
        }
      ]
    }

    data = "data: #{Jason.encode!(openai_chunk)}\n\n"
    [data]
  end

  defp handle_anthropic_stream_event(%{"type" => "content_block_start"} = event) do
    # Handle tool use in streaming
    case event["content_block"] do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        # Start of a tool call - send as delta
        openai_chunk = %{
          "id" => generate_id("chatcmpl"),
          "object" => "chat.completion.chunk",
          "created" => System.system_time(:second),
          "model" => Map.get(event, "model", "claude"),
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => id,
                    "type" => "function",
                    "function" => %{
                      "name" => name,
                      "arguments" => ""
                    }
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        }

        ["data: #{Jason.encode!(openai_chunk)}\n\n"]

      _ ->
        []
    end
  end

  defp handle_anthropic_stream_event(%{"type" => "message_start"}), do: []
  defp handle_anthropic_stream_event(%{"type" => "message_stop"}), do: ["data: [DONE]\n\n"]
  defp handle_anthropic_stream_event(%{"type" => "content_block_stop"}), do: []

  defp handle_anthropic_stream_event(%{"type" => "message_delta"} = event) do
    # Handle finish reason
    finish_reason = event["delta"]["stop_reason"]

    openai_chunk = %{
      "id" => generate_id("chatcmpl"),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => Map.get(event, "model", "claude"),
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => map_finish_reason_to_openai(finish_reason)
        }
      ]
    }

    ["data: #{Jason.encode!(openai_chunk)}\n\n"]
  end

  defp handle_anthropic_stream_event(_event), do: []

  defp handle_openai_stream_event(%{"choices" => choices} = event) do
    choice = List.first(choices, %{})
    delta = Map.get(choice, "delta", %{})
    finish_reason = Map.get(choice, "finish_reason")

    anthropic_event =
      cond do
        finish_reason != nil and finish_reason != "" ->
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => map_finish_reason_to_anthropic(finish_reason)},
            "usage" => %{"output_tokens" => 0}
          }

        Map.get(delta, "tool_calls") != nil ->
          # Handle tool calls in streaming
          handle_tool_calls_stream(delta["tool_calls"], event)

        Map.get(delta, "content") != nil ->
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => delta["content"]}
          }

        Map.get(delta, "role") == "assistant" ->
          %{
            "type" => "message_start",
            "message" => %{
              "id" => event["id"],
              "type" => "message",
              "role" => "assistant",
              "content" => [],
              "model" => event["model"],
              "stop_reason" => nil,
              "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
            }
          }

        true ->
          nil
      end

    case anthropic_event do
      nil ->
        []

      events when is_list(events) ->
        Enum.map(events, fn evt ->
          "event: #{evt["type"]}\ndata: #{Jason.encode!(evt)}\n\n"
        end)

      event ->
        data = "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
        [data]
    end
  end

  defp handle_tool_calls_stream(tool_calls, event) do
    # Convert OpenAI tool call deltas to Anthropic format
    Enum.map(tool_calls, fn tc ->
      %{
        "type" => "content_block_delta",
        "index" => Map.get(tc, "index", 0),
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => Map.get(tc["function"] || %{}, "arguments", "")
        }
      }
    end)
  end

  defp handle_openai_stream_event(_event) do
    []
  end
end
