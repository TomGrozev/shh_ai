defmodule ShhAi.PIIPipelineTest do
  use ExUnit.Case, async: true

  alias ShhAi.{PIIPipeline, PII.Patterns, SessionStore}

  setup do
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()
    :ok
  end

  describe "sanitize_openai_request/2" do
    test "sanitizes chat completion request with messages" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ],
        "model" => "gpt-4"
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert sanitized["model"] == "gpt-4"
      assert length(sanitized["messages"]) == 1
      assert String.contains?(hd(sanitized["messages"])["content"], "<EMAIL_1>")
      assert mapping == %{"EMAIL_1" => "john@example.com"}
    end

    test "sanitizes request with input key (embeddings format)" do
      body = %{
        "input" => [
          %{"role" => "user", "content" => "Contact: john@example.com"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert String.contains?(hd(sanitized["input"])["content"], "<EMAIL_1>")
      assert Map.has_key?(mapping, "EMAIL_1")
    end

    test "sanitizes non-message body (embeddings, moderations)" do
      body = %{
        "input" => "My email is john@example.com",
        "model" => "text-embedding-ada-002"
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert String.contains?(sanitized["input"], "<EMAIL_1>")
      assert Map.has_key?(mapping, "EMAIL_1")
    end

    test "handles multiple PII types in messages" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: john@example.com, Phone: 555-123-4567"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      content = hd(sanitized["messages"])["content"]
      assert String.contains?(content, "<EMAIL_1>")
      assert String.contains?(content, "<PHONE_1>")
      assert Map.has_key?(mapping, "EMAIL_1")
      assert Map.has_key?(mapping, "PHONE_1")
    end

    test "handles multiple messages with PII" do
      body = %{
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "My email is john@example.com"},
          %{"role" => "assistant", "content" => "Hello!"},
          %{"role" => "user", "content" => "Call me at 555-123-4567"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert length(sanitized["messages"]) == 4
      assert Map.has_key?(mapping, "EMAIL_1")
      assert Map.has_key?(mapping, "PHONE_1")
    end

    test "handles multi-part content in messages" do
      body = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "My email is john@example.com"},
              %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/image.png"}}
            ]
          }
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      content = hd(sanitized["messages"])["content"]
      assert is_list(content)
      text_part = Enum.find(content, fn part -> Map.has_key?(part, "text") end)
      assert String.contains?(text_part["text"], "<EMAIL_1>")
      assert Map.has_key?(mapping, "EMAIL_1")
    end

    test "returns empty mapping when PII is disabled" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} =
        PIIPipeline.sanitize_openai_request(body, enabled: false)

      assert sanitized["messages"] == body["messages"]
      assert mapping == %{}
    end

    test "handles empty messages list" do
      body = %{"messages" => [], "model" => "gpt-4"}

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert sanitized["messages"] == []
      assert mapping == %{}
    end

    test "handles message without content" do
      body = %{
        "messages" => [
          %{"role" => "user"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert length(sanitized["messages"]) == 1
      assert mapping == %{}
    end

    test "handles body without messages or input" do
      body = %{"model" => "gpt-4", "temperature" => 0.7}

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert sanitized == body
      assert mapping == %{}
    end

    test "stores mapping when session_id is provided" do
      # Create a session first
      {:ok, session_id} = SessionStore.create()

      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, _sanitized, _mapping, _pii_info} =
        PIIPipeline.sanitize_openai_request(body, session_id: session_id)

      # Verify mapping was stored
      {:ok, stored_mapping} = SessionStore.get(session_id)
      assert Map.has_key?(stored_mapping, "EMAIL_1")

      # Cleanup
      SessionStore.delete(session_id)
    end

    test "handles SSN sanitization" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My SSN is 123-45-6789"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      content = hd(sanitized["messages"])["content"]
      assert String.contains?(content, "<SSN_1>")
      assert Map.has_key?(mapping, "SSN_1")
    end

    test "handles credit card sanitization" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Card: 4111111111111111"}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      content = hd(sanitized["messages"])["content"]
      assert String.contains?(content, "<FINANCIAL_1>")
      assert Map.has_key?(mapping, "FINANCIAL_1")
    end
  end

  describe "restore_openai_response/2" do
    test "restores PII in response string" do
      response = "Your email <EMAIL_1> has been registered."
      mapping = %{"EMAIL_1" => "john@example.com"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert restored == "Your email john@example.com has been registered."
    end

    test "restores PII in nested map response" do
      response = %{
        "choices" => [
          %{
            "message" => %{
              "content" => "Hello <PERSON_1>!"
            }
          }
        ]
      }

      mapping = %{"PERSON_1" => "John"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) == "Hello John!"
    end

    test "restores PII in list response" do
      response = [
        %{"content" => "Hello <PERSON_1>"},
        %{"content" => "Email: <EMAIL_1>"}
      ]

      mapping = %{"PERSON_1" => "John", "EMAIL_1" => "john@example.com"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert hd(restored)["content"] == "Hello John"
      assert hd(tl(restored))["content"] == "Email: john@example.com"
    end

    test "restores PII in deeply nested response" do
      response = %{
        "level1" => %{
          "level2" => %{
            "level3" => "Value: <EMAIL_1>"
          }
        }
      }

      mapping = %{"EMAIL_1" => "test@example.com"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert restored["level1"]["level2"]["level3"] == "Value: test@example.com"
    end

    test "handles empty mapping" do
      response = %{"content" => "Hello world"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: %{})

      assert restored == response
    end

    test "handles response without PII" do
      response = %{
        "choices" => [
          %{"message" => %{"content" => "Hello world!"}}
        ]
      }

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, mapping: %{"EMAIL_1" => "john@example.com"})

      assert restored == response
    end

    test "restores multiple placeholders in single text" do
      response = "Contact <PERSON_1> at <EMAIL_1> or call <PHONE_1>"

      mapping = %{
        "PERSON_1" => "John",
        "EMAIL_1" => "john@example.com",
        "PHONE_1" => "555-123-4567"
      }

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert restored == "Contact John at john@example.com or call 555-123-4567"
    end

    test "retrieves mapping from session when session_id provided" do
      {:ok, session_id} = SessionStore.create()
      SessionStore.put(session_id, %{"PERSON_1" => "Jane"})

      response = "Hello <PERSON_1>!"

      {:ok, restored} = PIIPipeline.restore_openai_response(response, session_id: session_id)

      assert restored == "Hello Jane!"

      SessionStore.delete(session_id)
    end

    test "prefers explicit mapping over session_id" do
      {:ok, session_id} = SessionStore.create()
      SessionStore.put(session_id, %{"PERSON_1" => "Jane"})

      response = "Hello <PERSON_1>!"
      explicit_mapping = %{"PERSON_1" => "John"}

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response,
          mapping: explicit_mapping,
          session_id: session_id
        )

      # Should use explicit mapping, not session
      assert restored == "Hello John!"

      SessionStore.delete(session_id)
    end

    test "handles non-existent session gracefully" do
      response = "Hello <PERSON_1>!"

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, session_id: "non-existent-session")

      # Should return unchanged when no mapping found
      assert restored == response
    end

    test "handles Responses API format with delta" do
      response = %{
        "delta" => "Hello <PERSON_1>!",
        "item_id" => "msg_123"
      }

      mapping = %{"PERSON_1" => "John"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert restored["delta"] == "Hello John!"
      assert restored["item_id"] == "msg_123"
    end
  end

  describe "restore_stream_chunk/3" do
    test "restores PII in SSE chunk with complete placeholder" do
      chunk = "data: {\"delta\":\"Hello <PERSON_1>!\"}\n\n"
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert length(output) == 1
      assert hd(output) == "data: {\"delta\":\"Hello John!\"}\n\n"
      assert state == %{buffer: ""}
    end

    test "handles split placeholder across chunks" do
      mapping = %{"PERSON_1" => "John"}

      # First chunk with partial placeholder - the implementation restores complete text
      # and buffers only the partial placeholder part
      chunk1 = "data: {\"delta\":\"Hello <PERS\"}\n\n"
      {output1, state1} = PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)

      # Should output the complete text part and buffer the partial
      assert length(output1) == 1
      assert hd(output1) == "data: {\"delta\":\"Hello \"}\n\n"
      assert Map.has_key?(state1, :buffer)

      # Second chunk completes the placeholder
      chunk2 = "data: {\"delta\":\"ON_1>!\"}\n\n"
      {output2, state2} = PIIPipeline.restore_stream_chunk(chunk2, state1, mapping)

      # Should output the restored content with buffered part
      assert length(output2) == 1
      assert hd(output2) == "data: {\"delta\":\"John!\"}\n\n"
      assert state2 == %{buffer: ""}
    end

    test "handles multiple placeholders in single chunk" do
      chunk = "data: {\"delta\":\"Contact <PERSON_1> at <EMAIL_1>\"}\n\n"
      mapping = %{"PERSON_1" => "John", "EMAIL_1" => "john@example.com"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert length(output) == 1
      assert hd(output) == "data: {\"delta\":\"Contact John at john@example.com\"}\n\n"
      assert state == %{buffer: ""}
    end

    test "passes through chunk unchanged when mapping is empty" do
      chunk = "data: {\"delta\":\"Hello world!\"}\n\n"

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, %{})

      assert output == [chunk]
      assert state == %{}
    end

    test "handles [DONE] message" do
      chunk = "data: [DONE]\n\n"

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, %{"PERSON_1" => "John"})

      assert output == [chunk]
      assert state == %{buffer: ""}
    end

    test "handles chunk with event type" do
      chunk = "event: message\ndata: {\"delta\":\"Hello <PERSON_1>\"}\n\n"
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert length(output) == 1
      assert hd(output) == "event: message\ndata: {\"delta\":\"Hello John\"}\n\n"
      assert state == %{buffer: ""}
    end

    test "preserves metadata in chunk" do
      chunk =
        "data: {\"delta\":\"Hi <PERSON_1>\",\"item_id\":\"msg_123\",\"sequence_number\":1}\n\n"

      mapping = %{"PERSON_1" => "John"}

      {output, _state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # Parse the output to verify metadata is preserved
      assert hd(output) =~ "\"item_id\":\"msg_123\""
      assert hd(output) =~ "\"sequence_number\":1"
      assert hd(output) =~ "\"delta\":\"Hi John\""
    end

    test "handles Chat Completions API format with choices" do
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello <PERSON_1>\"}}]}\n\n"
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert length(output) == 1
      assert hd(output) == "data: {\"choices\":[{\"delta\":{\"content\":\"Hello John\"}}]}\n\n"
      assert state == %{buffer: ""}
    end

    test "handles chunk without delta (metadata only)" do
      chunk = "data: {\"item_id\":\"msg_123\",\"type\":\"message\"}\n\n"
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # Should pass through unchanged since there's no text to restore
      assert output == [chunk]
      assert state == %{buffer: ""}
    end

    test "handles malformed JSON gracefully" do
      chunk = "data: {invalid json}\n\n"
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # Should pass through unchanged
      assert output == [chunk]
      assert state == %{buffer: ""}
    end

    test "handles empty chunk" do
      chunk = ""
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert output == [""]
      assert state == %{buffer: ""}
    end

    test "handles chunk with no data line" do
      chunk = "event: ping\n\n"
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # Should pass through unchanged
      assert output == [chunk]
      assert state == %{buffer: ""}
    end

    test "handles three-part split placeholder" do
      mapping = %{"PERSON_1" => "John"}

      # First chunk: "Hello <P"
      # The implementation outputs "Hello " and buffers "<P"
      chunk1 = "data: {\"delta\":\"Hello <P\"}\n\n"
      {output1, state1} = PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)
      # Should output the complete text part ("Hello ") and buffer the partial
      assert length(output1) == 1
      assert hd(output1) == "data: {\"delta\":\"Hello \"}\n\n"

      # Second chunk: "ERSON_"
      # This gets added to buffer which now becomes "PERSION_"
      chunk2 = "data: {\"delta\":\"ERSON_\"}\n\n"
      {output2, state2} = PIIPipeline.restore_stream_chunk(chunk2, state1, mapping)
      # Still buffering - no complete placeholder yet, still partial
      # The buffer from chunk1 is "<P", adding "ERSON_" makes the delta content still partial
      assert length(output2) == 1
      # The delta content is empty since we're still buffering
      assert hd(output2) == "data: {\"delta\":\"\"}\n\n"

      # Third chunk: "1>!"
      # Now completes the placeholder
      chunk3 = "data: {\"delta\":\"1>!\"}\n\n"
      {output3, state3} = PIIPipeline.restore_stream_chunk(chunk3, state2, mapping)

      # Now we should have the complete restored content
      assert length(output3) == 1
      assert hd(output3) == "data: {\"delta\":\"John!\"}\n\n"
      assert state3 == %{buffer: ""}
    end

    test "accumulates text correctly across chunks" do
      mapping = %{"EMAIL_1" => "john@example.com"}

      # First chunk with complete text
      chunk1 = "data: {\"delta\":\"Hello \"}\n\n"
      {output1, state1} = PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)
      assert hd(output1) == "data: {\"delta\":\"Hello \"}\n\n"

      # Second chunk with placeholder
      chunk2 = "data: {\"delta\":\"Email: <EMAIL_1>\"}\n\n"
      {output2, state2} = PIIPipeline.restore_stream_chunk(chunk2, state1, mapping)
      assert hd(output2) == "data: {\"delta\":\"Email: john@example.com\"}\n\n"
      assert state2 == %{buffer: ""}
    end

    test "handles partial placeholder at end of chunk" do
      mapping = %{"PERSON_1" => "John"}

      # Chunk ends with "<" which could start a placeholder
      # The implementation outputs "Hello " and buffers the "<"
      chunk = "data: {\"delta\":\"Hello <\"}\n\n"
      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # Should output the complete text part and buffer the potential partial
      assert length(output) == 1
      assert hd(output) == "data: {\"delta\":\"Hello \"}\n\n"
      assert Map.has_key?(state, :buffer)
    end

    test "handles non-placeholder angle bracket" do
      mapping = %{"PERSON_1" => "John"}

      # Chunk has "<" followed by something that's not a placeholder
      chunk = "data: {\"delta\":\"5 < 10\"}\n\n"
      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # Should output as-is since it's not a placeholder
      assert length(output) == 1
      assert hd(output) == "data: {\"delta\":\"5 < 10\"}\n\n"
      assert state == %{buffer: ""}
    end
  end

  describe "round-trip sanitization and restoration" do
    test "full round-trip preserves original content" do
      original_body = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => "My email is john@example.com and phone is 555-123-4567"
          }
        ]
      }

      {:ok, _sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(original_body)

      # Simulate a response with placeholders
      response = %{
        "choices" => [
          %{"message" => %{"content" => "I received your email <EMAIL_1> and phone <PHONE_1>"}}
        ]
      }

      {:ok, restored} = PIIPipeline.restore_openai_response(response, mapping: mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) ==
               "I received your email john@example.com and phone 555-123-4567"
    end

    test "round-trip with session storage" do
      {:ok, session_id} = SessionStore.create()

      original_body = %{
        "messages" => [
          %{"role" => "user", "content" => "Contact: john@example.com"}
        ]
      }

      {:ok, sanitized, _mapping, _pii_info} =
        PIIPipeline.sanitize_openai_request(original_body, session_id: session_id)

      # Verify sanitization happened
      refute sanitized["messages"] == original_body["messages"]

      # Restore using session
      response = "I'll contact you at <EMAIL_1>"
      {:ok, restored} = PIIPipeline.restore_openai_response(response, session_id: session_id)

      assert restored == "I'll contact you at john@example.com"

      SessionStore.delete(session_id)
    end
  end

  describe "edge cases" do
    test "handles nil content in message" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => nil}
        ]
      }

      {:ok, sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)
      assert length(sanitized["messages"]) == 1
      assert mapping == %{}
    end

    test "handles very long text" do
      long_text = String.duplicate("My email is john@example.com. ", 1000)
      body = %{"messages" => [%{"role" => "user", "content" => long_text}]}

      {:ok, _sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert Map.has_key?(mapping, "EMAIL_1")
    end

    test "handles special characters in PII" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: user+special@example.com"}
        ]
      }

      {:ok, _sanitized, mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert Map.has_key?(mapping, "EMAIL_1")
      assert mapping["EMAIL_1"] == "user+special@example.com"
    end

    test "handles Unicode in content" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "你好，我的邮箱是 john@example.com"}
        ]
      }

      {:ok, sanitized, _mapping, _pii_info} = PIIPipeline.sanitize_openai_request(body)

      assert String.contains?(sanitized["messages"] |> hd() |> Map.get("content"), "<EMAIL_1>")
    end

    test "handles concurrent sessions independently" do
      {:ok, session1} = SessionStore.create()
      {:ok, session2} = SessionStore.create()

      body1 = %{"messages" => [%{"role" => "user", "content" => "Email: john@example.com"}]}
      body2 = %{"messages" => [%{"role" => "user", "content" => "Email: jane@example.org"}]}

      {:ok, _, _, _} = PIIPipeline.sanitize_openai_request(body1, session_id: session1)
      {:ok, _, _, _} = PIIPipeline.sanitize_openai_request(body2, session_id: session2)

      {:ok, mapping1} = SessionStore.get(session1)
      {:ok, mapping2} = SessionStore.get(session2)

      assert mapping1["EMAIL_1"] == "john@example.com"
      assert mapping2["EMAIL_1"] == "jane@example.org"

      SessionStore.delete(session1)
      SessionStore.delete(session2)
    end
  end
end
