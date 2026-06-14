defmodule ShhAi.ConversationIntegrationTest do
  @moduledoc """
  Cross-provider continuity integration tests.

  Validates the end-to-end flow: a conversation accumulates PII mappings
  across multiple turns, and the mappings are reused regardless of which
  source_provider created the conversation — because PII operations always
  happen in canonical (OpenAI) format.

  Exercises the full stack: `Conversation` → `ConversationStore.ETS` →
  `PII.Sanitizer` (with `existing_mapping`/`reverse_index`) → `PIIPipeline`.
  """

  # async: false — these tests touch the shared named ETS tables
  # and the persistent_term patterns loaded by PII.Patterns.
  use ExUnit.Case, async: false

  alias ShhAi.{Conversation, PIIPipeline}
  alias ShhAi.PII.Patterns

  setup do
    # Ensure PII patterns are loaded into persistent_term.
    Patterns.load_into_persistent_term()

    ShhAi.ConversationCase.setup_ets()
  end

  # ---------------------------------------------------------------------------
  # Test 1: Cross-provider placeholder reuse
  #
  # A conversation is created via :openai. PII is sanitized through the
  # pipeline, which stores the mapping in canonical format.  A subsequent
  # request — even one that *conceptually* comes from :anthropic — reuses
  # the same placeholders because the pipeline always operates in canonical
  # format and the mapping lives on the conversation (not on the provider).
  # ---------------------------------------------------------------------------

  describe "cross-provider placeholder reuse" do
    test "mapping created via :openai is reused when a different provider accesses the same conversation" do
      # --- Turn 1: :openai creates the conversation and sanitizes ---
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_cross_001"
        })

      assert conversation.new? == true

      body1 = %{
        "messages" => [
          %{"role" => "user", "content" => "My email is john@example.com"}
        ]
      }

      {:ok, sanitized1, mapping1, _ri1, pii_info1} =
        PIIPipeline.sanitize_openai_request(body1, conversation)

      # First turn assigns EMAIL_1
      assert String.contains?(hd(sanitized1["messages"])["content"], "<EMAIL_1>")
      assert mapping1[{:email, 1}] == "john@example.com"
      assert pii_info1.sanitized_count == 1

      # Verify the mapping was persisted in the conversation store
      {:ok, stored_mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert stored_mapping[{:email, 1}] == "john@example.com"

      # --- Turn 2: same conversation, but accessed via a :anthropic-originated
      # request that uses the same conversation_id.  In a real proxy flow the
      # format converter would produce canonical messages; here we simulate
      # that by passing canonical messages directly and reusing the same
      # conversation struct.  The key invariant: EMAIL_1 is reused, not EMAIL_2.

      # The PIIPipeline reads existing mapping/reverse_index from the
      # conversation, so we can pass the same conversation struct regardless
      # of which source_provider originally created it.
      body2 = %{
        "messages" => [
          %{"role" => "user", "content" => "Please email john@example.com again"}
        ]
      }

      {:ok, sanitized2, mapping2, _ri2, pii_info2} =
        PIIPipeline.sanitize_openai_request(body2, conversation)

      # Must reuse EMAIL_1 — not mint EMAIL_2
      content2 = hd(sanitized2["messages"])["content"]
      assert String.contains?(content2, "<EMAIL_1>")
      refute String.contains?(content2, "<EMAIL_2>")
      assert mapping2[{:email, 1}] == "john@example.com"
      # The email is still detected and sanitized (replaced by a placeholder),
      # even though the same placeholder was reused — detection count reflects
      # what was found, not how many new placeholders were minted.
      assert pii_info2.sanitized_count == 1

      # The stored mapping still has exactly one email entry
      {:ok, final_mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert final_mapping[{:email, 1}] == "john@example.com"
      refute Map.has_key?(final_mapping, {:email, 2})
    end

    test "new PII introduced in a cross-provider turn gets the next placeholder index" do
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :anthropic,
          provider_conversation_id: "thread_cross_002"
        })

      # Turn 1: sanitize with one email
      body1 = %{
        "messages" => [
          %{"role" => "user", "content" => "Contact: john@example.com"}
        ]
      }

      {:ok, _, _, _, _} =
        PIIPipeline.sanitize_openai_request(body1, conversation)

      # Turn 2: same email + a new one
      body2 = %{
        "messages" => [
          %{"role" => "user", "content" => "Also add jane@example.org"}
        ]
      }

      {:ok, sanitized2, mapping2, _ri2, _pii_info2} =
        PIIPipeline.sanitize_openai_request(body2, conversation)

      content2 = hd(sanitized2["messages"])["content"]

      # The new email gets EMAIL_2 (counter seeded from existing EMAIL_1)
      assert String.contains?(content2, "<EMAIL_2>")
      assert mapping2[{:email, 2}] == "jane@example.org"

      # Accumulated mapping has both
      {:ok, stored} = Conversation.get_mapping(conversation.conversation_id)
      assert stored[{:email, 1}] == "john@example.com"
      assert stored[{:email, 2}] == "jane@example.org"
    end

    test "restore works correctly with cross-provider accumulated mapping" do
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_cross_003"
        })

      # Sanitize to build up the mapping
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email john@example.com, call 555-123-4567"}
        ]
      }

      {:ok, _sanitized, _mapping, _ri, _pii} =
        PIIPipeline.sanitize_openai_request(body, conversation)

      # Simulate a response coming back with placeholders
      response = %{
        "choices" => [
          %{
            "message" => %{
              "content" => "I'll email <EMAIL_1> and call <PHONE_1>"
            }
          }
        ]
      }

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, conversation)

      assert restored["choices"] |> hd() |> get_in(["message", "content"]) ==
               "I'll email john@example.com and call 555-123-4567"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2: End-to-end conversation lifecycle
  #
  # Create → sanitize → store mapping → restore response → touch TTL → verify
  # ---------------------------------------------------------------------------

  describe "end-to-end conversation lifecycle" do
    test "full lifecycle: create, sanitize, store, restore, touch, verify" do
      # 1. Create conversation
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_lifecycle_001"
        })

      assert conversation.new? == true
      assert is_binary(conversation.conversation_id)
      assert conversation.source_provider == :openai
      assert conversation.provider_conversation_id == "thread_lifecycle_001"

      # 2. Sanitize a message containing PII
      body = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => "I'm John Smith, email john@example.com, SSN 123-45-6789"
          }
        ]
      }

      {:ok, sanitized, _mapping, _ri, pii_info} =
        PIIPipeline.sanitize_openai_request(body, conversation)

      sanitized_content = hd(sanitized["messages"])["content"]
      assert String.contains?(sanitized_content, "<EMAIL_1>")
      assert String.contains?(sanitized_content, "<SSN_1>")
      assert pii_info.sanitized_count >= 2

      # 3. Verify mapping stored in conversation store
      {:ok, stored_mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert stored_mapping[{:email, 1}] == "john@example.com"
      assert stored_mapping[{:ssn, 1}] == "123-45-6789"

      {:ok, stored_ri} =
        ShhAi.ConversationStore.get_reverse_index(conversation.conversation_id)

      assert stored_ri[{"john@example.com", :email}] == {:email, 1}
      assert stored_ri[{"123-45-6789", :ssn}] == {:ssn, 1}

      # 4. Restore a response using the stored mapping
      response = %{
        "choices" => [
          %{"message" => %{"content" => "Hello <PERSON_1>, your email <EMAIL_1> is on file."}}
        ]
      }

      {:ok, restored} =
        PIIPipeline.restore_openai_response(response, conversation)

      restored_content = restored["choices"] |> hd() |> get_in(["message", "content"])
      assert restored_content == "Hello <PERSON_1>, your email john@example.com is on file."

      # 5. Touch the conversation to reset its sliding TTL
      assert :ok = Conversation.touch(conversation.conversation_id)

      # 6. Verify the conversation still exists and its mapping is intact
      assert {:ok, _} = Conversation.get_mapping(conversation.conversation_id)

      {:ok, final_mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert final_mapping[{:email, 1}] == "john@example.com"
      assert final_mapping[{:ssn, 1}] == "123-45-6789"
    end

    test "conversation deletion removes all accumulated state" do
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_lifecycle_002"
        })

      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Email: john@example.com"}
        ]
      }

      {:ok, _, _, _, _} =
        PIIPipeline.sanitize_openai_request(body, conversation)

      # Sanity: mapping exists
      assert {:ok, mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"

      # Delete
      assert :ok = Conversation.delete(conversation.conversation_id)

      # All state is gone
      assert {:error, :not_found} =
               Conversation.get_mapping(conversation.conversation_id)

      assert {:error, :not_found} =
               ShhAi.ConversationStore.get_reverse_index(conversation.conversation_id)

      assert {:error, :not_found} =
               Conversation.get_mapping(conversation.conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: Placeholder reuse across multiple turns
  # ---------------------------------------------------------------------------

  describe "placeholder reuse across multiple turns" do
    test "same email across three turns always reuses EMAIL_1" do
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_multi_001"
        })

      # Turn 1
      body1 = %{"messages" => [%{"role" => "user", "content" => "Email: john@example.com"}]}
      {:ok, s1, m1, _, _} = PIIPipeline.sanitize_openai_request(body1, conversation)
      assert String.contains?(hd(s1["messages"])["content"], "<EMAIL_1>")
      assert m1[{:email, 1}] == "john@example.com"

      # Turn 2 — same email reappears
      body2 = %{"messages" => [%{"role" => "user", "content" => "Again: john@example.com"}]}
      {:ok, s2, m2, _, _} = PIIPipeline.sanitize_openai_request(body2, conversation)
      assert String.contains?(hd(s2["messages"])["content"], "<EMAIL_1>")
      refute String.contains?(hd(s2["messages"])["content"], "<EMAIL_2>")
      assert m2[{:email, 1}] == "john@example.com"

      # Turn 3 — yet again, plus a new email
      body3 = %{
        "messages" => [
          %{"role" => "user", "content" => "john@example.com and jane@example.org"}
        ]
      }

      {:ok, s3, m3, _, _} = PIIPipeline.sanitize_openai_request(body3, conversation)
      content3 = hd(s3["messages"])["content"]
      assert String.contains?(content3, "<EMAIL_1>")
      assert String.contains?(content3, "<EMAIL_2>")
      assert m3[{:email, 1}] == "john@example.com"
      assert m3[{:email, 2}] == "jane@example.org"

      # Final accumulated state
      {:ok, final_mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert map_size(final_mapping) == 2
      assert final_mapping[{:email, 1}] == "john@example.com"
      assert final_mapping[{:email, 2}] == "jane@example.org"
    end

    test "mixed PII types accumulate correctly across turns" do
      {:ok, conversation} =
        Conversation.find_or_create(nil, %{
          source_provider: :anthropic,
          provider_conversation_id: "thread_multi_002"
        })

      # Turn 1: email
      body1 = %{"messages" => [%{"role" => "user", "content" => "Email: john@example.com"}]}
      {:ok, _, _, _, _} = PIIPipeline.sanitize_openai_request(body1, conversation)

      # Turn 2: phone
      body2 = %{"messages" => [%{"role" => "user", "content" => "Phone: 555-123-4567"}]}
      {:ok, _, _, _, _} = PIIPipeline.sanitize_openai_request(body2, conversation)

      # Turn 3: SSN
      body3 = %{"messages" => [%{"role" => "user", "content" => "SSN: 123-45-6789"}]}
      {:ok, _, _, _, _} = PIIPipeline.sanitize_openai_request(body3, conversation)

      # All three types accumulated
      {:ok, mapping} = Conversation.get_mapping(conversation.conversation_id)
      assert mapping[{:email, 1}] == "john@example.com"
      assert mapping[{:phone, 1}] == "555-123-4567"
      assert mapping[{:ssn, 1}] == "123-45-6789"

      # Reverse index also accumulated
      {:ok, ri} = ShhAi.ConversationStore.get_reverse_index(conversation.conversation_id)
      assert ri[{"john@example.com", :email}] == {:email, 1}
      assert ri[{"555-123-4567", :phone}] == {:phone, 1}
      assert ri[{"123-45-6789", :ssn}] == {:ssn, 1}
    end

    test "conversations do not bleed mappings across different conversations" do
      {:ok, conv_a} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_iso_a"
        })

      {:ok, conv_b} =
        Conversation.find_or_create(nil, %{
          source_provider: :openai,
          provider_conversation_id: "thread_iso_b"
        })

      # Sanitize the same email in both conversations
      body = %{"messages" => [%{"role" => "user", "content" => "Email: john@example.com"}]}

      {:ok, _, _, _, _} = PIIPipeline.sanitize_openai_request(body, conv_a)
      {:ok, _, _, _, _} = PIIPipeline.sanitize_openai_request(body, conv_b)

      # Both have EMAIL_1 → john@example.com (independently)
      {:ok, mapping_a} = Conversation.get_mapping(conv_a.conversation_id)
      {:ok, mapping_b} = Conversation.get_mapping(conv_b.conversation_id)

      assert mapping_a[{:email, 1}] == "john@example.com"
      assert mapping_b[{:email, 1}] == "john@example.com"

      # But they are separate conversation_ids — deleting A doesn't affect B
      Conversation.delete(conv_a.conversation_id)

      assert {:error, :not_found} = Conversation.get_mapping(conv_a.conversation_id)
      assert {:ok, mapping_b} = Conversation.get_mapping(conv_b.conversation_id)
      assert mapping_b[{:email, 1}] == "john@example.com"
    end

    test "Sanitizer with existing_mapping and reverse_index reuses placeholders directly" do
      # This test exercises the Sanitizer layer directly (bypassing PIIPipeline)
      # to confirm that the existing_mapping/reverse_index options work for
      # cross-provider continuity at the lowest level.

      alias ShhAi.PII.Sanitizer

      # Turn 1: fresh sanitization
      {:ok, text1, mapping1, ri1, _} = Sanitizer.sanitize("Contact john@example.com")
      assert text1 == "Contact <EMAIL_1>"
      assert mapping1[{:email, 1}] == "john@example.com"

      # Turn 2: pass existing mapping and reverse_index (simulating what
      # PIIPipeline does when it reads from a Conversation)
      {:ok, text2, mapping2, ri2, _} =
        Sanitizer.sanitize("Again: john@example.com",
          existing_mapping: mapping1,
          reverse_index: ri1
        )

      assert text2 == "Again: <EMAIL_1>"
      refute String.contains?(text2, "<EMAIL_2>")
      assert mapping2[{:email, 1}] == "john@example.com"

      # Turn 3: new PII gets next counter
      {:ok, text3, mapping3, _ri3, _} =
        Sanitizer.sanitize("New: jane@example.org",
          existing_mapping: mapping2,
          reverse_index: ri2
        )

      assert String.contains?(text3, "<EMAIL_2>")
      assert mapping3[{:email, 1}] == "john@example.com"
      assert mapping3[{:email, 2}] == "jane@example.org"
    end
  end
end
