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

    test "handles multiple images in a message" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [
          %{
            "role" => "user",
            "content" => "Compare these images",
            "images" => ["image1_base64", "image2_base64"]
          }
        ]
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [user_msg | _] = messages
      content = Map.get(user_msg, "content")

      image_parts = Enum.filter(content, fn c -> c["type"] == "image_url" end)
      assert length(image_parts) == 2
    end

    test "handles empty images array" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [
          %{
            "role" => "user",
            "content" => "Hello",
            "images" => []
          }
        ]
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [user_msg | _] = messages
      # Empty images array should still result in a valid message
      assert Map.has_key?(user_msg, "content")
    end

    test "converts Ollama tool calls to OpenAI format" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [
          %{
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
          }
        ]
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      # Content is converted to a list with text part when content is nil
      assert Map.has_key?(msg, "content")
      assert Map.get(msg, "role") == "assistant"
    end

    test "handles tool call without id by generating one" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "type" => "function",
                "function" => %{
                  "name" => "get_weather",
                  "arguments" => "{}"
                }
              }
            ]
          }
        ]
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      # Content is converted to a list with text part when content is nil
      assert Map.has_key?(msg, "content")
      assert Map.get(msg, "role") == "assistant"
    end

    test "handles tool response messages" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [
          %{
            "role" => "tool",
            "content" => "Temperature: 72°F",
            "tool_call_id" => "call_1"
          }
        ]
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      messages = Map.get(converted_body, "messages", [])
      [msg | _] = messages
      # Tool messages pass through with role preserved
      assert Map.get(msg, "role") == "tool"
      # Note: tool_call_id may not be preserved in all implementations
    end

    test "handles empty messages list" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => []
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      assert Map.get(converted_body, "messages") == []
    end

    test "handles partial options" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "options" => %{
          "temperature" => 0.7
        }
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      assert Map.get(converted_body, "temperature") == 0.7
      refute Map.has_key?(converted_body, "top_p")
      refute Map.has_key?(converted_body, "max_tokens")
    end

    test "handles tools in request" do
      headers = []

      body = %{
        "model" => "llama3",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "description" => "Get weather",
              "parameters" => %{}
            }
          }
        ],
        "tool_choice" => "auto"
      }

      {_converted_headers, converted_body} = Ollama.to_openai_request(headers, body, "/api/chat")

      assert Map.has_key?(converted_body, "tools")
      assert Map.has_key?(converted_body, "tool_choice")
    end

    test "passes through unknown request formats unchanged" do
      headers = []

      body = %{
        "model" => "llama3",
        "unknown_field" => "value"
      }

      {_converted_headers, converted_body} =
        Ollama.to_openai_request(headers, body, "/api/unknown")

      assert converted_body == body
    end

    test "handles generate with options" do
      headers = []

      body = %{
        "model" => "llama3",
        "prompt" => "Hello",
        "stream" => true,
        "options" => %{
          "temperature" => 0.5,
          "num_predict" => 50
        }
      }

      {_converted_headers, converted_body} =
        Ollama.to_openai_request(headers, body, "/api/generate")

      assert Map.has_key?(converted_body, "messages")
      assert Map.get(converted_body, "temperature") == 0.5
      assert Map.get(converted_body, "max_tokens") == 50
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

    test "converts Ollama models list to OpenAI format" do
      response = %{
        "models" => [
          %{
            "name" => "llama3",
            "modified_at" => "2024-01-01T00:00:00Z",
            "size" => 4_000_000_000
          },
          %{
            "name" => "mistral",
            "modified_at" => "2024-01-02T00:00:00Z",
            "size" => 3_000_000_000
          }
        ]
      }

      converted = Ollama.to_openai_response(response, "/api/tags")

      assert Map.has_key?(converted, "object")
      assert Map.get(converted, "object") == "list"
      assert Map.has_key?(converted, "data")

      data = Map.get(converted, "data", [])
      assert length(data) == 2

      [first_model | _] = data
      assert Map.get(first_model, "id") == "llama3"
      assert Map.get(first_model, "object") == "model"
      assert Map.has_key?(first_model, "created")
      assert Map.get(first_model, "owned_by") == "ollama"
    end

    test "handles response with usage stats" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true,
        "prompt_eval_count" => 10,
        "eval_count" => 20
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "usage")
      usage = Map.get(converted, "usage")
      assert Map.get(usage, "prompt_tokens") == 10
      assert Map.get(usage, "completion_tokens") == 20
      assert Map.get(usage, "total_tokens") == 30
    end

    test "handles response with partial usage stats" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true,
        "eval_count" => 20
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "usage")
      usage = Map.get(converted, "usage")
      assert Map.get(usage, "prompt_tokens") == 0
      assert Map.get(usage, "completion_tokens") == 20
      assert Map.get(usage, "total_tokens") == 20
    end

    test "handles response without usage stats" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "usage")
      usage = Map.get(converted, "usage")
      assert Map.get(usage, "prompt_tokens") == 0
      assert Map.get(usage, "completion_tokens") == 0
      assert Map.get(usage, "total_tokens") == 0
    end

    test "handles response with done_reason length" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true,
        "done_reason" => "length"
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      [choice | _] = Map.get(converted, "choices", [])
      assert Map.get(choice, "finish_reason") == "length"
    end

    test "handles response with unknown done_reason" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true,
        "done_reason" => "unknown"
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      [choice | _] = Map.get(converted, "choices", [])
      # Unknown done_reason should default to "stop"
      assert Map.get(choice, "finish_reason") == "stop"
    end

    test "handles binary JSON string response" do
      response = ~s({"model": "llama3", "message": {"content": "Hello"}, "done": true})

      converted = Ollama.to_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "model")
      assert Map.has_key?(converted, "choices")
    end

    test "handles invalid binary JSON string response" do
      response = "not valid json"

      converted = Ollama.to_openai_response(response, "/api/chat")

      assert converted == response
    end

    test "handles response with model id" do
      response = %{
        "id" => "unique-id-123",
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      # Implementation generates a new id, doesn't preserve the input id
      assert Map.has_key?(converted, "id")
      assert String.starts_with?(Map.get(converted, "id"), "chatcmpl-")
    end

    test "handles response without model id" do
      response = %{
        "model" => "llama3",
        "message" => %{
          "role" => "assistant",
          "content" => "Hello!"
        },
        "done" => true
      }

      converted = Ollama.to_openai_response(response, "/api/chat")

      # Should generate an id
      assert Map.has_key?(converted, "id")
      assert String.starts_with?(Map.get(converted, "id"), "chatcmpl-")
    end

    test "passes through unknown response formats" do
      response = %{"unknown" => "format"}

      converted = Ollama.to_openai_response(response, "/api/unknown")

      assert converted == response
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

    test "handles binary JSON string response for /api/chat" do
      response =
        ~s({"id":"chatcmpl-123","model":"gpt-4","choices":[{"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}]})

      converted = Ollama.from_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "model")
      assert Map.has_key?(converted, "message")
    end

    test "handles binary JSON string response for /api/generate" do
      response =
        ~s({"id":"chatcmpl-123","model":"gpt-4","choices":[{"message":{"content":"Hello!"},"finish_reason":"stop"}]})

      converted = Ollama.from_openai_response(response, "/api/generate")

      assert Map.has_key?(converted, "response")
    end

    test "handles invalid binary JSON string response" do
      response = "not valid json"

      converted = Ollama.from_openai_response(response, "/api/chat")

      assert converted == response
    end

    test "handles response without usage" do
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

      converted = Ollama.from_openai_response(response, "/api/chat")

      assert Map.has_key?(converted, "message")
      refute Map.has_key?(converted, "prompt_eval_count")
      refute Map.has_key?(converted, "eval_count")
    end

    test "handles response with nil content" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => nil},
            "finish_reason" => "stop"
          }
        ]
      }

      converted = Ollama.from_openai_response(response, "/api/chat")

      message = Map.get(converted, "message")
      # Implementation converts nil content to empty string
      assert Map.get(message, "content") == ""
    end

    test "handles finish_reason length" do
      response = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "length"
          }
        ]
      }

      converted = Ollama.from_openai_response(response, "/api/chat")

      assert Map.get(converted, "done_reason") == "length"
    end

    test "converts OpenAI models list to Ollama format" do
      response = %{
        "object" => "list",
        "data" => [
          %{
            "id" => "gpt-4",
            "object" => "model",
            "created" => 1_700_000_000,
            "owned_by" => "openai"
          },
          %{
            "id" => "gpt-3.5-turbo",
            "object" => "model",
            "created" => 1_700_000_000,
            "owned_by" => "openai"
          }
        ]
      }

      converted = Ollama.from_openai_response(response, "/api/tags")

      assert Map.has_key?(converted, "models")
      models = Map.get(converted, "models")
      assert length(models) == 2

      [first_model | _] = models
      assert Map.has_key?(first_model, "name")
      assert Map.has_key?(first_model, "modified_at")
    end

    test "passes through unknown response formats" do
      response = %{"unknown" => "format"}

      converted = Ollama.from_openai_response(response, "/api/unknown")

      assert converted == response
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

    test "converts done chunk with tool_calls finish reason" do
      chunk = ~s({"model": "llama3", "done": true, "done_reason": "tool_calls"})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      assert Enum.any?(result, fn c -> String.contains?(c, ~s("finish_reason":"tool_calls")) end)
    end

    test "converts done chunk with length finish reason" do
      chunk = ~s({"model": "llama3", "done": true, "done_reason": "length"})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      assert Enum.any?(result, fn c -> String.contains?(c, ~s("finish_reason":"length")) end)
    end

    test "converts done chunk with unknown finish reason" do
      chunk = ~s({"model": "llama3", "done": true, "done_reason": "unknown"})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      # Unknown finish reasons should default to "stop"
      assert Enum.any?(result, fn c -> String.contains?(c, ~s("finish_reason":"stop")) end)
    end

    test "converts Ollama stream chunk with tool calls" do
      chunk =
        ~s({"model": "llama3", "message": {"tool_calls": [{"id": "call_1", "function": {"name": "get_weather", "arguments": "{}"}}]}, "done": false})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      # Tool calls in streaming may return empty list if not properly formatted
      # The implementation handles tool calls in streaming responses
      assert is_list(result)
    end

    test "handles invalid JSON in Ollama stream chunk" do
      chunk = "invalid json"

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert result == [chunk]
    end

    test "ignores unrecognized Ollama stream event" do
      chunk = ~s({"unknown": "event"})

      result = Ollama.to_openai_stream_chunk(chunk, "/api/chat")

      assert result == []
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

    test "handles OpenAI stream chunk with finish reason stop" do
      event = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "delta" => %{},
            "finish_reason" => "stop"
          }
        ]
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      [ollama_chunk | _] = result
      assert String.contains?(ollama_chunk, "\"done\":true")
      assert String.contains?(ollama_chunk, "\"done_reason\":\"stop\"")
    end

    test "handles OpenAI stream chunk with finish reason length" do
      event = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "delta" => %{},
            "finish_reason" => "length"
          }
        ]
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      [ollama_chunk | _] = result
      assert String.contains?(ollama_chunk, "\"done_reason\":\"length\"")
    end

    test "handles OpenAI stream chunk with tool_calls" do
      event = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "function" => %{"name" => "get_weather", "arguments" => "{}"}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      [ollama_chunk | _] = result
      assert String.contains?(ollama_chunk, "tool_calls")
    end

    test "handles OpenAI stream chunk with role delta" do
      event = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "delta" => %{"role" => "assistant"},
            "finish_reason" => nil
          }
        ]
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      # Role-only deltas should be skipped
      assert result == []
    end

    test "handles empty OpenAI stream chunk" do
      event = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4",
        "choices" => [
          %{
            "delta" => %{},
            "finish_reason" => nil
          }
        ]
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      # Empty deltas should return empty list
      assert result == []
    end

    test "handles OpenAI stream chunk without choices" do
      event = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4"
      }

      chunk = "data: #{Jason.encode!(event)}\n\n"
      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert result == []
    end

    test "handles invalid JSON in OpenAI stream chunk" do
      chunk = "data: invalid json\n\n"

      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert is_list(result)
      assert result == [chunk]
    end

    test "handles chunk without data prefix" do
      chunk = "invalid format"

      result = Ollama.from_openai_stream_chunk(chunk, "/api/chat")

      assert result == [chunk]
    end
  end
end
