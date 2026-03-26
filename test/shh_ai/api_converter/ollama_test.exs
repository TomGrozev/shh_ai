defmodule ShhAi.ApiConverter.OllamaTest do
  use ExUnit.Case, async: true

  alias ShhAi.ApiConverter.Ollama

  describe "to_openai_request/3" do
    test "converts Ollama chat format to OpenAI format" do
      headers = [{"content-type", "application/json"}]

      body = %{
        "model" => "llama3",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "stream" => false
      }

      {converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      assert Map.has_key?(converted_body, "messages")
      assert Map.has_key?(converted_body, "model")
      # Headers should pass through unchanged
      assert converted_headers == headers
    end

    test "converts Ollama generate format to OpenAI format" do
      headers = []

      body = %{
        "model" => "llama3",
        "prompt" => "Hello",
        "stream" => false
      }

      {_converted_headers, converted_body} =
        Ollama.to_openai_request(headers, body, "/api/generate")

      # Generate should be converted to chat format
      assert Map.has_key?(converted_body, "messages")
      assert Map.has_key?(converted_body, "model")
    end

    test "converts Ollama options to OpenAI parameters" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "options" => %{
          "temperature" => 0.7,
          "top_p" => 0.9,
          "num_predict" => 100
        }
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      assert Map.get(converted_body, "temperature") == 0.7
      assert Map.get(converted_body, "top_p") == 0.9
      assert Map.get(converted_body, "max_tokens") == 100
    end

    test "converts Ollama images to OpenAI image_url format" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [
          %{
            "role" => "user",
            "content" => "What's in this image?",
            "images" => ["base64imagedata"]
          }
        ]
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [user_msg | _] = messages
      content = Map.get(user_msg, "content")
      assert is_list(content)
      # Should have text and image_url parts
      content_types = Enum.map(content, fn c -> c["type"] end)
      assert "text" in content_types
      assert "image_url" in content_types
    end
  end

  describe "from_openai_request/3" do
    test "converts OpenAI format to Ollama chat format for /api/chat" do
      headers = [{"content-type", "application/json"}]

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "temperature" => 0.7
      }

      {_converted_headers, converted_body} =
        Ollama.from_openai_request(headers, body, "/api/chat")

      assert Map.has_key?(converted_body, "model")
      assert Map.has_key?(converted_body, "messages")
      assert Map.has_key?(converted_body, "stream")
      # Should have options from OpenAI parameters
      assert Map.has_key?(converted_body, "options")
    end

    test "converts OpenAI format to Ollama generate format for /api/generate" do
      headers = []

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there"},
          %{"role" => "user", "content" => "How are you?"}
        ]
      }

      {_converted_headers, converted_body} =
        Ollama.from_openai_request(headers, body, "/api/generate")

      # Generate format uses prompt from last user message
      assert Map.has_key?(converted_body, "prompt")
      assert Map.has_key?(converted_body, "model")
    end

    test "converts OpenAI images to Ollama format" do
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
                "image_url" => %{"url" => "data:image/png;base64,abc123"}
              }
            ]
          }
        ]
      }

      {_converted_headers, converted_body} =
        Ollama.from_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [user_msg | _] = messages
      # Should have images field
      assert Map.has_key?(user_msg, "images")
      images = Map.get(user_msg, "images", [])
      assert length(images) == 1
      # Should extract base64 data
      assert hd(images) == "abc123"
    end

    test "passes through non-chat/generate requests" do
      headers = []
      body = %{"model" => "test"}

      {_converted_headers, converted_body} =
        Ollama.from_openai_request(headers, body, "/api/embeddings")

      assert converted_body == body
    end
  end

  describe "to_openai_response/2" do
    test "converts Ollama chat response to OpenAI format" do
      response = %{
        "model" => "llama3",
        "created_at" => "2024-01-01T00:00:00Z",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello there!"
        },
        "done" => true,
        "done_reason" => "stop"
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "object")
      assert Map.has_key?(converted, "choices")
      assert Map.has_key?(converted, "model")

      [choice | _] = Map.get(converted, "choices", [])
      assert Map.get(choice, "message")["role"] == "assistant"
      assert Map.get(choice, "message")["content"] == "Hello there!"
      assert Map.get(choice, "finish_reason") == "stop"
    end

    test "converts Ollama generate response to OpenAI format" do
      response = %{
        "model" => "llama3",
        "created_at" => "2024-01-01T00:00:00Z",
        "response" => "Hello there!",
        "done" => true
      }

      converted = Ollama.to_openai_response(response, "/api/generate")

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "choices")

      [choice | _] = Map.get(converted, "choices", [])
      assert Map.get(choice, "message")["content"] == "Hello there!"
    end

    test "converts Ollama tool response to OpenAI format" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_1",
              "type" => "function",
              "function" => %{
                "name" => "get_weather",
                "arguments" => "{\"location\": \"NYC\"}"
              }
            }
          ]
        },
        "done" => true,
        "done_reason" => "tool_calls"
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      [choice | _] = Map.get(converted, "choices", [])
      message = Map.get(choice, "message")
      assert Map.has_key?(message, "tool_calls")
      assert Map.get(choice, "finish_reason") == "tool_calls"
    end
  end

  describe "from_openai_response/2" do
    test "converts OpenAI response to Ollama chat format" do
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

      converted = Ollama.from_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "model")
      assert Map.has_key?(converted, "message")
      assert Map.has_key?(converted, "done")
      assert Map.get(converted, "done") == true
      assert Map.get(converted, "done_reason") == "stop"

      message = Map.get(converted, "message")
      assert Map.get(message, "role") == "assistant"
      assert Map.get(message, "content") == "Hello!"
    end

    test "converts OpenAI response to Ollama generate format" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ]
      }

      converted = Ollama.from_openai_response(response, "/api/generate")

      assert Map.has_key?(converted, "model")
      assert Map.has_key?(converted, "response")
      assert Map.get(converted, "response") == "Hello!"
      assert Map.get(converted, "done") == true
    end

    test "converts OpenAI tool_calls response to Ollama format" do
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
                    "arguments" => "{\"location\": \"NYC\"}"
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      converted = Ollama.from_openai_response(response, "/api/chat")

      message = Map.get(converted, "message")
      assert Map.has_key?(message, "tool_calls")
      assert Map.get(converted, "done_reason") == "tool_calls"
    end
  end

  describe "to_openai_path/1" do
    test "converts /api/chat to /v1/chat/completions" do
      assert Ollama.to_openai_path("/api/chat") == "/v1/chat/completions"
    end

    test "converts /api/generate to /v1/chat/completions" do
      assert Ollama.to_openai_path("/api/generate") == "/v1/chat/completions"
    end

    test "converts /api/embeddings to /v1/embeddings" do
      assert Ollama.to_openai_path("/api/embeddings") == "/v1/embeddings"
    end

    test "converts /api/tags to /v1/models" do
      assert Ollama.to_openai_path("/api/tags") == "/v1/models"
    end

    test "defaults to /v1/chat/completions for unknown paths" do
      assert Ollama.to_openai_path("/api/unknown") == "/v1/chat/completions"
    end
  end

  describe "from_openai_path/1" do
    test "converts /v1/chat/completions to /api/chat" do
      assert Ollama.from_openai_path("/v1/chat/completions") == "/api/chat"
    end

    test "converts /v1/completions to /api/generate" do
      assert Ollama.from_openai_path("/v1/completions") == "/api/generate"
    end

    test "converts /v1/embeddings to /api/embeddings" do
      assert Ollama.from_openai_path("/v1/embeddings") == "/api/embeddings"
    end

    test "converts /v1/models to /api/tags" do
      assert Ollama.from_openai_path("/v1/models") == "/api/tags"
    end

    test "defaults to /api/chat for unknown paths" do
      assert Ollama.from_openai_path("/v1/unknown") == "/api/chat"
    end
  end

  describe "get_path_type/1" do
    test "returns chat type for /api/chat" do
      assert Ollama.get_path_type("/api/chat") == {:chat, "/api/chat"}
    end

    test "returns chat type for /api/generate" do
      assert Ollama.get_path_type("/api/generate") == {:chat, "/api/generate"}
    end

    test "returns embeddings type for /api/embeddings" do
      assert Ollama.get_path_type("/api/embeddings") == {:embeddings, "/api/embeddings"}
    end

    test "returns models type for /api/tags" do
      assert Ollama.get_path_type("/api/tags") == {:models, "/api/tags"}
    end

    test "returns other type for unknown paths" do
      assert Ollama.get_path_type("/api/unknown") == {:other, "/api/unknown"}
    end
  end

  describe "stream chunk conversion" do
    test "converts Ollama chat stream chunk to OpenAI format" do
      chunk = ~s({"model": "llama3", "message": {"content": "Hello"}, "done": false})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      [openai_chunk | _] = result
      assert String.contains?(openai_chunk, "data:")
      assert String.contains?(openai_chunk, "chat.completion.chunk")
    end

    test "converts Ollama generate stream chunk to OpenAI format" do
      chunk = ~s({"model": "llama3", "response": "Hello", "done": false})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/generate")

      assert is_list(result)
      [openai_chunk | _] = result
      assert String.contains?(openai_chunk, "data:")
    end

    test "converts done chunk with finish reason" do
      chunk = ~s({"model": "llama3", "done": true, "done_reason": "stop"})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      # Should have finish reason
      assert Enum.any?(result, fn c -> String.contains?(c, "finish_reason") end)
      # Should have [DONE] marker
      assert Enum.any?(result, fn c -> String.contains?(c, "[DONE]") end)
    end

    test "converts OpenAI stream chunk to Ollama format" do
      event = %{
        "id" => "chatcmpl-123",
        "choices" => [
          %{
            "delta" => %{"content" => "Hello"},
            "finish_reason" => nil
          }
        ]
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      [ollama_chunk | _] = result
      assert String.contains?(ollama_chunk, "message")
    end

    test "handles [DONE] marker" do
      chunk = "data: [DONE]\n\n"

      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert result == :done
    end
  end
end
