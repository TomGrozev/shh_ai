defmodule ShhAi.ApiConverter.OpenAITest do
  use ExUnit.Case, async: true

  alias ShhAi.ApiConverter.OpenAI

  describe "to_openai_request/3" do
    test "passes through headers and body unchanged" do
      headers = [{"content-type", "application/json"}]
      body = %{"model" => "gpt-4", "messages" => [%{"role" => "user", "content" => "Hello"}]}

      {result_headers, result_body} =
        OpenAI.to_openai_request(headers, body, "/v1/chat/completions")

      assert result_headers == headers
      assert result_body == body
    end

    test "passes through any path" do
      headers = []
      body = %{}

      {result_headers, result_body} = OpenAI.to_openai_request(headers, body, "/v1/models")

      assert result_headers == headers
      assert result_body == body
    end
  end

  describe "from_openai_request/3" do
    test "passes through headers and body unchanged" do
      headers = [{"authorization", "Bearer test-key"}]
      body = %{"model" => "gpt-4", "messages" => [%{"role" => "user", "content" => "Hello"}]}

      {result_headers, result_body} =
        OpenAI.from_openai_request(headers, body, "/v1/chat/completions")

      assert result_headers == headers
      assert result_body == body
    end
  end

  describe "to_openai_response/2" do
    test "passes through map response unchanged" do
      response = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello!"}}]
      }

      result = OpenAI.to_openai_response(response, "/v1/chat/completions")

      assert result == response
    end

    test "passes through string response unchanged" do
      response = "data: {\"choices\":[]}\n\n"

      result = OpenAI.to_openai_response(response, "/v1/chat/completions")

      assert result == response
    end
  end

  describe "from_openai_response/2" do
    test "passes through map response unchanged" do
      response = %{
        "id" => "chatcmpl-123",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello!"}}]
      }

      result = OpenAI.from_openai_response(response, "/v1/chat/completions")

      assert result == response
    end

    test "passes through string response unchanged" do
      response = "{\"id\": \"test\"}"

      result = OpenAI.from_openai_response(response, "/v1/chat/completions")

      assert result == response
    end
  end

  describe "to_openai_stream_chunk/2" do
    test "returns data chunk in a list" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"

      result = OpenAI.to_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
      assert hd(result) =~ "data:"
      assert hd(result) =~ "\n\n"
      assert hd(result) =~ "\"choices\""
      assert hd(result) =~ "\"Hello\""
    end

    test "handles [DONE] chunk" do
      chunk = "data: [DONE]\n\n"

      result = OpenAI.to_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert {:done, done_chunks} = result
      assert length(done_chunks) == 1
      assert hd(done_chunks) == "data: [DONE]\n\n"
    end
  end

  describe "from_openai_stream_chunk/2" do
    test "returns data chunk in a list" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"

      result = OpenAI.from_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
      assert hd(result) =~ "data:"
      assert hd(result) =~ "\n\n"
    end
  end

  describe "to_openai_stream_chunk/2 with SSEParser typed events" do
    test "parses data frame via SSEParser and returns reconstructed chunk" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"

      result = OpenAI.to_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
      # Verify the output is a valid SSE data frame
      assert hd(result) =~ "data:"
      assert hd(result) =~ "\n\n"
    end

    test "translates :done event into [DONE] payload byte" do
      chunk = "data: [DONE]\n\n"

      result = OpenAI.to_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert {:done, done_chunks} = result
      assert length(done_chunks) == 1
      assert hd(done_chunks) == "data: [DONE]\n\n"
    end

    test "returns error for malformed chunk" do
      chunk = "data: {invalid json}\n\n"

      result = OpenAI.to_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert {:error, :invalid_format} = result
    end
  end

  describe "from_openai_stream_chunk/2 with SSEParser typed events" do
    test "parses data frame via SSEParser and returns reconstructed chunk" do
      payload = %{"choices" => [%{"delta" => %{"content" => "World"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"

      result = OpenAI.from_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
    end

    test "translates :done event into [DONE] payload byte" do
      chunk = "data: [DONE]\n\n"

      result = OpenAI.from_openai_stream_chunk(chunk, "/v1/chat/completions")

      assert {:done, done_chunks} = result
      assert hd(done_chunks) == "data: [DONE]\n\n"
    end
  end

  describe "to_openai_path/1" do
    test "returns path unchanged for chat completions" do
      assert OpenAI.to_openai_path("/v1/chat/completions") == "/v1/chat/completions"
    end

    test "returns path unchanged for models" do
      assert OpenAI.to_openai_path("/v1/models") == "/v1/models"
    end

    test "returns path unchanged for embeddings" do
      assert OpenAI.to_openai_path("/v1/embeddings") == "/v1/embeddings"
    end

    test "returns path unchanged for any path" do
      assert OpenAI.to_openai_path("/v1/any/endpoint") == "/v1/any/endpoint"
    end
  end

  describe "from_openai_path/1" do
    test "returns path unchanged for chat completions" do
      assert OpenAI.from_openai_path("/v1/chat/completions") == "/v1/chat/completions"
    end

    test "returns path unchanged for models" do
      assert OpenAI.from_openai_path("/v1/models") == "/v1/models"
    end

    test "returns path unchanged for embeddings" do
      assert OpenAI.from_openai_path("/v1/embeddings") == "/v1/embeddings"
    end

    test "returns path unchanged for any path" do
      assert OpenAI.from_openai_path("/v1/any/endpoint") == "/v1/any/endpoint"
    end
  end

  describe "get_path_type/1" do
    test "returns chat type for chat completions" do
      assert OpenAI.get_path_type("/v1/chat/completions") == {:chat, "/v1/chat/completions"}
    end

    test "returns chat type for completions" do
      assert OpenAI.get_path_type("/v1/completions") == {:chat, "/v1/completions"}
    end

    test "returns embeddings type for embeddings" do
      assert OpenAI.get_path_type("/v1/embeddings") == {:embeddings, "/v1/embeddings"}
    end

    test "returns models type for models" do
      assert OpenAI.get_path_type("/v1/models") == {:models, "/v1/models"}
    end

    test "returns other type for unknown paths" do
      assert OpenAI.get_path_type("/v1/unknown") == {:other, "/v1/unknown"}
      assert OpenAI.get_path_type("/v1/files") == {:other, "/v1/files"}
      assert OpenAI.get_path_type("/custom/path") == {:other, "/custom/path"}
    end
  end
end
