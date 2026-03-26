defmodule ShhAi.ApiConverterTest do
  use ExUnit.Case, async: true

  alias ShhAi.ApiConverter

  describe "get_converter/1" do
    test "returns OpenAI converter for :openai" do
      assert ApiConverter.get_converter(:openai) == ShhAi.ApiConverter.OpenAI
    end

    test "returns Anthropic converter for :anthropic" do
      assert ApiConverter.get_converter(:anthropic) == ShhAi.ApiConverter.Anthropic
    end

    test "returns Ollama converter for :ollama" do
      assert ApiConverter.get_converter(:ollama) == ShhAi.ApiConverter.Ollama
    end
  end

  describe "get_target_path/3" do
    test "returns same path for OpenAI to OpenAI" do
      path = ApiConverter.get_target_path("/v1/chat/completions", :openai, :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns Anthropic path for OpenAI to Anthropic" do
      path = ApiConverter.get_target_path("/v1/chat/completions", :openai, :anthropic)
      assert path == "/v1/messages"
    end

    test "returns Ollama path for OpenAI to Ollama" do
      path = ApiConverter.get_target_path("/v1/chat/completions", :openai, :ollama)
      assert path == "/api/chat"
    end

    test "returns OpenAI path for Anthropic to OpenAI" do
      path = ApiConverter.get_target_path("/v1/messages", :anthropic, :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns Anthropic path for Anthropic to Anthropic" do
      path = ApiConverter.get_target_path("/v1/messages", :anthropic, :anthropic)
      assert path == "/v1/messages"
    end

    test "returns Ollama path for Anthropic to Ollama" do
      path = ApiConverter.get_target_path("/v1/messages", :anthropic, :ollama)
      assert path == "/api/chat"
    end

    test "returns OpenAI path for Ollama to OpenAI" do
      path = ApiConverter.get_target_path("/api/chat", :ollama, :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns Anthropic path for Ollama to Anthropic" do
      path = ApiConverter.get_target_path("/api/chat", :ollama, :anthropic)
      assert path == "/v1/messages"
    end

    test "returns Ollama path for Ollama to Ollama" do
      path = ApiConverter.get_target_path("/api/chat", :ollama, :ollama)
      assert path == "/api/chat"
    end
  end

  describe "get_path_info/2" do
    test "returns chat type for OpenAI chat completions" do
      {:chat, path} = ApiConverter.get_path_info("/v1/chat/completions", :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns embeddings type for OpenAI embeddings" do
      {:embeddings, path} = ApiConverter.get_path_info("/v1/embeddings", :openai)
      assert path == "/v1/embeddings"
    end

    test "returns models type for OpenAI models" do
      {:models, path} = ApiConverter.get_path_info("/v1/models", :openai)
      assert path == "/v1/models"
    end

    test "returns chat type for Anthropic messages" do
      {:chat, path} = ApiConverter.get_path_info("/v1/messages", :anthropic)
      assert path == "/v1/messages"
    end

    test "returns chat type for Ollama chat" do
      {:chat, path} = ApiConverter.get_path_info("/api/chat", :ollama)
      assert path == "/api/chat"
    end

    test "returns chat type for Ollama generate" do
      {:chat, path} = ApiConverter.get_path_info("/api/generate", :ollama)
      assert path == "/api/generate"
    end

    test "returns embeddings type for Ollama embeddings" do
      {:embeddings, path} = ApiConverter.get_path_info("/api/embeddings", :ollama)
      assert path == "/api/embeddings"
    end

    test "returns models type for Ollama tags" do
      {:models, path} = ApiConverter.get_path_info("/api/tags", :ollama)
      assert path == "/api/tags"
    end
  end

  describe "convert_request/6" do
    test "passes through OpenAI request unchanged for OpenAI to OpenAI" do
      headers = [{"content-type", "application/json"}]
      body = %{"model" => "gpt-4", "messages" => [%{"role" => "user", "content" => "Hello"}]}

      {:ok, {converted_headers, converted_body}, target_path} =
        ApiConverter.convert_request(
          headers,
          body,
          :openai,
          "/v1/chat/completions",
          :openai,
          "/v1/chat/completions"
        )

      assert converted_headers == headers
      assert converted_body == body
      assert target_path == "/v1/chat/completions"
    end

    test "converts OpenAI request to Anthropic format" do
      headers = [{"content-type", "application/json"}]

      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_tokens" => 100
      }

      {:ok, {converted_headers, converted_body}, _target_path} =
        ApiConverter.convert_request(
          headers,
          body,
          :openai,
          "/v1/chat/completions",
          :anthropic,
          "/v1/messages"
        )

      # Anthropic requires system as separate field, not in messages
      assert Map.has_key?(converted_body, "system")
      assert Map.has_key?(converted_body, "messages")
      # Should not have system in messages
      messages = Map.get(converted_body, "messages", [])
      refute Enum.any?(messages, fn m -> m["role"] == "system" end)
      # Should have anthropic-version header
      assert Enum.any?(converted_headers, fn {k, _} -> k == "anthropic-version" end)
    end

    test "converts OpenAI request to Ollama format" do
      headers = [{"content-type", "application/json"}]

      body = %{
        "model" => "llama3",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "stream" => false
      }

      {:ok, {_converted_headers, converted_body}, _target_path} =
        ApiConverter.convert_request(
          headers,
          body,
          :openai,
          "/v1/chat/completions",
          :ollama,
          "/api/chat"
        )

      assert Map.has_key?(converted_body, "model")
      assert Map.has_key?(converted_body, "messages")
      assert Map.has_key?(converted_body, "stream")
    end
  end

  describe "convert_response/5" do
    test "passes through OpenAI response unchanged for OpenAI to OpenAI" do
      response = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello!"}}]
      }

      {:ok, converted} =
        ApiConverter.convert_response(
          response,
          :openai,
          "/v1/chat/completions",
          :openai,
          "/v1/chat/completions"
        )

      assert converted == response
    end

    test "converts Anthropic response to OpenAI format" do
      anthropic_response = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "model" => "claude-3",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      {:ok, converted} =
        ApiConverter.convert_response(
          anthropic_response,
          :openai,
          "/v1/chat/completions",
          :anthropic,
          "/v1/messages"
        )

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "choices")
      assert Map.has_key?(converted, "usage")
      assert length(Map.get(converted, "choices", [])) == 1

      [choice | _] = Map.get(converted, "choices", [])
      assert Map.has_key?(choice, "message")
      message = Map.get(choice, "message")
      assert Map.get(message, "role") == "assistant"
      assert Map.get(message, "content") == "Hello!"
    end

    test "converts Ollama response to OpenAI format" do
      ollama_response = %{
        "model" => "llama3",
        "created_at" => "2024-01-01T00:00:00Z",
        "message" => %{"role" => "assistant", "content" => "Hello!"},
        "done" => true,
        "done_reason" => "stop"
      }

      {:ok, converted} =
        ApiConverter.convert_response(
          ollama_response,
          :openai,
          "/v1/chat/completions",
          :ollama,
          "/api/chat"
        )

      assert Map.has_key?(converted, "id")
      assert Map.has_key?(converted, "choices")
      assert Map.has_key?(converted, "model")

      [choice | _] = Map.get(converted, "choices", [])
      assert Map.has_key?(choice, "message")
      message = Map.get(choice, "message")
      assert Map.get(message, "content") == "Hello!"
    end
  end
end
