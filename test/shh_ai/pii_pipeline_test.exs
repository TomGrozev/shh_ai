defmodule ShhAi.PIIPipelineTest do
  use ExUnit.Case, async: false

  alias ShhAi.{Conversation, PII.Patterns, PIIPipeline}
  alias ShhAi.Conversation.Store
  alias ShhAi.PII.SanitizationResult

  setup do
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()

    # Initialize ETS tables for Conversation.Store
    :ok = Store.ETS.init()

    :ok
  end

  # Helper to create a conversation for tests.
  # Uses a 2-message list so fingerprint_messages returns a hash (Turn 2+ behavior).
  # Sets new? to false so the cache and mapping storage paths are used.
  defp create_conversation do
    # Use a unique message per call to avoid conflicts
    uid = System.unique_integer([:positive])

    messages = [
      %{role: "user", content: "test_msg_#{uid}"},
      %{role: "assistant", content: "reply"}
    ]

    {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
    # Mark as existing (not new) so cache and mapping storage paths are used
    %{conv | new?: false}
  end

  describe "sanitize_openai_request/2" do
    test "returns a %SanitizationResult{} struct" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ],
        "model" => "gpt-4"
      }

      assert {:ok, %SanitizationResult{} = result} =
               PIIPipeline.sanitize_openai_request(body, nil)

      assert is_list(result.sanitized_messages)
      assert is_map(result.mapping)
      assert is_map(result.reverse_index)
      assert is_tuple(result.detection_counts)
      assert is_map(result.pii_info)
    end

    test "sanitizes chat completion request with messages" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ],
        "model" => "gpt-4"
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert length(sanitized) == 1
      assert String.contains?(hd(sanitized)["content"], "<EMAIL_1>")
      assert mapping == %{{:email, 1} => "john@example.com"}
    end

    test "sanitizes request with input key (embeddings format)" do
      body = %{
        "input" => [
          %{"role" => "user", "content" => "Contact: john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert String.contains?(hd(sanitized)["content"], "<EMAIL_1>")
      assert Map.has_key?(mapping, {:email, 1})
    end

    test "sanitizes non-message body (embeddings, moderations)" do
      body = %{
        "input" => "My email is john@example.com",
        "model" => "text-embedding-ada-002"
      }

      {:ok, %SanitizationResult{sanitized_messages: [sanitized], mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert String.contains?(sanitized["input"], "<EMAIL_1>")
      assert Map.has_key?(mapping, {:email, 1})
    end

    test "handles multiple PII types in messages" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: john@example.com, Phone: 555-123-4567"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      content = hd(sanitized)["content"]
      assert String.contains?(content, "<EMAIL_1>")
      assert String.contains?(content, "<PHONE_1>")
      assert Map.has_key?(mapping, {:email, 1})
      assert Map.has_key?(mapping, {:phone, 1})
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

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert length(sanitized) == 4
      assert Map.has_key?(mapping, {:email, 1})
      assert Map.has_key?(mapping, {:phone, 1})
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

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      content = hd(sanitized)["content"]
      assert is_list(content)
      text_part = Enum.find(content, fn part -> Map.has_key?(part, "text") end)
      assert String.contains?(text_part["text"], "<EMAIL_1>")
      assert Map.has_key?(mapping, {:email, 1})
    end

    test "returns empty mapping when PII is disabled" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil, enabled: false)

      assert sanitized == body["messages"]
      assert mapping == %{}
    end

    test "handles empty messages list" do
      body = %{"messages" => [], "model" => "gpt-4"}

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert sanitized == []
      assert mapping == %{}
    end

    test "handles message without content" do
      body = %{
        "messages" => [
          %{"role" => "user"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert length(sanitized) == 1
      assert mapping == %{}
    end

    test "handles body without messages or input" do
      body = %{"model" => "gpt-4", "temperature" => 0.7}

      {:ok, %SanitizationResult{sanitized_messages: [sanitized], mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert sanitized == body
      assert mapping == %{}
    end

    test "stores mapping in conversation when conversation is provided" do
      conversation = create_conversation()

      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{}} =
        PIIPipeline.sanitize_openai_request(body, conversation)

      # Verify mapping was stored in the conversation
      {:ok, stored_mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert Map.has_key?(stored_mapping, {:email, 1})
    end

    test "handles SSN sanitization" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My SSN is 123-45-6789"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      content = hd(sanitized)["content"]
      assert String.contains?(content, "<SSN_1>")
      assert Map.has_key?(mapping, {:ssn, 1})
    end

    test "handles credit card sanitization" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Card: 4111111111111111"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      content = hd(sanitized)["content"]
      assert String.contains?(content, "<FINANCIAL_1>")
      assert Map.has_key?(mapping, {:financial, 1})
    end

    test "reuses placeholders across calls with same conversation" do
      conversation = create_conversation()

      body1 = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      body2 = %{
        "messages" => [
          %{"role" => "user", "content" => "Email again: john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{mapping: mapping1}} =
        PIIPipeline.sanitize_openai_request(body1, conversation)

      {:ok, %SanitizationResult{sanitized_messages: sanitized2}} =
        PIIPipeline.sanitize_openai_request(body2, conversation)

      # Both calls should use the same placeholder for the same email
      assert Map.has_key?(mapping1, {:email, 1})
      assert mapping1[{:email, 1}] == "john@example.com"

      # Second call should reuse EMAIL_1, not create EMAIL_2
      content2 = hd(sanitized2)["content"]
      assert String.contains?(content2, "<EMAIL_1>")
      refute String.contains?(content2, "<EMAIL_2>")
    end

    test "works without conversation (backward compatible)" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{} = result} =
        PIIPipeline.sanitize_openai_request(body, nil)

      # Should still work and return results
      assert String.contains?(hd(result.sanitized_messages)["content"], "<EMAIL_1>")
      assert result.mapping == %{{:email, 1} => "john@example.com"}
      assert is_map(result.reverse_index)
      assert result.pii_info.sanitized_count == 1
    end
  end

  describe "restore_openai_response/2" do
    test "restores PII in response string" do
      response = "Your email <EMAIL_1> has been registered."
      mapping = %{"EMAIL_1" => "john@example.com"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

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

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) == "Hello John!"
    end

    test "restores PII in list response" do
      response = [
        %{"content" => "Hello <PERSON_1>"},
        %{"content" => "Email: <EMAIL_1>"}
      ]

      mapping = %{"PERSON_1" => "John", "EMAIL_1" => "john@example.com"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

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

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

      assert restored["level1"]["level2"]["level3"] == "Value: test@example.com"
    end

    test "handles empty mapping" do
      response = %{"content" => "Hello world"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: %{})

      assert restored == response
    end

    test "handles response without PII" do
      response = %{
        "choices" => [
          %{"message" => %{"content" => "Hello world!"}}
        ]
      }

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, nil,
          mapping: %{"EMAIL_1" => "john@example.com"}
        )

      assert restored == response
    end

    test "restores multiple placeholders in single text" do
      response = "Contact <PERSON_1> at <EMAIL_1> or call <PHONE_1>"

      mapping = %{
        "PERSON_1" => "John",
        "EMAIL_1" => "john@example.com",
        "PHONE_1" => "555-123-4567"
      }

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

      assert restored == "Contact John at john@example.com or call 555-123-4567"
    end

    test "restores using conversation's stored mapping" do
      conversation = create_conversation()

      # Store a mapping in the conversation
      Conversation.add_mapping(
        conversation.conversation_id,
        %{"PERSON_1" => "Jane"},
        %{{"Jane", "person"} => "PERSON_1"}
      )

      response = "Hello <PERSON_1>!"

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, conversation)

      assert restored == "Hello Jane!"
    end

    test "explicit mapping takes priority over conversation" do
      conversation = create_conversation()

      # Store a mapping in the conversation
      Conversation.add_mapping(
        conversation.conversation_id,
        %{"PERSON_1" => "Jane"},
        %{{"Jane", "person"} => "PERSON_1"}
      )

      response = "Hello <PERSON_1>!"
      explicit_mapping = %{"PERSON_1" => "John"}

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, conversation, mapping: explicit_mapping)

      # Should use explicit mapping, not conversation
      assert restored == "Hello John!"
    end

    test "handles non-existent conversation gracefully" do
      # Create a conversation struct but delete it from the store
      conversation = create_conversation()
      Store.ETS.delete(conversation.conversation_id)

      response = "Hello <PERSON_1>!"

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, conversation)

      # Should return unchanged when no mapping found
      assert restored == response
    end

    test "handles Responses API format with delta" do
      response = %{
        "delta" => "Hello <PERSON_1>!",
        "item_id" => "msg_123"
      }

      mapping = %{"PERSON_1" => "John"}

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

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

    test "handles empty chunk" do
      chunk = ""
      mapping = %{"PERSON_1" => "John"}

      {output, state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert output == [""]
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

      {:ok, %SanitizationResult{mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(original_body, nil)

      # Simulate a response with placeholders
      response = %{
        "choices" => [
          %{"message" => %{"content" => "I received your email <EMAIL_1> and phone <PHONE_1>"}}
        ]
      }

      {:ok, restored} = PIIPipeline.restore_openai_response(response, nil, mapping: mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) ==
               "I received your email john@example.com and phone 555-123-4567"
    end

    test "round-trip with conversation" do
      conversation = create_conversation()

      original_body = %{
        "messages" => [
          %{"role" => "user", "content" => "Contact: john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized}} =
        PIIPipeline.sanitize_openai_request(original_body, conversation)

      # Verify sanitization happened
      refute sanitized == original_body["messages"]

      # Restore using conversation
      response = "I'll contact you at <EMAIL_1>"
      {:ok, restored} = PIIPipeline.restore_openai_response(response, conversation)

      assert restored == "I'll contact you at john@example.com"
    end
  end

  describe "sanitize_openai_request with message caching" do
    setup do
      :ets.delete_all_objects(:conversation_message_cache)
      uid = System.unique_integer([:positive])

      messages = [
        %{role: "user", content: "cache_msg_#{uid}"},
        %{role: "assistant", content: "reply"}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      # Mark as existing so cache path is used
      %{conversation: %{conv | new?: false}}
    end

    test "cache miss: sanitizes and caches per-message via Conversation facade", %{
      conversation: conv
    } do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok,
       %SanitizationResult{
         sanitized_messages: sanitized,
         mapping: mapping,
         detection_counts: counts
       }} =
        PIIPipeline.sanitize_openai_request(body, conv)

      content = hd(sanitized)["content"]
      assert String.contains?(content, "<EMAIL_1>")
      assert mapping[{:email, 1}] == "john@example.com"
      assert counts == {1, 0}

      # Verify cache entry was stored via Conversation facade
      hash = Conversation.hash_message(%{role: "user", content: "My email is john@example.com"})

      assert {:ok, {:user_message, ^content, cached_mapping, _cached_ri, {1, 0}}} =
               Conversation.lookup_message(conv.conversation_id, hash)

      assert Map.has_key?(cached_mapping, {:email, 1})
    end

    test "second call with same messages uses cache (cache hit)", %{conversation: conv} do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      # First call: cache miss
      {:ok,
       %SanitizationResult{sanitized_messages: sanitized1, mapping: mapping1, pii_info: pii_info1}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      assert pii_info1.sanitized_count == 1

      # Second call: cache hit — same output
      {:ok,
       %SanitizationResult{sanitized_messages: sanitized2, mapping: mapping2, pii_info: pii_info2}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      assert sanitized2 == sanitized1
      assert mapping2 == mapping1
      # Cache hit means no detection was performed, so sanitized_count is 0
      assert pii_info2.sanitized_count == 0
    end

    test "cache miss adds new mapping entries to conversation", %{conversation: conv} do
      # Turn 1
      body1 = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{mapping: mapping1}} =
        PIIPipeline.sanitize_openai_request(body1, conv)

      assert mapping1[{:email, 1}] == "john@example.com"

      # Turn 2: same message (hit) + new message (miss)
      body2 = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: john@example.com"},
          %{"role" => "user", "content" => "Phone: 555-123-4567"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized2, mapping: mapping2}} =
        PIIPipeline.sanitize_openai_request(body2, conv)

      content1 = Enum.at(sanitized2, 0)["content"]
      content2 = Enum.at(sanitized2, 1)["content"]

      assert String.contains?(content1, "<EMAIL_1>")
      assert String.contains?(content2, "<PHONE_1>")
      assert mapping2[{:email, 1}] == "john@example.com"
      assert mapping2[{:phone, 1}] == "555-123-4567"
    end

    test "without conversation, no caching occurs" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: john@example.com"}
        ]
      }

      # No conversation — should work normally without caching
      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert String.contains?(hd(sanitized)["content"], "<EMAIL_1>")
      assert mapping[{:email, 1}] == "john@example.com"
    end

    # Regression guard: PIIPipeline must read the Reverse Index via
    # `Conversation.get_reverse_index/1` (the facade), not via
    # `Conversation.Store.get_reverse_index/1` directly. Issue #19 closes
    # the seam leak; this test pins the contract so a future refactor
    # cannot silently re-open it.
    #
    # Two assertions together cover the contract:
    #
    #   1. The set of `ShhAi.Conversation.Store` functions reached by
    #      `PIIPipeline.sanitize_openai_request/2` is a subset of the
    #      functions the Conversation facade legitimately delegates to
    #      the Store. Anything else is a new seam leak.
    #
    #   2. The Conversation facade's `get_reverse_index/1` is actually
    #      *on the call path* — proven by mocking it to return a sentinel
    #      and observing that the pipeline's `SanitizationResult` carries
    #      the sentinel. If a future refactor bypassed the facade and
    #      called `Store.get_reverse_index/1` directly, this mock would
    #      have no effect on the pipeline's output.
    test "get_conversation_state reads Reverse Index via Conversation facade, not Store directly",
         %{conversation: conv} do
      # ----- Assertion 1: Store calls are limited to the permitted set -----
      :meck.new(Store, [:passthrough])

      on_exit(fn ->
        # meck auto-unloads when its owning process exits, so the
        # test process may have already torn the mock down by the time
        # on_exit fires. Unload-arity-0 (which tolerates already-unloaded
        # modules) is the safe form.
        :meck.unload()
      end)

      # Clear any history from the describe-block setup (find_or_create
      # itself calls Store.get_conversation/1 or Store.create/1).
      :meck.reset(Store)

      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{}} = PIIPipeline.sanitize_openai_request(body, conv)

      # The set of Store functions the PIIPipeline may legitimately reach
      # (transitively, via the Conversation facade).
      permitted =
        MapSet.new([
          {:get_mapping, 1},
          {:get_reverse_index, 1},
          {:add_mapping, 3},
          {:cache_message, 3},
          {:lookup_message, 2}
        ])

      observed =
        Store
        |> :meck.history()
        # Strip out GenServer internal callbacks — the Store module is a
        # GenServer, so `handle_call/3` / `handle_info/2` etc. are recorded
        # in meck history when the GenServer processes a `:backend` lookup
        # from a delegated call. Those are not Store API calls the pipeline
        # makes; they're bookkeeping of the dispatch GenServer.
        |> Enum.reject(fn {_pid, {_mod, fun, _args}, _result} ->
          fun in [:init, :handle_call, :handle_info, :handle_cast, :terminate, :code_change]
        end)
        |> Enum.map(fn {_pid, {_mod, fun, args}, _result} -> {fun, length(args)} end)
        |> MapSet.new()

      unexpected = MapSet.difference(observed, permitted)

      assert MapSet.size(unexpected) == 0,
             "PIIPipeline must not call Store.* directly (only via the Conversation facade). " <>
               "Unexpected Store calls: #{inspect(MapSet.to_list(unexpected))}"

      # ----- Assertion 2: the facade is on the call path, not bypassed -----
      # Mock `Conversation.get_reverse_index/1` to return a sentinel RI
      # that contains a single, unique entry. If the pipeline routes
      # through the facade, the resulting SanitizationResult will carry
      # that sentinel entry (the pipeline merges the seed RI into the
      # result). If a future refactor bypasses the facade and calls
      # `Store.get_reverse_index/1` directly, this mock is invisible to
      # the pipeline, and the sentinel entry will be absent.
      :meck.unload(Store)

      sentinel_key = {"__SENTINEL_RI_VALUE__", :email}
      sentinel_ri = %{sentinel_key => {:email, 999}}

      :meck.new(Conversation, [:passthrough])
      on_exit(fn -> :meck.unload() end)
      :meck.expect(Conversation, :get_reverse_index, fn _id -> {:ok, sentinel_ri} end)

      {:ok, %SanitizationResult{reverse_index: result_ri}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      assert Map.has_key?(result_ri, sentinel_key),
             "expected SanitizationResult.reverse_index to carry the sentinel " <>
               "(#{inspect(sentinel_key)}) seeded by the mocked Conversation facade — " <>
               "PIIPipeline is likely bypassing the Conversation facade and calling " <>
               "Store.get_reverse_index/1 directly"
    end

    # Regression guard: on a cache hit, the cached text is reused and
    # `PII.Sanitizer.sanitize_messages/2` must NOT be called for that
    # message. The pre-existing test at the top of this describe block
    # ("second call with same messages uses cache (cache hit)") only
    # asserts output equality — a future refactor that re-invokes the
    # Sanitizer on hits would still pass it. This test pins the
    # *behavior* (cache is the source of truth) by overwriting the cache
    # entry with a sentinel and asserting the next call returns the
    # sentinel verbatim — which can only happen if the Sanitizer was
    # bypassed.
    test "cache hit does not call Sanitizer.sanitize_messages/2 again", %{conversation: conv} do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is alice@example.com"}
        ]
      }

      # 1. First call: cache miss — message is sanitized and cached.
      {:ok, %SanitizationResult{sanitized_messages: [s1]}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      assert String.contains?(s1["content"], "<EMAIL_1>"),
             "first call should have sanitized alice@example.com"

      # 2. Overwrite the cache entry for this message hash with a sentinel
      # value. If the next call were to re-sanitize, it would produce
      # something derived from the original PII (e.g. "<EMAIL_1>") —
      # never the literal sentinel string.
      hash = Conversation.hash_message(%{role: "user", content: "My email is alice@example.com"})
      sentinel = "SENTINEL_FROM_CACHE_HIT"

      :ok =
        Conversation.cache_message(
          conv.conversation_id,
          hash,
          {:user_message, sentinel, %{}, %{}, {0, 0}}
        )

      # 3. Second call: must return the sentinel verbatim — proving the
      # cache was the source, not a fresh sanitization pass.
      {:ok, %SanitizationResult{sanitized_messages: [s2]}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      assert s2["content"] == sentinel,
             "expected cache hit to return sentinel #{inspect(sentinel)}; " <>
               "got #{inspect(s2["content"])} — Sanitizer was likely re-invoked on cache hit"
    end

    # Regression guard: the cache also covers assistant_message entries
    # (cached after the streaming response completes). The pre-existing
    # tests in this file only covered the user_message cache hit path.
    test "assistant_message cache hit returns the cached text verbatim", %{conversation: conv} do
      # Pre-populate the cache with an assistant_message entry keyed by
      # a known hash. The cached content is a sentinel string that no
      # real sanitization pass would produce.
      hash =
        Conversation.hash_message(%{
          role: "assistant",
          content: "Hello user, I am your assistant"
        })

      sentinel = "SENTINEL_FROM_ASSISTANT_CACHE_HIT"

      :ok =
        Conversation.cache_message(
          conv.conversation_id,
          hash,
          {:assistant_message, sentinel}
        )

      body = %{
        "messages" => [
          %{
            "role" => "assistant",
            "content" => "Hello user, I am your assistant"
          }
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: [sanitized]}} =
        PIIPipeline.sanitize_openai_request(body, conv)

      # On a cache hit, the cached text is substituted into the message
      # with no fresh sanitization — so the sentinel comes back verbatim.
      assert sanitized["content"] == sentinel,
             "expected assistant_message cache hit to return sentinel " <>
               "#{inspect(sentinel)}; got #{inspect(sanitized["content"])}"
    end
  end

  describe "edge cases" do
    test "handles nil content in message" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => nil}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized, mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert length(sanitized) == 1
      assert mapping == %{}
    end

    test "handles very long text" do
      long_text = String.duplicate("My email is john@example.com. ", 1000)
      body = %{"messages" => [%{"role" => "user", "content" => long_text}]}

      {:ok, %SanitizationResult{mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert Map.has_key?(mapping, {:email, 1})
    end

    test "handles special characters in PII" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: user+special@example.com"}
        ]
      }

      {:ok, %SanitizationResult{mapping: mapping}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert Map.has_key?(mapping, {:email, 1})
      assert mapping[{:email, 1}] == "user+special@example.com"
    end

    test "handles Unicode in content" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "你好，我的邮箱是 john@example.com"}
        ]
      }

      {:ok, %SanitizationResult{sanitized_messages: sanitized}} =
        PIIPipeline.sanitize_openai_request(body, nil)

      assert String.contains?(hd(sanitized)["content"], "<EMAIL_1>")
    end

    test "handles concurrent conversations independently" do
      conversation1 = create_conversation()
      conversation2 = create_conversation()

      body1 = %{"messages" => [%{"role" => "user", "content" => "Email: john@example.com"}]}
      body2 = %{"messages" => [%{"role" => "user", "content" => "Email: jane@example.org"}]}

      {:ok, %SanitizationResult{}} = PIIPipeline.sanitize_openai_request(body1, conversation1)
      {:ok, %SanitizationResult{}} = PIIPipeline.sanitize_openai_request(body2, conversation2)

      {:ok, mapping1} = Conversation.get_mapping(conversation1.conversation_id)
      {:ok, mapping2} = Conversation.get_mapping(conversation2.conversation_id)

      assert mapping1[{:email, 1}] == "john@example.com"
      assert mapping2[{:email, 1}] == "jane@example.org"
    end
  end

  describe "restore_stream_chunk/3 with SSEParser typed events" do
    test "handles data frame with PII restoration" do
      mapping = %{"PERSON_1" => "John"}
      payload = %{"choices" => [%{"delta" => %{"content" => "Hello <PERSON_1>"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"

      {output, _state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert length(output) == 1
      assert hd(output) =~ "John"
      assert hd(output) =~ "data:"
    end

    test "handles :done frame by passing through" do
      mapping = %{"PERSON_1" => "John"}
      chunk = "data: [DONE]\n\n"

      {output, _state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # :done frames have no text to restore, should pass through
      assert is_list(output)
      assert length(output) == 1
      assert hd(output) == "data: [DONE]\n\n"
    end

    test "handles event-typed frame with PII restoration" do
      mapping = %{"PERSON_1" => "John"}
      payload = %{"choices" => [%{"delta" => %{"content" => "Hi <PERSON_1>"}}]}
      chunk = "event: content_block_delta\ndata: #{Jason.encode!(payload)}\n\n"

      {output, _state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      assert length(output) == 1
      assert hd(output) =~ "Hi John"
      assert hd(output) =~ "event: content_block_delta"
    end

    test "preserves split-placeholder buffering behavior" do
      mapping = %{"PERSON_1" => "John"}

      # <PERSON_1> split across two chunks
      chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello <PERS\"}}]}\n\n"
      {output1, state1} = PIIPipeline.restore_stream_chunk(chunk1, %{}, mapping)

      chunk2 = "data: {\"choices\":[{\"delta\":{\"content\":\"ON_1>!\"}}]}\n\n"
      {output2, _state2} = PIIPipeline.restore_stream_chunk(chunk2, state1, mapping)

      # Combined output should have restored PII
      all_output = output1 ++ output2
      combined_text = Enum.join(all_output)
      assert combined_text =~ "John"
    end

    # Regression guard: restore_stream_chunk/3 must handle Anthropic
    # `event:` + `data:` frames, not just OpenAI `data:` frames. Anthropic
    # sends `event: content_block_delta\ndata: {...}\n\n` and the pipeline
    # is expected to handle the frame structure (parse it, route to the
    # typed-event path) even when the current PII extractor only handles
    # OpenAI text shapes.
    test "handles Anthropic event: + data: frame structure" do
      mapping = %{"PERSON_1" => "John"}

      payload = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hi <PERSON_1>"}
      }

      chunk =
        "event: content_block_delta\n" <>
          "data: #{Jason.encode!(payload)}\n\n"

      {output, _state} = PIIPipeline.restore_stream_chunk(chunk, %{}, mapping)

      # The frame parses cleanly through the typed-events path; the
      # output is a list (the wire format is preserved).
      assert is_list(output)
      assert length(output) == 1
      [out_chunk] = output
      # The event: line is preserved on the wire.
      assert out_chunk =~ "event: content_block_delta"
    end
  end

  describe "extract_content_from_openai_chunks/1" do
    test "extracts text content from OpenAI streaming chunks" do
      chunks = [
        ~s(data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n),
        ~s(data: {"choices": [{"delta": {"content": " world"}}]}\n\n)
      ]

      assert PIIPipeline.extract_content_from_openai_chunks(chunks) == "Hello world"
    end

    test "extracts from message key (non-streaming)" do
      chunks = [~s(data: {"choices": [{"message": {"content": "Hi"}}]}\n\n)]
      assert PIIPipeline.extract_content_from_openai_chunks(chunks) == "Hi"
    end

    test "returns empty string for chunks without choices" do
      chunks = [~s(data: {"id": "1"}\n\n)]
      assert PIIPipeline.extract_content_from_openai_chunks(chunks) == ""
    end

    test "returns empty string for non-list input" do
      assert PIIPipeline.extract_content_from_openai_chunks("garbage") == ""
    end

    test "returns empty string for empty list" do
      assert PIIPipeline.extract_content_from_openai_chunks([]) == ""
    end

    test "skips chunks with nil content" do
      chunks = [
        ~s(data: {"choices": [{"delta": {"content": "A"}}]}\n\n),
        ~s(data: {"choices": [{"delta": {}}]}\n\n),
        ~s(data: {"choices": [{"delta": {"content": "B"}}]}\n\n)
      ]

      assert PIIPipeline.extract_content_from_openai_chunks(chunks) == "AB"
    end

    test "handles chunks that are complete SSE frames" do
      payload = %{"choices" => [%{"delta" => %{"content" => "test"}}]}
      chunk = "data: #{Jason.encode!(payload)}\n\n"
      assert PIIPipeline.extract_content_from_openai_chunks([chunk]) == "test"
    end
  end

  describe "extract_assistant_message/1" do
    test "extracts message from choices with message key" do
      response = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}]}

      assert PIIPipeline.extract_assistant_message(response) == %{
               "role" => "assistant",
               "content" => "Hello"
             }
    end

    test "extracts delta from choices with delta key" do
      response = %{"choices" => [%{"delta" => %{"content" => "streaming"}}]}
      assert PIIPipeline.extract_assistant_message(response) == %{"content" => "streaming"}
    end

    test "returns empty assistant message for unrecognized format" do
      assert PIIPipeline.extract_assistant_message(%{}) == %{
               "role" => "assistant",
               "content" => ""
             }
    end

    test "returns empty assistant message for non-map input" do
      assert PIIPipeline.extract_assistant_message("garbage") == %{
               "role" => "assistant",
               "content" => ""
             }
    end
  end
end
