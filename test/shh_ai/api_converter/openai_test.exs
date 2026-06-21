defmodule ShhAi.ApiConverter.OpenAITest do
  use ExUnit.Case, async: true

  alias ShhAi.ApiConverter.OpenAI
  alias ShhAi.ProviderClient.SSEParser

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

  describe "to_openai_stream_events/2" do
    test "parses a data frame into a single %SSEParser{} event" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"

      result = OpenAI.to_openai_stream_events(chunk, "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
      assert [%SSEParser{type: :data, payload: ^payload}] = result
    end

    test "returns a single :done event for the [DONE] frame" do
      chunk = "data: [DONE]\n\n"

      assert [%SSEParser{type: :done, event_name: nil, payload: nil}] =
               OpenAI.to_openai_stream_events(chunk, "/v1/chat/completions")
    end

    test "returns {:error, :invalid_format} for malformed JSON" do
      chunk = "data: {invalid json}\n\n"

      assert {:error, :invalid_format} =
               OpenAI.to_openai_stream_events(chunk, "/v1/chat/completions")
    end

    test "returns {:error, :invalid_format} for a partial frame (no complete SSE frame in chunk)" do
      # Half of an SSE frame — no `\n\n` terminator, so SSEParser.parse
      # signals `:partial`. The OpenAI converter maps any `{:error, _}`
      # to `:invalid_format` (the historical OpenAI behaviour).
      assert {:error, :invalid_format} =
               OpenAI.to_openai_stream_events("data: {\"choices\"", "/v1/chat/completions")
    end
  end

  describe "from_openai_stream_events/2" do
    test "serialises a data event to a single SSE data frame" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      event = %SSEParser{type: :data, payload: payload}

      result = OpenAI.from_openai_stream_events([event], "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
      [chunk] = result
      assert chunk =~ "data:"
      assert chunk =~ "\n\n"
      assert chunk =~ "Hello"
    end

    test "translates :done event into [DONE] payload byte, tagged with :done" do
      event = %SSEParser{type: :done, event_name: nil, payload: nil}

      assert {:done, ["data: [DONE]\n\n"]} =
               OpenAI.from_openai_stream_events([event], "/v1/chat/completions")
    end

    test "treats :event-typed frames the same as :data (OpenAI has no `event:` wire lines)" do
      payload = %{"choices" => [%{"delta" => %{"content" => "x"}}]}
      event = %SSEParser{type: :event, event_name: "content_block_delta", payload: payload}

      result = OpenAI.from_openai_stream_events([event], "/v1/chat/completions")

      assert is_list(result)
      assert length(result) == 1
      [chunk] = result
      assert chunk =~ "data:"
      refute chunk =~ "event:"
    end

    test "returns {:error, :invalid_format} for an empty event list" do
      assert {:error, :invalid_format} =
               OpenAI.from_openai_stream_events([], "/v1/chat/completions")
    end

    test "round-trip: to_openai_stream_events + from_openai_stream_events produces byte-identical output" do
      # Regression guard: the events path must produce the same
      # source-format bytes as a direct SSE round-trip.
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      original_chunk = "data: #{Jason.encode!(payload)}\n\n"

      events = OpenAI.to_openai_stream_events(original_chunk, "/v1/chat/completions")
      [chunk] = OpenAI.from_openai_stream_events(events, "/v1/chat/completions")

      assert chunk == original_chunk
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
