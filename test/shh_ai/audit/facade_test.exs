defmodule ShhAi.AuditFacadeTest do
  @moduledoc """
  End-to-end tracer bullet for the Audit Mode data plane. Exercises the
  full `Conversation` facade → `ShhAi.Audit.Writer` → SQLite path, with
  the same per-test tmp DB / Repo kill-and-restart setup as
  `ShhAi.Audit.WriterTest`.

  Two scenarios are covered:

    1. `AUDIT_MODE=true` — the full create → add_mapping → cache_message
       flow produces the expected rows in `conversations` and
       `conversation_messages`, with the PII columns encrypted at rest.
    2. `AUDIT_MODE=false` — the same flow produces no SQLite writes
       (the facade's `Config.audit_mode?()` gate short-circuits the
       casts before the Writer is involved).

  See ADR 0010.
  """

  use ExUnit.Case, async: false
  use ShhAi.AuditCase

  alias ShhAi.Audit.Vault
  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.Repo

  setup do
    ShhAi.AuditCase.setup_audit()
  end

  describe "facade → Writer end-to-end" do
    test "AUDIT_MODE=true: create → add_mapping → cache_message writes the expected encrypted rows" do
      messages = [
        %{role: "user", content: "My email is alice@example.com"},
        %{role: "assistant", content: "Got it."}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})

      # Force the conversation out of "Turn 1" mode so the persist +
      # mapping + cache_message flow runs.
      conv = %{conv | new?: true}

      final_id =
        Conversation.persist_turn_1(
          conv,
          messages,
          %{"EMAIL_1" => "alice@example.com"},
          %{{"alice@example.com", :email} => "EMAIL_1"}
        )

      Conversation.cache_message(
        final_id,
        "hash-1",
        {:user_message, "My email is <EMAIL_1>",
         %{"EMAIL_1" => "alice@example.com"},
         %{{"alice@example.com", :email} => "EMAIL_1"}, {1, 0}}
      )

      assert :ok = sync_writer()

      # The conversations row exists and is encrypted.
      [row] = rows_in_conversations(final_id)
      assert row["conversation_id"] == final_id
      assert row["source_provider"] == "openai"
      assert row["opted_out"] == "false"

      blob = row["mapping"]
      assert is_binary(blob)
      assert {:ok, decrypted} = Vault.decrypt(blob)
      assert :erlang.binary_to_term(decrypted) == %{"EMAIL_1" => "alice@example.com"}

      # The conversation_messages row exists and is encrypted.
      [msg_row] = rows_in_conversation_messages(final_id)
      assert msg_row["role"] == "user"
      msg_blob = msg_row["sanitized_content"]
      assert is_binary(msg_blob)
      assert {:ok, "My email is <EMAIL_1>"} = Vault.decrypt(msg_blob)
    end

    test "AUDIT_MODE=false: the same facade flow produces no SQLite writes" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      messages = [
        %{role: "user", content: "Some other email"},
        %{role: "assistant", content: "ok"}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      conv = %{conv | new?: true}

      final_id =
        Conversation.persist_turn_1(
          conv,
          messages,
          %{},
          %{}
        )

      Conversation.cache_message(
        final_id,
        "hash-2",
        {:user_message, "Some other email", %{}, %{}, {0, 0}}
      )

      assert :ok = sync_writer()

      # No rows — every facade cast short-circuited on
      # `Config.audit_mode?() == false` before the Writer was
      # involved.
      assert [] = rows_in_conversations(final_id)
      assert [] = rows_in_conversation_messages(final_id)
    end

    test "PII pipeline threads request_time to audit message created_at" do
      alias ShhAi.PIIPipeline

      messages = [
        %{role: "user", content: "My email is pipeline_test@example.com"},
        %{role: "assistant", content: "Got it."}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      conv = %{conv | new?: true}

      final_id =
        Conversation.persist_turn_1(
          conv,
          messages,
          %{},
          %{}
        )

      # Pre-populate the cache so the pipeline takes the Turn 2+ path
      # (reduce_with_cache → handle_message_with_cache → cache_message).
      hash = Conversation.hash_message(hd(messages))

      Conversation.cache_message(
        final_id,
        hash,
        {:user_message, "My email is <EMAIL_1>", %{}, %{}, {0, 0}}
      )

      assert :ok = sync_writer()

      # Now call the PII pipeline with a known request_time.
      # The pipeline should thread this request_time through to the
      # audit message's created_at column instead of using utc_now.
      known_request_time = ~N[2025-01-15 12:34:56]

      {:ok, _result} =
        PIIPipeline.sanitize_openai_request(
          %{"messages" => messages},
          %{conv | new?: false, conversation_id: final_id},
          request_time: known_request_time
        )

      assert :ok = sync_writer()

      # Query the raw created_at from the messages table.
      rows =
        Repo.query!(
          "SELECT created_at FROM conversation_messages WHERE conversation_id = ?",
          [final_id]
        ).rows

      # At least one row should have the known request_time as created_at.
      # SQLite returns timestamps as ISO 8601 strings, so compare as strings.
      expected_iso = NaiveDateTime.to_iso8601(known_request_time)
      created_at_values = Enum.map(rows, fn [ca] -> ca end)

      assert expected_iso in created_at_values,
             "Expected request_time #{expected_iso} in audit created_at, " <>
               "got: #{inspect(created_at_values)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sync_writer do
    GenServer.call(ShhAi.Audit.Writer, :sync, 5_000)
  end

  defp rows_in_conversations(conversation_id) do
    Repo.query!(
      "SELECT conversation_id, source_provider, provider_conversation_id, fingerprint_hash, opted_out, mapping FROM conversations WHERE conversation_id = ?",
      [conversation_id]
    ).rows
    |> Enum.map(fn [cid, sp, pci, fp, oo, m] ->
      %{
        "conversation_id" => cid,
        "source_provider" => sp,
        "provider_conversation_id" => pci,
        "fingerprint_hash" => fp,
        "opted_out" => if(oo == 1, do: "true", else: "false"),
        "mapping" => m
      }
    end)
  end

  defp rows_in_conversation_messages(conversation_id) do
    Repo.query!(
      "SELECT id, conversation_id, role, sanitized_content FROM conversation_messages WHERE conversation_id = ?",
      [conversation_id]
    ).rows
    |> Enum.map(fn [id, cid, role, sc] ->
      %{
        "id" => id,
        "conversation_id" => cid,
        "role" => role,
        "sanitized_content" => sc
      }
    end)
  end
end
