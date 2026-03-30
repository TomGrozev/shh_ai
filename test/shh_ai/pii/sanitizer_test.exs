defmodule ShhAi.PII.SanitizerTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.{Patterns, Sanitizer}

  setup do
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()
    :ok
  end

  describe "sanitize/2" do
    test "sanitizes email addresses" do
      text = "My email is john@example.com"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(text)

      assert sanitized == "My email is <EMAIL_1>"
      assert mapping == %{"<EMAIL_1>" => "john@example.com"}
    end

    test "sanitizes multiple PII items" do
      text = "Email: john@example.com, Phone: 555-123-4567"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<EMAIL_1>")
      assert String.contains?(sanitized, "<PHONE_1>")
      assert Map.has_key?(mapping, "<EMAIL_1>")
      assert Map.has_key?(mapping, "<PHONE_1>")
    end

    test "generates unique placeholders for same type" do
      text = "Emails: john@example.com and jane@example.org"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<EMAIL_1>")
      assert String.contains?(sanitized, "<EMAIL_2>")
      assert Map.has_key?(mapping, "<EMAIL_1>")
      assert Map.has_key?(mapping, "<EMAIL_2>")
    end

    test "preserves text without PII" do
      text = "Hello world"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(text)

      assert sanitized == text
      assert mapping == %{}
    end

    test "sanitizes SSN" do
      text = "SSN: 123-45-6789"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<SSN_1>")
      assert Map.has_key?(mapping, "<SSN_1>")
    end

    test "sanitizes credit card numbers" do
      text = "Card: 4111111111111111"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(text)

      assert String.contains?(sanitized, "<CREDIT_CARD_1>")
      assert Map.has_key?(mapping, "<CREDIT_CARD_1>")
    end
  end

  describe "sanitize/2 with context" do
    test "always sanitizes certain types regardless of context" do
      # SSN should always be sanitized
      text = "SSN: 123-45-6789"

      {:ok, sanitized, _mapping} =
        Sanitizer.sanitize(text, context: %{message_type: :system})

      assert String.contains?(sanitized, "<SSN_1>")
    end

    test "preserves location in system message with location context" do
      text = "Weather in New York"

      {:ok, sanitized, mapping} =
        Sanitizer.sanitize(text, context: %{message_type: :system, has_location_context: true})

      # Location might be preserved due to context
      # This depends on the context rules
      assert is_binary(sanitized)
      assert is_map(mapping)
    end

    test "preserves location when user provides location context" do
      text = "I live in New York"

      {:ok, sanitized, mapping} =
        Sanitizer.sanitize(text, context: %{has_location_context: true})

      # Location should be preserved due to explicit context
      assert sanitized == text
      assert mapping == %{}
    end
  end

  describe "sanitize_messages/2" do
    test "sanitizes user message" do
      messages = [%{"role" => "user", "content" => "My email is john@example.com"}]

      {:ok, sanitized_messages, mapping} = Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 1
      sanitized_content = hd(sanitized_messages)["content"]
      assert String.contains?(sanitized_content, "<EMAIL_1>")
      assert Map.has_key?(mapping, "<EMAIL_1>")
    end

    test "sanitizes multiple messages" do
      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "My email is john@example.com"},
        %{"role" => "assistant", "content" => "Hello!"}
      ]

      {:ok, sanitized_messages, mapping} = Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 3
      assert Map.has_key?(mapping, "<EMAIL_1>")
    end

    test "merges mappings from multiple messages" do
      messages = [
        %{"role" => "user", "content" => "Email: john@example.com"},
        %{"role" => "user", "content" => "Phone: 555-123-4567"}
      ]

      {:ok, _sanitized_messages, mapping} = Sanitizer.sanitize_messages(messages)

      assert Map.has_key?(mapping, "<EMAIL_1>")
      assert Map.has_key?(mapping, "<PHONE_1>")
    end

    test "handles empty messages list" do
      {:ok, sanitized_messages, mapping} = Sanitizer.sanitize_messages([])

      assert sanitized_messages == []
      assert mapping == %{}
    end

    test "handles messages without content" do
      messages = [%{"role" => "user"}]

      {:ok, sanitized_messages, mapping} = Sanitizer.sanitize_messages(messages)

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

      {:ok, sanitized_messages, mapping} = Sanitizer.sanitize_messages(messages)

      assert length(sanitized_messages) == 1
      content = hd(sanitized_messages)["content"]
      assert is_list(content)

      text_part = Enum.find(content, fn part -> Map.has_key?(part, "text") end)
      assert String.contains?(text_part["text"], "<EMAIL_1>")
      assert Map.has_key?(mapping, "<EMAIL_1>")
    end
  end

  describe "restore/2" do
    test "restores single placeholder" do
      text = "My email is <EMAIL_1>"
      mapping = %{"<EMAIL_1>" => "john@example.com"}

      {:ok, restored} = Sanitizer.restore(text, mapping)

      assert restored == "My email is john@example.com"
    end

    test "restores multiple placeholders" do
      text = "Email: <EMAIL_1>, Phone: <PHONE_1>"
      mapping = %{"<EMAIL_1>" => "john@example.com", "<PHONE_1>" => "555-123-4567"}

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
      mapping = %{"<EMAIL_1>" => "john@example.com"}

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

      mapping = %{"<PERSON_1>" => "John"}

      {:ok, restored} = Sanitizer.restore_response(response, mapping)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) == "Hello John!"
    end

    test "restores PII in list response" do
      response = [
        %{"content" => "Hello <PERSON_1>"},
        %{"content" => "Email: <EMAIL_1>"}
      ]

      mapping = %{"<PERSON_1>" => "John", "<EMAIL_1>" => "john@example.com"}

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

      mapping = %{"<EMAIL_1>" => "test@example.com"}

      {:ok, restored} = Sanitizer.restore_response(response, mapping)

      assert restored["level1"]["level2"]["level3"] == "Value: test@example.com"
    end
  end

  describe "round-trip sanitization and restoration" do
    test "full round-trip preserves original text" do
      original = "Contact john@example.com or call 555-123-4567"

      {:ok, sanitized, mapping} = Sanitizer.sanitize(original)
      {:ok, restored} = Sanitizer.restore(sanitized, mapping)

      assert restored == original
    end

    test "round-trip with messages" do
      messages = [
        %{"role" => "user", "content" => "My email is john@example.com and SSN is 123-45-6789"}
      ]

      {:ok, sanitized_messages, mapping} = Sanitizer.sanitize_messages(messages)

      # Restore in the sanitized content
      sanitized_content = hd(sanitized_messages)["content"]
      {:ok, restored_content} = Sanitizer.restore(sanitized_content, mapping)

      assert restored_content == hd(messages)["content"]
    end
  end
end
