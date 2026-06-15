defmodule ShhAi.ApiConverter.AnthropicTest do
  use ExUnit.Case, async: true

  alias ShhAi.ApiConverter.Anthropic

  describe "to_openai_request/3" do
    test "converts Anthropic messages format to OpenAI format" do
      headers = [{"content-type", "application/json"}]

      body = %{
        "model" => "claude-3-opus",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_tokens" => 1024
      }

      {converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      # Should have messages in OpenAI format
      assert Map.has_key?(converted_body, "messages")
      assert Map.has_key?(converted_body, "model")
      assert Map.has_key?(converted_body, "max_tokens")
      # Should not have anthropic-version header
      refute Enum.any?(converted_headers, fn {k, _} -> k == "anthropic-version" end)
    end

    test "converts system prompt from top-level to message" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "system" => "You are a helpful assistant.",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      # System should be added as first message
      messages = Map.get(converted_body, "messages", [])
      assert length(messages) == 2
      [system_msg | rest] = messages
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are a helpful assistant."
      [user_msg | _] = rest
      assert user_msg["role"] == "user"
    end

    test "converts structured system prompt to text" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "system" => [
          %{"type" => "text", "text" => "You are helpful."},
          %{"type" => "text", "text" => "Be concise."}
        ],
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      [system_msg | _] = messages
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful.\nBe concise."
    end

    test "converts Anthropic tool calls to OpenAI format" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [],
        "tools" => [
          %{
            "name" => "get_weather",
            "description" => "Get weather info",
            "input_schema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      }

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      tools = Map.get(converted_body, "tools", [])
      assert length(tools) == 1
      [tool | _] = tools
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "get_weather"
    end

    test "converts x-api-key header to Authorization header" do
      headers = [{"x-api-key", "test-key"}, {"content-type", "application/json"}]
      body = %{"model" => "claude-3-opus", "messages" => []}

      {converted_headers, _converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      # Should have Authorization header with Bearer token
      auth_header = Enum.find(converted_headers, fn {k, _} -> k == "authorization" end)
      assert auth_header != nil
      {"authorization", value} = auth_header
      assert value == "Bearer test-key"
      # Should not have x-api-key
      refute Enum.any?(converted_headers, fn {k, _} -> k == "x-api-key" end)
    end
  end

  describe "from_openai_request/3" do
    test "converts OpenAI format to Anthropic format" do
      headers = [{"content-type", "application/json"}]

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_tokens" => 1024
      }

      {converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      # Should have anthropic-version header
      assert Enum.any?(converted_headers, fn {k, _} -> k == "anthropic-version" end)
      # Should have messages
      assert Map.has_key?(converted_body, "messages")
      assert Map.has_key?(converted_body, "max_tokens")
    end

    test "extracts system message to system field" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      {_converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      # System should be separate
      assert Map.get(converted_body, "system") == "You are helpful."
      # Messages should not include system
      messages = Map.get(converted_body, "messages", [])
      refute Enum.any?(messages, fn m -> m["role"] == "system" end)
    end

    test "converts OpenAI tool calls to Anthropic format" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "description" => "Get weather info",
              "parameters" => %{"type" => "object"}
            }
          }
        ]
      }

      {_converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      tools = Map.get(converted_body, "tools", [])
      assert length(tools) == 1
      [tool | _] = tools
      assert tool["name"] == "get_weather"
      assert Map.has_key?(tool, "input_schema")
    end

    test "converts Authorization header to x-api-key" do
      headers = [{"authorization", "Bearer test-key"}, {"content-type", "application/json"}]
      body = %{"model" => "gpt-4", "messages" => []}

      {converted_headers, _converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      # Should have x-api-key header
      api_key_header = Enum.find(converted_headers, fn {k, _} -> k == "x-api-key" end)
      assert api_key_header != nil
      {"x-api-key", value} = api_key_header
      assert value == "test-key"
    end
  end

  describe "to_openai_response/2" do
    test "converts Anthropic response to OpenAI format" do
      response = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "model" => "claude-3-opus",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "object")
      assert Map.has_key?(converted, "choices")
      assert Map.has_key?(converted, "model")
      assert Map.has_key?(converted, "usage")

      [choice | _] = Map.get(converted, "choices", [])
      assert Map.has_key?(choice, "message")
      assert Map.get(choice, "message")["role"] == "assistant"
      assert Map.get(choice, "message")["content"] == "Hello!"
      assert Map.get(choice, "finish_reason") == "stop"
    end

    test "converts Anthropic tool_use response to OpenAI format" do
      response = %{
        "id" => "msg_123",
        "content" => [
          %{"type" => "text", "text" => "Let me check."},
          %{
            "type" => "tool_use",
            "id" => "tool_1",
            "name" => "get_weather",
            "input" => %{"location" => "NYC"}
          }
        ],
        "model" => "claude-3-opus",
        "stop_reason" => "tool_use"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      [choice | _] = Map.get(converted, "choices", [])
      message = Map.get(choice, "message")
      assert Map.has_key?(message, "tool_calls")
      assert Map.get(choice, "finish_reason") == "tool_calls"
    end
  end

  describe "from_openai_response/2" do
    test "converts OpenAI response to Anthropic format" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}
      }

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "type")
      assert Map.has_key?(converted, "role")
      assert Map.has_key?(converted, "content")
      assert Map.has_key?(converted, "model")
      assert Map.has_key?(converted, "stop_reason")

      content = Map.get(converted, "content", [])
      assert length(content) == 1
      [block | _] = content
      assert block["type"] == "text"
      assert block["text"] == "Hello!"
    end

    test "converts OpenAI tool_calls response to Anthropic format" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => "{\"location\":\"NYC\"}"
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      content = Map.get(converted, "content", [])
      assert length(content) == 1
      [block | _] = content
      assert block["type"] == "tool_use"
      assert block["name"] == "get_weather"
      assert Map.get(converted, "stop_reason") == "tool_use"
    end
  end

  describe "to_openai_path/1" do
    test "converts /v1/messages to /v1/chat/completions" do
      assert Anthropic.to_openai_path("/v1/messages") == "/v1/chat/completions"
    end

    test "defaults to /v1/chat/completions for unknown paths" do
      assert Anthropic.to_openai_path("/v1/unknown") == "/v1/chat/completions"
    end
  end

  describe "from_openai_path/1" do
    test "converts /v1/chat/completions to /v1/messages" do
      assert Anthropic.from_openai_path("/v1/chat/completions") == "/v1/messages"
    end

    test "converts /v1/completions to /v1/messages" do
      assert Anthropic.from_openai_path("/v1/completions") == "/v1/messages"
    end

    test "defaults to /v1/messages for unknown paths" do
      assert Anthropic.from_openai_path("/v1/unknown") == "/v1/messages"
    end
  end

  describe "get_path_type/1" do
    test "returns chat type for /v1/messages" do
      assert Anthropic.get_path_type("/v1/messages") == {:chat, "/v1/messages"}
    end

    test "returns other type for unknown paths" do
      assert Anthropic.get_path_type("/v1/unknown") == {:other, "/v1/unknown"}
    end
  end

  describe "to_openai_stream_chunk/2" do
    test "converts content_block_delta event" do
      chunk =
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      # Filter out empty strings from split
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      assert data_chunks != []
      [data | _] = data_chunks
      assert String.starts_with?(data, "data: ")
    end

    test "converts content_block_start event with tool_use" do
      chunk =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"get_weather\"}}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      # Filter out empty strings from split
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      assert data_chunks != []
      [data | _] = data_chunks
      assert String.contains?(data, "tool_calls")
    end

    test "handles message_start event" do
      chunk =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\",\"role\":\"assistant\"}}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      # Filter out empty strings - message_start returns [] but split may add empty string
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      assert data_chunks == []
    end

    test "handles message_stop event" do
      chunk = "data: {\"type\":\"message_stop\"}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      # Filter out empty strings from split
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      assert data_chunks == ["data: [DONE]\n\n"]
    end

    test "handles content_block_stop event" do
      chunk = "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      # Filter out empty strings - content_block_stop returns [] but split may add empty string
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      assert data_chunks == []
    end

    test "handles message_delta event with stop_reason" do
      chunk = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      # Filter out empty strings from split
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      [data | _] = data_chunks
      assert String.contains?(data, "finish_reason")
    end

    test "handles [DONE] marker" do
      chunk = "data: [DONE]\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      # Returns {:done, chunks} when [DONE] is encountered
      assert match?({:done, _}, result) or result == :done
    end

    test "handles invalid JSON gracefully" do
      chunk = "data: invalid json\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end

    test "handles unrecognized event type" do
      chunk = "data: {\"type\":\"unknown_event\"}\n\n"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      # Filter out empty strings - unrecognized events return [] but split may add empty string
      data_chunks = Enum.filter(result, fn s -> s != "" end)
      assert data_chunks == []
    end
  end

  describe "from_openai_stream_chunk/2" do
    test "converts OpenAI content delta to Anthropic format" do
      chunk =
        "data: {\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      [data | _] = result
      assert String.contains?(data, "content_block_delta")
    end

    test "converts OpenAI role delta to Anthropic message_start" do
      chunk =
        "data: {\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      [data | _] = result
      assert String.contains?(data, "message_start")
    end

    test "converts OpenAI finish_reason to Anthropic message_delta" do
      chunk =
        "data: {\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      # The implementation returns multiple events: content_block_stop and message_delta
      # Find the message_delta event
      message_delta_event =
        Enum.find(result, fn data -> String.contains?(data, "message_delta") end)

      assert message_delta_event != nil
    end

    test "handles [DONE] marker" do
      chunk = "data: [DONE]\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      # When [DONE] is received, it returns {:done, chunks} to signal stream end with final chunks
      assert {:done, chunks} = result
      assert is_list(chunks)
      assert length(chunks) == 1
    end

    test "handles tool_calls in delta" do
      chunk =
        "data: {\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{}\"}}]},\"finish_reason\":null}]}\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end

    test "handles invalid JSON gracefully" do
      chunk = "data: invalid json\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end
  end

  describe "from_openai_request/3 additional cases" do
    test "handles request without messages key" do
      headers = []
      body = %{"model" => "claude-3-opus"}

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      assert Map.has_key?(converted_body, "model")
      refute Map.has_key?(converted_body, "messages")
    end

    test "converts tool_result content blocks" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "tool_1",
                "content" => "Weather: 72°F"
              }
            ]
          }
        ]
      }

      {_headers, converted_body} = Anthropic.to_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      assert length(messages) == 1
      [msg | _] = messages
      # Tool result content blocks are converted to messages with role "tool"
      assert msg["role"] == "tool"
      assert msg["tool_call_id"] == "tool_1"
      assert msg["content"] == "Weather: 72°F"
    end

    test "converts image content blocks" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's this?"},
              %{
                "type" => "image",
                "source" => %{
                  "type" => "url",
                  "url" => "https://example.com/image.png"
                }
              }
            ]
          }
        ]
      }

      {_headers, converted_body} = Anthropic.to_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      content = msg["content"]
      assert is_list(content)
      assert length(content) == 2
    end

    test "converts base64 image source" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's this?"},
              %{
                "type" => "image",
                "source" => %{
                  "type" => "base64",
                  "media_type" => "image/png",
                  "data" => "base64imagedata"
                }
              }
            ]
          }
        ]
      }

      {_headers, converted_body} = Anthropic.to_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      content = msg["content"]
      [_, img_block] = content
      assert img_block["type"] == "image_url"
      assert String.starts_with?(img_block["image_url"]["url"], "data:image/png;base64,")
    end

    test "converts tool_choice parameter" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tool_choice" => "auto"
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.has_key?(converted_body, "tool_choice")
      assert converted_body["tool_choice"]["type"] == "auto"
    end

    test "converts tool_choice none" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tool_choice" => "none"
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.has_key?(converted_body, "tool_choice")
      assert converted_body["tool_choice"]["type"] == "any"
    end

    test "converts tool_choice as map" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tool_choice" => %{"type" => "tool", "name" => "get_weather"}
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.has_key?(converted_body, "tool_choice")
      assert converted_body["tool_choice"]["name"] == "get_weather"
    end
  end

  describe "to_openai_response/2 additional cases" do
    test "handles binary response by parsing JSON" do
      response =
        ~s({"id":"msg_123","content":[{"type":"text","text":"Hello"}],"model":"claude-3"})

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "choices")
    end

    test "handles invalid JSON binary response" do
      response = "not valid json"

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert converted == response
    end

    test "handles response with nil usage" do
      response = %{
        "id" => "msg_123",
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "model" => "claude-3"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "usage")
    end

    test "handles response without id" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "model" => "claude-3"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "id")
      assert String.starts_with?(converted["id"], "chatcmpl-")
    end
  end

  describe "from_openai_response/2 edge cases" do
    test "handles binary response by parsing JSON" do
      response =
        ~s({"id":"chatcmpl-123","model":"gpt-4","choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]})

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "content")
    end

    test "handles invalid JSON binary response" do
      response = "not valid json"

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      assert converted == response
    end

    test "converts finish_reason length to max_tokens" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello"},
            "finish_reason" => "length"
          }
        ]
      }

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      assert converted["stop_reason"] == "max_tokens"
    end

    test "converts finish_reason tool_calls to tool_use" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => []},
            "finish_reason" => "tool_calls"
          }
        ]
      }

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      assert converted["stop_reason"] == "tool_use"
    end

    test "handles response with nil usage" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello"},
            "finish_reason" => "stop"
          }
        ]
      }

      converted = Anthropic.from_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "usage")
    end
  end

  describe "message content conversion edge cases" do
    test "handles OpenAI message with nil content" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "assistant", "content" => nil, "tool_calls" => []}
        ]
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      assert length(messages) == 1
    end

    test "handles OpenAI message with empty string content" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => ""}]
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      assert length(messages) == 1
    end

    test "handles tool message in OpenAI format" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "result data"}
        ]
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      # Tool messages are converted with role "tool" and content as text
      # (current implementation converts content to text format)
      assert msg["role"] == "tool"
      # The content is converted to a text block by current implementation
      content = msg["content"]
      assert is_list(content)
    end

    test "handles multiple system messages" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "system", "content" => "Be helpful."},
          %{"role" => "system", "content" => "Be concise."},
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      # Should use first system message
      assert Map.get(converted_body, "system") == "Be helpful."
    end

    test "converts image_url content in OpenAI format" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's this?"},
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "https://example.com/image.png"}
              }
            ]
          }
        ]
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      content = msg["content"]
      assert length(content) == 2
      [text_block, img_block] = content
      assert text_block["type"] == "text"
      assert img_block["type"] == "image"
    end

    test "converts base64 image_url in OpenAI format" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64,abc123"}
              }
            ]
          }
        ]
      }

      {_headers, converted_body} = Anthropic.from_openai_request(headers, body, "/v1/messages")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      content = msg["content"]
      [img_block | _] = content
      assert img_block["type"] == "image"
      assert img_block["source"]["type"] == "base64"
    end
  end

  describe "to_openai_stream_chunk/2 edge cases" do
    test "handles invalid chunk format" do
      chunk = "invalid format"

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
      assert result == [chunk]
    end

    test "handles empty chunk" do
      chunk = ""

      result = Anthropic.to_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end
  end

  describe "from_openai_stream_chunk/2 edge cases" do
    test "handles invalid JSON in data field" do
      chunk = "data: {invalid json}\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end

    test "handles empty data field" do
      chunk = "data: \n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end

    test "handles unrecognized event type" do
      event = %{"id" => "chatcmpl-123", "choices" => [%{"delta" => %{"unknown" => "value"}}]}
      chunk = "data: #{Jason.encode!(event)}\n\n"

      result = Anthropic.from_openai_stream_chunk(chunk, "/v1/messages")

      assert is_list(result)
    end
  end

  describe "from_openai_request/3 edge cases" do
    test "handles request without messages key" do
      headers = []
      body = %{"model" => "gpt-4"}

      {converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.has_key?(converted_body, "model")
      refute Map.has_key?(converted_body, "messages")
      # Should have anthropic-version header
      assert Enum.any?(converted_headers, fn {k, _} -> k == "anthropic-version" end)
    end

    test "handles empty messages list" do
      headers = []
      body = %{"model" => "gpt-4", "messages" => []}

      {_converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.get(converted_body, "messages") == []
    end

    test "handles temperature parameter" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "test"}],
        "temperature" => 0.7
      }

      {_converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.get(converted_body, "temperature") == 0.7
    end

    test "handles top_p parameter" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "test"}],
        "top_p" => 0.9
      }

      {_converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.get(converted_body, "top_p") == 0.9
    end

    test "handles top_k parameter" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "test"}],
        "top_k" => 40
      }

      {_converted_headers, converted_body} =
        Anthropic.from_openai_request(headers, body, "/v1/messages")

      assert Map.get(converted_body, "top_k") == 40
    end
  end

  describe "to_openai_request/3 additional cases - tools" do
    test "handles request without tools" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [%{"role" => "user", "content" => "test"}]
      }

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      refute Map.has_key?(converted_body, "tools")
    end

    test "handles nil tools" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [%{"role" => "user", "content" => "test"}],
        "tools" => nil
      }

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      refute Map.has_key?(converted_body, "tools")
    end

    test "handles empty tools list" do
      headers = []

      body = %{
        "model" => "claude-3-opus",
        "messages" => [%{"role" => "user", "content" => "test"}],
        "tools" => []
      }

      {_converted_headers, converted_body} =
        Anthropic.to_openai_request(headers, body, "/v1/messages")

      # Empty tools list is preserved (it's a valid tools array)
      assert Map.get(converted_body, "tools") == []
    end
  end

  describe "to_openai_response/2 extra cases" do
    test "handles response without id" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "model" => "claude-3-opus"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "id")
      assert String.starts_with?(converted["id"], "chatcmpl-")
    end

    test "handles response without usage" do
      response = %{
        "id" => "msg_123",
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "model" => "claude-3-opus"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "usage")
      assert converted["usage"]["prompt_tokens"] == 0
      assert converted["usage"]["completion_tokens"] == 0
    end

    test "handles response with nil content" do
      response = %{"id" => "msg_123", "content" => nil, "model" => "claude-3-opus"}

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "choices")
      [choice | _] = converted["choices"]
      assert choice["message"]["content"] == nil
    end

    test "handles response with empty content list" do
      response = %{"id" => "msg_123", "content" => [], "model" => "claude-3-opus"}

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      assert Map.has_key?(converted, "choices")
      [choice | _] = converted["choices"]
      assert choice["message"]["content"] == nil
    end

    test "handles response with multiple text blocks" do
      response = %{
        "id" => "msg_123",
        "content" => [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "text", "text" => "World"}
        ],
        "model" => "claude-3-opus"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      [choice | _] = converted["choices"]
      assert choice["message"]["content"] == "Hello\nWorld"
    end

    test "handles response with unknown content block type" do
      response = %{
        "id" => "msg_123",
        "content" => [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "unknown", "data" => "value"}
        ],
        "model" => "claude-3-opus"
      }

      converted = Anthropic.to_openai_response(response, "/v1/messages")

      [choice | _] = converted["choices"]
      assert choice["message"]["content"] == "Hello"
    end
  end
end
