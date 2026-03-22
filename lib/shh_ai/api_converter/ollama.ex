defmodule ShhAi.ApiConverter.Ollama do
  @moduledoc """
  Ollama API format converter.
  Converts between OpenAI format (canonical) and Ollama API format.

  Supports:
  - Chat completions with text, images, and tools
  - Generate endpoint
  - Embeddings
  - Model listing
  """

  @behaviour ShhAi.ApiConverter

  # Request conversion: Ollama -> OpenAI
  @impl true
  def to_openai_request(headers, %{"messages" => messages} = request, _path) do
    # Convert Ollama messages to OpenAI format (handle images and tools)
    openai_messages = Enum.map(messages, &convert_ollama_message_to_openai/1)

    body =
      %{
        "model" => request["model"],
        "messages" => openai_messages,
        "stream" => request["stream"],
        "temperature" => request["options"]["temperature"],
        "top_p" => request["options"]["top_p"],
        "max_tokens" => request["options"]["num_predict"],
        "tools" => request["tools"],
        "tool_choice" => request["tool_choice"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    {headers, body}
  end

  def to_openai_request(headers, %{"prompt" => prompt} = request, "/api/generate") do
    openai_messages =
      Enum.map([%{"role" => "user", "content" => prompt}], &convert_ollama_message_to_openai/1)

    # Convert Ollama generate to OpenAI chat completion
    body =
      %{
        "model" => request["model"],
        "messages" => openai_messages,
        "stream" => request["stream"],
        "max_tokens" => request["options"]["num_predict"],
        "temperature" => request["options"]["temperature"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    {headers, body}
  end

  def to_openai_request(headers, body, _path), do: {headers, body}

  # Request conversion: OpenAI -> Ollama
  @impl true
  def from_openai_request(headers, %{"messages" => messages} = request, "/api/chat") do
    ollama_messages = Enum.map(messages, &convert_openai_message_to_ollama/1)

    ollama_request = %{
      "model" => request["model"],
      "messages" => ollama_messages,
      "stream" => request["stream"] || false,
      "tools" => request["tools"]
    }

    # Build options from OpenAI parameters
    options =
      %{
        "temperature" => request["temperature"],
        "top_p" => request["top_p"],
        "max_tokens" => request["max_tokens"]
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    ollama_request =
      if map_size(options) > 0 do
        Map.put(ollama_request, "options", options)
      else
        ollama_request
      end
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    {headers, ollama_request}
  end

  def from_openai_request(headers, %{"messages" => messages} = request, "/api/generate") do
    # Convert chat to generate format (use last user message as prompt)
    last_user_message =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m["role"] == "user" end)

    prompt = if last_user_message, do: last_user_message["content"], else: ""

    body =
      %{
        "model" => request["model"],
        "prompt" => prompt,
        "stream" => request["stream"] || false
      }

    {headers, body}
  end

  def from_openai_request(headers, body, _path), do: {headers, body}

  # Response conversion: Ollama -> OpenAI
  @impl true
  def to_openai_response(
        %{"message" => %{"content" => content} = message} = response,
        "/api/chat"
      ) do
    %{
      "id" => generate_id("chatcmpl"),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => convert_ollama_response_message_to_openai(message, content),
          "finish_reason" => map_finish_reason_to_openai(response["done_reason"])
        }
      ],
      "usage" => map_usage_to_openai(response)
    }
  end

  def to_openai_response(%{"response" => content} = response, "/api/generate") do
    %{
      "id" => generate_id("chatcmpl"),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => map_usage_to_openai(response)
    }
  end

  def to_openai_response(response, path) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> to_openai_response(decoded, path)
      {:error, _} -> response
    end
  end

  def to_openai_response(response, _path), do: response

  # Response conversion: OpenAI -> Ollama
  @impl true
  def from_openai_response(%{"choices" => [_ | _] = choices} = response, "/api/chat") do
    choice = List.first(choices)
    message = choice["message"]

    ollama_message = convert_openai_message_to_ollama_response(message)

    %{
      "model" => response["model"],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => ollama_message,
      "done" => true,
      "done_reason" => map_finish_reason_to_ollama(choice["finish_reason"])
    }
    |> maybe_add_usage(response["usage"])
  end

  def from_openai_response(%{"choices" => [_ | _] = choices} = response, "/api/generate") do
    choice = List.first(choices)
    message = choice["message"]

    %{
      "model" => response["model"],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "response" => message["content"] || "",
      "done" => true
    }
    |> maybe_add_usage(response["usage"])
  end

  def from_openai_response(response, path) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> from_openai_response(decoded, path)
      {:error, _} -> response
    end
  end

  def from_openai_response(response, _path), do: response

  # Streaming conversion: Ollama -> OpenAI
  @impl true
  def to_openai_stream_chunk(chunk, path) do
    case Jason.decode(chunk) do
      {:ok, decoded} -> handle_ollama_stream_event(decoded, path)
      {:error, _} -> [chunk]
    end
  end

  # Streaming conversion: OpenAI -> Ollama
  @impl true
  def from_openai_stream_chunk(chunk, _path) do
    case parse_sse_chunk(chunk) do
      {:data, data} ->
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
        :done

      {:error, _} ->
        [chunk]
    end
  end

  # Path conversion
  @impl true
  def to_openai_path("/api/chat"), do: "/v1/chat/completions"
  def to_openai_path("/api/generate"), do: "/v1/chat/completions"
  def to_openai_path("/api/embeddings"), do: "/v1/embeddings"
  def to_openai_path("/api/tags"), do: "/v1/models"
  def to_openai_path(_path), do: "/v1/chat/completions"

  @impl true
  def from_openai_path("/v1/chat/completions"), do: "/api/chat"
  def from_openai_path("/v1/completions"), do: "/api/generate"
  def from_openai_path("/v1/embeddings"), do: "/api/embeddings"
  def from_openai_path("/v1/models"), do: "/api/tags"
  def from_openai_path(_path), do: "/api/chat"

  @impl true
  def get_path_type("/api/chat"), do: {:chat, "/api/chat"}
  def get_path_type("/api/generate"), do: {:chat, "/api/generate"}
  def get_path_type("/api/embeddings"), do: {:embeddings, "/api/embeddings"}
  def get_path_type("/api/tags"), do: {:models, "/api/tags"}
  def get_path_type(path), do: {:other, path}

  # Private helpers - Message conversion

  defp convert_ollama_message_to_openai(%{"role" => role, "content" => content} = message) do
    images = Map.get(message, "images", [])

    content_part = %{"type" => "text", "text" => content}

    # Handle images in Ollama format (base64 array)
    image_content =
      Enum.map(images, fn img_data ->
        %{
          "type" => "image_url",
          "image_url" => %{
            "url" => "data:image/jpeg;base64,#{img_data}"
          }
        }
      end)

    %{"role" => role, "content" => [content_part | image_content]}
  end

  defp convert_ollama_message_to_openai(message), do: message

  defp convert_openai_message_to_ollama(%{"role" => role, "content" => content} = message) do
    base = %{"role" => role}

    # Handle OpenAI content array format (text + images)
    {text_content, images} = extract_content_and_images(content)

    base = Map.put(base, "content", text_content)

    # Add images if present
    base =
      if images != [] do
        Map.put(base, "images", images)
      else
        base
      end

    # Handle tool calls
    base =
      case message["tool_calls"] do
        nil ->
          base

        tool_calls when is_list(tool_calls) ->
          ollama_tool_calls = Enum.map(tool_calls, &convert_openai_tool_call_to_ollama/1)
          Map.put(base, "tool_calls", ollama_tool_calls)
      end

    # Handle tool call id for tool response messages
    base =
      case message["tool_call_id"] do
        nil -> base
        tool_call_id -> Map.put(base, "tool_call_id", tool_call_id)
      end

    base
  end

  defp convert_openai_message_to_ollama(message), do: message

  # Extract text content and images from OpenAI content format
  defp extract_content_and_images(content) when is_binary(content) do
    {content, []}
  end

  defp extract_content_and_images(content) when is_list(content) do
    {text_parts, images} =
      Enum.reduce(content, {[], []}, fn part, {texts, imgs} ->
        case part do
          %{"type" => "text", "text" => text} ->
            {texts ++ [text], imgs}

          %{"type" => "image_url", "image_url" => %{"url" => url}} ->
            # Extract base64 data from data URL or use as-is
            image_data = extract_base64_from_url(url)
            {texts, imgs ++ [image_data]}

          _ ->
            {texts, imgs}
        end
      end)

    {Enum.join(text_parts, "\n"), images}
  end

  defp extract_content_and_images(content), do: {content, []}

  # Extract base64 data from data URL or return as-is
  defp extract_base64_from_url("data:" <> _ = data_url) do
    case Regex.run(~r/;base64,(.+)$/, data_url) do
      [_, base64_data] -> base64_data
      _ -> data_url
    end
  end

  defp extract_base64_from_url(url), do: url

  # Tool call conversion helpers

  defp convert_ollama_tool_call_to_openai(%{"function" => func} = tool_call) do
    %{
      "id" => tool_call["id"] || generate_id("call"),
      "type" => "function",
      "function" => %{
        "name" => func["name"],
        "arguments" => func["arguments"]
      }
    }
  end

  defp convert_ollama_tool_call_to_openai(tool_call), do: tool_call

  defp convert_openai_tool_call_to_ollama(%{"id" => id, "function" => func}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => func["name"],
        "arguments" => func["arguments"]
      }
    }
  end

  defp convert_openai_tool_call_to_ollama(tool_call), do: tool_call

  # Response message conversion

  defp convert_ollama_response_message_to_openai(
         %{"tool_calls" => tool_calls} = _message,
         _content
       ) do
    openai_tool_calls = Enum.map(tool_calls, &convert_ollama_tool_call_to_openai/1)

    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => openai_tool_calls
    }
  end

  defp convert_ollama_response_message_to_openai(message, content) do
    %{
      "role" => message["role"] || "assistant",
      "content" => content
    }
  end

  defp convert_openai_message_to_ollama_response(%{"tool_calls" => tool_calls} = message) do
    %{
      "role" => "assistant",
      "content" => message["content"],
      "tool_calls" => Enum.map(tool_calls, &convert_openai_tool_call_to_ollama/1)
    }
  end

  defp convert_openai_message_to_ollama_response(message) do
    %{
      "role" => "assistant",
      "content" => message["content"] || ""
    }
  end

  # Finish reason mapping

  defp map_finish_reason_to_openai("stop"), do: "stop"
  defp map_finish_reason_to_openai("length"), do: "length"
  defp map_finish_reason_to_openai("tool_calls"), do: "tool_calls"
  defp map_finish_reason_to_openai(_), do: "stop"

  defp map_finish_reason_to_ollama("stop"), do: "stop"
  defp map_finish_reason_to_ollama("length"), do: "length"
  defp map_finish_reason_to_ollama("tool_calls"), do: "tool_calls"
  defp map_finish_reason_to_ollama(_), do: "stop"

  # Usage mapping

  defp map_usage_to_openai(%{"prompt_eval_count" => prompt, "eval_count" => completion}) do
    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" => prompt + completion
    }
  end

  defp map_usage_to_openai(%{"eval_count" => completion}) do
    %{
      "prompt_tokens" => 0,
      "completion_tokens" => completion,
      "total_tokens" => completion
    }
  end

  defp map_usage_to_openai(_),
    do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  defp maybe_add_usage(response, nil), do: response

  defp maybe_add_usage(response, usage) do
    response
    |> Map.put("prompt_eval_count", usage["prompt_tokens"] || 0)
    |> Map.put("eval_count", usage["completion_tokens"] || 0)
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

  defp handle_ollama_stream_event(
         %{"message" => %{"content" => content} = message} = event,
         "/api/chat"
       ) do
    # Check for tool calls in streaming response
    delta =
      case message["tool_calls"] do
        nil ->
          %{"content" => content}

        tool_calls ->
          %{"tool_calls" => Enum.map(tool_calls, &convert_ollama_tool_call_to_openai/1)}
      end

    openai_chunk = %{
      "id" => Map.get(event, "id", generate_id("chatcmpl")),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => event["model"],
      "choices" => [
        %{
          "index" => 0,
          "delta" => delta,
          "finish_reason" => nil
        }
      ]
    }

    data = "data: #{Jason.encode!(openai_chunk)}\n\n"
    [data]
  end

  defp handle_ollama_stream_event(%{"response" => content} = event, "/api/generate") do
    openai_chunk = %{
      "id" => Map.get(event, "id", generate_id("chatcmpl")),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => event["model"],
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"content" => content},
          "finish_reason" => nil
        }
      ]
    }

    data = "data: #{Jason.encode!(openai_chunk)}\n\n"
    [data]
  end

  defp handle_ollama_stream_event(%{"done" => true} = event, _path) do
    finish_reason =
      case event["done_reason"] do
        "stop" -> "stop"
        "length" -> "length"
        "tool_calls" -> "tool_calls"
        _ -> "stop"
      end

    openai_chunk = %{
      "id" => Map.get(event, "id", generate_id("chatcmpl")),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => Map.get(event, "model", ""),
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => finish_reason
        }
      ]
    }

    data = "data: #{Jason.encode!(openai_chunk)}\n\n"
    [data, "data: [DONE]\n\n"]
  end

  defp handle_ollama_stream_event(_event, _path), do: []

  defp handle_openai_stream_event(%{"choices" => choices} = event) do
    choice = List.first(choices, %{})
    delta = Map.get(choice, "delta", %{})
    finish_reason = Map.get(choice, "finish_reason")

    ollama_chunk =
      cond do
        finish_reason != nil and finish_reason != "" ->
          %{
            "model" => Map.get(event, "model", "llama3"),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "done" => true,
            "done_reason" => map_finish_reason_to_ollama(finish_reason)
          }

        Map.get(delta, "tool_calls") != nil ->
          %{
            "model" => Map.get(event, "model", "llama3"),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "message" => %{
              "role" => "assistant",
              "tool_calls" => Enum.map(delta["tool_calls"], &convert_openai_tool_call_to_ollama/1)
            },
            "done" => false
          }

        Map.get(delta, "content") != nil ->
          %{
            "model" => Map.get(event, "model", "llama3"),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "message" => %{
              "role" => "assistant",
              "content" => delta["content"]
            },
            "done" => false
          }

        Map.get(delta, "role") == "assistant" ->
          nil

        true ->
          nil
      end

    case ollama_chunk do
      nil ->
        []

      chunk ->
        data = "#{Jason.encode!(chunk)}\n"
        [data]
    end
  end

  defp handle_openai_stream_event(_event) do
    []
  end
end
