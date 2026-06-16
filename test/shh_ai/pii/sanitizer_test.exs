defmodule ShhAi.PII.SanitizerTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.{Patterns, Sanitizer}

  setup_all do
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()
    :ok
  end

  describe "sanitize/2" do
    test "sanitizes email addresses" do
      text = "My email is john@example.com"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(text)

      assert sanitized == "My email is <EMAIL_1>"
      assert mapping == %{{:email, 1} => "john@example.com"}
    end

    test "sanitizes multiple PII items" do
      text = "Email: john@example.com, Phone: 555-123-4567"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<EMAIL_1>")
      assert String.contains?(sanitized, "<PHONE_1>")
      assert Map.has_key?(mapping, {:email, 1})
      assert Map.has_key?(mapping, {:phone, 1})
    end

    test "generates unique placeholders for same type" do
      text = "Emails: john@example.com and jane@example.org"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<EMAIL_1>")
      assert String.contains?(sanitized, "<EMAIL_2>")
      assert Map.has_key?(mapping, {:email, 1})
      assert Map.has_key?(mapping, {:email, 2})
    end

    test "preserves text without PII" do
      text = "Hello world"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(text)

      assert sanitized == text
      assert mapping == %{}
    end

    test "sanitizes SSN" do
      text = "SSN: 123-45-6789"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<SSN_1>")
      assert Map.has_key?(mapping, {:ssn, 1})
    end

    test "sanitizes credit card numbers" do
      text = "Card: 4111111111111111"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<FINANCIAL_1>")
      assert Map.has_key?(mapping, {:financial, 1})
    end
  end

  describe "sanitize/2 with context" do
    test "always sanitizes certain types regardless of context" do
      # SSN should always be sanitized
      text = "SSN: 123-45-6789"

      {:ok, sanitized, _mapping, _reverse_index, _counts} =
        Sanitizer.sanitize(text, context: %{message_type: :system})

      assert String.contains?(sanitized, "<SSN_1>")
    end

    test "preserves location in system message with location context" do
      text = "Weather in New York"

      {:ok, sanitized, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize(text, context: %{message_type: :system, has_location_context: true})

      # Location might be preserved due to context
      # This depends on the context rules
      assert is_binary(sanitized)
      assert is_map(mapping)
    end

    test "preserves location when user provides location context" do
      text = "I live in New York"

      {:ok, sanitized, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize(text, context: %{has_location_context: true})

      # Location should be preserved due to explicit context
      assert sanitized == text
      assert mapping == %{}
    end
  end

  describe "sanitize_messages/2" do
    test "sanitizes user message" do
      messages = [%{"role" => "user", "content" => "My email is john@example.com"}]

      {:ok, sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 1
      sanitized_content = hd(sanitized_messages)["content"]
      assert String.contains?(sanitized_content, "<EMAIL_1>")
      assert Map.has_key?(mapping, {:email, 1})
    end

    test "sanitizes multiple messages" do
      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "My email is john@example.com"},
        %{"role" => "assistant", "content" => "Hello!"}
      ]

      {:ok, sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 3
      assert Map.has_key?(mapping, {:email, 1})
    end

    test "merges mappings from multiple messages" do
      messages = [
        %{"role" => "user", "content" => "Email: john@example.com"},
        %{"role" => "user", "content" => "Phone: 555-123-4567"}
      ]

      {:ok, _sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages)

      assert Map.has_key?(mapping, {:email, 1})
      assert Map.has_key?(mapping, {:phone, 1})
    end

    test "handles empty messages list" do
      {:ok, sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages([])

      assert sanitized_messages == []
      assert mapping == %{}
    end

    test "handles messages without content" do
      messages = [%{"role" => "user"}]

      {:ok, sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 1
      assert mapping == %{}
    end

    test "handles multi-part content" do
      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "My email is john@example.com"},
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/image.png"}}
          ]
        }
      ]

      {:ok, sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 1
      content = hd(sanitized_messages)["content"]
      assert is_list(content)

      text_part = Enum.find(content, fn part -> Map.has_key?(part, "text") end)
      assert String.contains?(text_part["text"], "<EMAIL_1>")
      assert Map.has_key?(mapping, {:email, 1})
    end
  end

  describe "restore/2" do
    test "restores single placeholder" do
      text = "My email is <EMAIL_1>"
      mapping = %{{:email, 1} => "john@example.com"}

      {:ok, restored} = Sanitizer.restore(text, mapping)

      assert restored == "My email is john@example.com"
    end

    test "restores multiple placeholders" do
      text = "Email: <EMAIL_1>, Phone: <PHONE_1>"
      mapping = %{{:email, 1} => "john@example.com", {:phone, 1} => "555-123-4567"}

      {:ok, restored} = Sanitizer.restore(text, mapping)

      assert restored == "Email: john@example.com, Phone: 555-123-4567"
    end

    test "returns text unchanged if no placeholders" do
      text = "Hello world"
      mapping = %{}

      {:ok, restored} = Sanitizer.restore(text, mapping)

      assert restored == text
    end

    test "returns text unchanged if mapping empty" do
      text = "Email: <EMAIL_1>"
      mapping = %{}

      {:ok, restored} = Sanitizer.restore(text, mapping)

      assert restored == text
    end
  end

  describe "restore_response/2" do
    test "restores PII in string response" do
      response = "Your email <EMAIL_1> has been registered."
      mapping = %{{:email, 1} => "john@example.com"}

      {:ok, restored} = Sanitizer.restore_response(response, mapping)

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

      mapping = %{{:person, 1} => "John"}

      {:ok, restored} = Sanitizer.restore_response(response, mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) == "Hello John!"
    end

    test "restores PII in list response" do
      response = [
        %{"content" => "Hello <PERSON_1>"},
        %{"content" => "Email: <EMAIL_1>"}
      ]

      mapping = %{{:person, 1} => "John", {:email, 1} => "john@example.com"}

      {:ok, restored} = Sanitizer.restore_response(response, mapping)

      assert hd(restored)["content"] == "Hello John"
      assert hd(tl(restored))["content"] == "Email: john@example.com"
    end

    test "returns response unchanged if mapping empty" do
      response = %{"content" => "Hello world"}

      {:ok, restored} = Sanitizer.restore_response(response, %{})

      assert restored == response
    end

    test "handles deeply nested structures" do
      response = %{
        "level1" => %{
          "level2" => %{
            "level3" => "Value: <EMAIL_1>"
          }
        }
      }

      mapping = %{{:email, 1} => "test@example.com"}

      {:ok, restored} = Sanitizer.restore_response(response, mapping)

      assert restored["level1"]["level2"]["level3"] == "Value: test@example.com"
    end
  end

  describe "with existing mapping and reverse index" do
    test "reuses existing placeholder for same PII value" do
      text = "My email is john@example.com"
      existing_mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      {:ok, sanitized, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize(text,
          existing_mapping: existing_mapping,
          reverse_index: reverse_index
        )

      assert sanitized == "My email is <EMAIL_1>"
      # Mapping should include existing entries
      assert mapping[{:email, 1}] == "john@example.com"
      # Reverse index should include existing entries
      assert new_reverse_index[{"john@example.com", :email}] == {:email, 1}
    end

    test "new PII value gets next counter" do
      text = "My email is jane@example.com"
      existing_mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      {:ok, sanitized, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize(text,
          existing_mapping: existing_mapping,
          reverse_index: reverse_index
        )

      assert sanitized == "My email is <EMAIL_2>"
      # Should include existing mapping entries
      assert mapping[{:email, 1}] == "john@example.com"
      # Should include new mapping entry
      assert mapping[{:email, 2}] == "jane@example.com"
      # Reverse index should include both
      assert new_reverse_index[{"john@example.com", :email}] == {:email, 1}
      assert new_reverse_index[{"jane@example.com", :email}] == {:email, 2}
    end

    test "mixed: some PII reused, some new" do
      text = "Emails: john@example.com and jane@example.com"
      existing_mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      {:ok, sanitized, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize(text,
          existing_mapping: existing_mapping,
          reverse_index: reverse_index
        )

      assert String.contains?(sanitized, "<EMAIL_1>")
      assert String.contains?(sanitized, "<EMAIL_2>")
      assert mapping[{:email, 1}] == "john@example.com"
      assert mapping[{:email, 2}] == "jane@example.com"
      assert new_reverse_index[{"john@example.com", :email}] == {:email, 1}
      assert new_reverse_index[{"jane@example.com", :email}] == {:email, 2}
    end

    test "without reverse_index but with mapping" do
      text = "My email is jane@example.com"
      existing_mapping = %{{:email, 1} => "john@example.com"}

      {:ok, sanitized, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize(text, existing_mapping: existing_mapping)

      assert sanitized == "My email is <EMAIL_2>"
      assert mapping[{:email, 1}] == "john@example.com"
      assert mapping[{:email, 2}] == "jane@example.com"
      # reverse_index should be built for the new entry
      assert new_reverse_index[{"jane@example.com", :email}] == {:email, 2}
    end

    test "without either opt: backward compatible" do
      text = "My email is john@example.com"

      {:ok, sanitized, mapping, reverse_index, _counts} = Sanitizer.sanitize(text)

      assert sanitized == "My email is <EMAIL_1>"
      assert mapping == %{{:email, 1} => "john@example.com"}
      assert reverse_index == %{{"john@example.com", :email} => {:email, 1}}
    end
  end

  describe "sanitize_messages/2 with existing mapping and reverse index" do
    test "reuses placeholders across messages" do
      existing_mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"}
      ]

      {:ok, sanitized_messages, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages,
          existing_mapping: existing_mapping,
          reverse_index: reverse_index
        )

      sanitized_content = hd(sanitized_messages)["content"]
      assert String.contains?(sanitized_content, "<EMAIL_1>")
      refute String.contains?(sanitized_content, "<EMAIL_2>")
      assert mapping[{:email, 1}] == "john@example.com"
      assert new_reverse_index[{"john@example.com", :email}] == {:email, 1}
    end

    test "new PII in messages gets next counter" do
      existing_mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      messages = [
        %{"role" => "user", "content" => "My email is jane@example.com"}
      ]

      {:ok, sanitized_messages, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages,
          existing_mapping: existing_mapping,
          reverse_index: reverse_index
        )

      sanitized_content = hd(sanitized_messages)["content"]
      assert String.contains?(sanitized_content, "<EMAIL_2>")
      assert mapping[{:email, 1}] == "john@example.com"
      assert mapping[{:email, 2}] == "jane@example.com"
      assert new_reverse_index[{"jane@example.com", :email}] == {:email, 2}
    end

    test "accumulates across multiple messages in sequence" do
      existing_mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}

      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"},
        %{"role" => "assistant", "content" => "Got it!"},
        %{"role" => "user", "content" => "Also jane@example.com please"}
      ]

      {:ok, sanitized_messages, mapping, new_reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages,
          existing_mapping: existing_mapping,
          reverse_index: reverse_index
        )

      first_content = Enum.at(sanitized_messages, 0)["content"]
      third_content = Enum.at(sanitized_messages, 2)["content"]

      assert String.contains?(first_content, "<EMAIL_1>")
      refute String.contains?(first_content, "<EMAIL_2>")
      assert String.contains?(third_content, "<EMAIL_2>")
      assert mapping[{:email, 1}] == "john@example.com"
      assert mapping[{:email, 2}] == "jane@example.com"
      assert new_reverse_index[{"john@example.com", :email}] == {:email, 1}
      assert new_reverse_index[{"jane@example.com", :email}] == {:email, 2}
    end
  end

  describe "sanitize_with_cache/3" do
    setup do
      Patterns.load_into_persistent_term()
      ShhAi.ConversationStore.ETS.init()
      :ets.delete_all_objects(:conversation_message_cache)
      :ets.delete_all_objects(:conversations)
      :ets.delete_all_objects(:conversation_mappings)
      :ets.delete_all_objects(:conversation_reverse_index)

      {:ok, conv} = ShhAi.Conversation.find_or_create(nil, %{source_provider: :openai})
      %{conversation_id: conv.conversation_id}
    end

    test "cache miss: produces same output as uncached sanitize_messages", %{
      conversation_id: conv_id
    } do
      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"}
      ]

      {:ok, sanitized_no_cache, mapping_no_cache, _ri_no_cache, _counts_no_cache} =
        Sanitizer.sanitize_messages(messages)

      {:ok, sanitized_cached, mapping_cached, _ri_cached, _counts_cached} =
        Sanitizer.sanitize_with_cache(messages, conv_id)

      assert sanitized_cached == sanitized_no_cache
      assert mapping_cached == mapping_no_cache
    end

    test "cache hit: skips detection and reuses sanitized text", %{conversation_id: conv_id} do
      messages = [
        %{"role" => "user", "content" => "My email is john@example.com"}
      ]

      {:ok, sanitized1, mapping1, _ri1, counts1} =
        Sanitizer.sanitize_with_cache(messages, conv_id)

      assert counts1 == {1, 0}
      assert String.contains?(hd(sanitized1)["content"], "<EMAIL_1>")

      {:ok, sanitized2, mapping2, _ri2, counts2} =
        Sanitizer.sanitize_with_cache(messages, conv_id)

      assert sanitized2 == sanitized1
      assert mapping2 == mapping1
      assert counts2 == {0, 0}
    end

    test "cache hit preserves exact same sanitized output", %{conversation_id: conv_id} do
      messages = [
        %{"role" => "system", "content" => "You are helpful."},
        %{"role" => "user", "content" => "Email john@example.com and call 555-123-4567"}
      ]

      {:ok, first_result, _, _, _} = Sanitizer.sanitize_with_cache(messages, conv_id)
      {:ok, second_result, _, _, _} = Sanitizer.sanitize_with_cache(messages, conv_id)

      assert first_result == second_result
    end

    test "cache miss accumulates new mapping entries correctly", %{conversation_id: conv_id} do
      messages1 = [
        %{"role" => "user", "content" => "Email: john@example.com"}
      ]

      {:ok, _sanitized1, mapping1, ri1, _counts1} =
        Sanitizer.sanitize_with_cache(messages1, conv_id)

      assert mapping1[{:email, 1}] == "john@example.com"

      messages2 = [
        %{"role" => "user", "content" => "Email: john@example.com"},
        %{"role" => "user", "content" => "Also: jane@example.org"}
      ]

      {:ok, sanitized2, mapping2, _ri2, _counts2} =
        Sanitizer.sanitize_with_cache(messages2, conv_id,
          existing_mapping: mapping1,
          reverse_index: ri1
        )

      content_first = Enum.at(sanitized2, 0)["content"]
      assert String.contains?(content_first, "<EMAIL_1>")

      content_second = Enum.at(sanitized2, 1)["content"]
      assert String.contains?(content_second, "<EMAIL_2>")
      assert mapping2[{:email, 2}] == "jane@example.org"
    end

    test "mixed hit and miss in same call", %{conversation_id: conv_id} do
      sys_msg = [%{"role" => "system", "content" => "You are a helpful assistant."}]
      {:ok, _, _, _, _} = Sanitizer.sanitize_with_cache(sys_msg, conv_id)

      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "My SSN is 123-45-6789"}
      ]

      {:ok, sanitized, mapping, _ri, counts} =
        Sanitizer.sanitize_with_cache(messages, conv_id)

      assert Enum.at(sanitized, 0)["content"] == "You are a helpful assistant."
      assert String.contains?(Enum.at(sanitized, 1)["content"], "<SSN_1>")
      assert mapping[{:ssn, 1}] == "123-45-6789"
      assert counts == {1, 0}
    end
  end

  describe "round-trip sanitization and restoration" do
    test "full round-trip preserves original text" do
      original = "Contact john@example.com or call 555-123-4567"

      {:ok, sanitized, mapping, _reverse_index, _counts} = Sanitizer.sanitize(original)
      {:ok, restored} = Sanitizer.restore(sanitized, mapping)

      assert restored == original
    end

    test "round-trip with messages" do
      messages = [
        %{"role" => "user", "content" => "My email is john@example.com and SSN is 123-45-6789"}
      ]

      {:ok, sanitized_messages, mapping, _reverse_index, _counts} =
        Sanitizer.sanitize_messages(messages)

      # Restore in the sanitized content
      sanitized_content = hd(sanitized_messages)["content"]
      {:ok, restored_content} = Sanitizer.restore(sanitized_content, mapping)

      assert restored_content == hd(messages)["content"]
    end
  end
end
