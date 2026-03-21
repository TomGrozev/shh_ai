defmodule ShhAi.ApiConverter.Anthropic do
  @moduledoc """
  Anthropic API format converter.
  Converts between OpenAI format (canonical) and Anthropic Messages API format.
  """

  @behaviour ShhAi.ApiConverter

  # Request conversion: Anthropic -> OpenAI
  @impl true
  def to_openai_request(headers, %{"messages" => messages} = request, _path) do
    # Convert Anthropic messages format to OpenAI format
    openai_messages = convert_messages_to_openai(messages)

    openai_request = %{
      "model" => request["model"],
      "messages" => openai_messages,
      "stream" => request["stream"],
      "temperature" => request["temperature"],
      "top_p" => request["top_p"],
      "max_tokens" => request["max_tokens"]
    }

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

  def to_openai_request(request, _path), do: request

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

    anthropic_request = %{
      "model" => request["model"],
      "messages" => anthropic_messages,
      "max_tokens" => request["max_tokens"] || request["max_completion_tokens"] || 4096,
      "stream" => request["stream"]
    }

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

    # Remove nil values
    body =
      anthropic_request
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Map.new()

    {headers_from_openai(headers), body}
  end

  def from_openai_request(request, _path), do: request

  # Response conversion: Anthropic -> OpenAI
  @impl true
  def to_openai_response(%{"content" => content} = response, _path) do
    # Convert Anthropic response to OpenAI format
    text_content = extract_text_content(content)

    %{
      "id" => response["id"] || generate_id("chatcmpl"),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => text_content
          },
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

    %{
      "id" => response["id"] || generate_id("msg"),
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{
          "type" => "text",
          "text" => message["content"] || ""
        }
      ],
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

  defp convert_messages_to_openai(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => msg["role"],
        "content" => convert_content_to_openai(msg["content"])
      }
    end)
  end

  defp convert_content_to_openai(content) when is_binary(content), do: content

  defp convert_content_to_openai(content) when is_list(content) do
    # Anthropic content blocks to OpenAI format
    text_parts =
      content
      |> Enum.filter(fn block -> block["type"] == "text" end)
      |> Enum.map(fn block -> block["text"] end)
      |> Enum.join("\n")

    # For now, just return text. Image handling would need more work.
    text_parts
  end

  defp convert_messages_to_anthropic(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => msg["role"],
        "content" => convert_content_to_anthropic(msg["content"])
      }
    end)
  end

  defp convert_content_to_anthropic(content) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp convert_content_to_anthropic(content) when is_list(content) do
    # OpenAI content parts to Anthropic format
    Enum.map(content, fn part ->
      case part do
        %{"type" => "text", "text" => text} ->
          %{"type" => "text", "text" => text}

        %{"type" => "image_url", "image_url" => %{"url" => url}} ->
          %{
            "type" => "image",
            "source" => %{
              "type" => "url",
              "url" => url
            }
          }

        _ ->
          %{"type" => "text", "text" => inspect(part)}
      end
    end)
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

  defp handle_anthropic_stream_event(%{"type" => "message_start"} = event), do: []

  defp handle_anthropic_stream_event(%{"type" => "message_stop"}), do: ["data: [DONE]\n\n"]
  defp handle_anthropic_stream_event(%{"type" => "content_block_start"}), do: []
  defp handle_anthropic_stream_event(%{"type" => "content_block_stop"}), do: []
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

      event ->
        data = "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
        [data]
    end
  end

  defp handle_openai_stream_event(_event) do
    []
  end
end
