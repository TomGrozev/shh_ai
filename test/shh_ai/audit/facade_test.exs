defmodule ShhAi.AuditFacadeTest do
  @moduledoc """
  End-to-end tracer bullet for the Audit Mode data plane. Exercises the
  full `Conversation` facade → `ShhAi.Audit.Writer` → SQLite path, with
  the same per-test tmp DB / Repo kill-and-restart setup as
  `ShhAi.Audit.WriterTest`.

  Two scenarios are covered:

    1. `AUDIT_MODE=true` — the full persist_turn flow produces the expected
       rows in `conversations` and `conversation_messages`, with the PII
       columns encrypted at rest.
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
  alias ShhAi.Conversation.Fingerprinter
  alias ShhAi.Repo

  setup do
    ShhAi.AuditCase.setup_audit()
  end

  describe "facade → Writer end-to-end" do
    test "AUDIT_MODE=true: persist_turn writes the expected encrypted rows" do
      messages = [
        %{role: "user", content: "My email is alice@example.com"},
        %{role: "assistant", content: "Got it."}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      conv = %{conv | new?: true}

      fingerprint = Fingerprinter.fingerprint_messages(messages)
      conversation_id = Fingerprinter.derive_conversation_id(fingerprint)
      conv = %{conv | conversation_id: conversation_id}

      sanitized_messages =
        Enum.map(messages, fn msg ->
          %{"role" => msg[:role], "content" => msg[:content]}
        end)

      {:ok, final_id} =
        Conversation.persist_turn(
          conversation: conv,
          sanitized_messages: sanitized_messages,
          assistant_message_hash: "",
          mapping: %{"EMAIL_1" => "alice@example.com"},
          reverse_index: %{{"alice@example.com", :email} => "EMAIL_1"},
          request_time: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          fingerprint: fingerprint
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

      # The conversation_messages rows exist (one per message).
      msg_rows = rows_in_conversation_messages(final_id)
      assert length(msg_rows) == 2
      roles = Enum.map(msg_rows, & &1["role"]) |> Enum.sort()
      assert roles == ["assistant", "user"]
    end

    test "AUDIT_MODE=false: the same persist_turn flow produces no SQLite writes" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      messages = [
        %{role: "user", content: "Some other email"},
        %{role: "assistant", content: "ok"}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      conv = %{conv | new?: true}

      fingerprint = Fingerprinter.fingerprint_messages(messages)
      conversation_id = Fingerprinter.derive_conversation_id(fingerprint)
      conv = %{conv | conversation_id: conversation_id}

      sanitized_messages =
        Enum.map(messages, fn msg ->
          %{"role" => msg[:role], "content" => msg[:content]}
        end)

      {:ok, final_id} =
        Conversation.persist_turn(
          conversation: conv,
          sanitized_messages: sanitized_messages,
          assistant_message_hash: "",
          mapping: %{},
          reverse_index: %{},
          request_time: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          fingerprint: fingerprint
        )

      assert :ok = sync_writer()

      # No rows — every facade cast short-circuited on
      # `Config.audit_mode?() == false` before the Writer was
      # involved.
      assert [] = rows_in_conversations(final_id)
      assert [] = rows_in_conversation_messages(final_id)
    end

    test "PII pipeline threads request_time to audit message created_at" do
      messages = [
        %{role: "user", content: "My email is pipeline_test@example.com"},
        %{role: "assistant", content: "Got it."}
      ]

      {:ok, conv} = Conversation.find_or_create(messages, %{source_provider: :openai})
      conv = %{conv | new?: true}

      fingerprint = Fingerprinter.fingerprint_messages(messages)
      conversation_id = Fingerprinter.derive_conversation_id(fingerprint)
      conv = %{conv | conversation_id: conversation_id}

      sanitized_messages =
        Enum.map(messages, fn msg ->
          %{"role" => msg[:role], "content" => msg[:content]}
        end)

      # Use a known request_time so we can verify it appears in the audit rows.
      known_request_time = ~N[2025-01-15 12:34:56]

      {:ok, final_id} =
        Conversation.persist_turn(
          conversation: conv,
          sanitized_messages: sanitized_messages,
          assistant_message_hash: "",
          mapping: %{},
          reverse_index: %{},
          request_time: known_request_time,
          fingerprint: fingerprint
        )

      assert :ok = sync_writer()

      # Query the raw created_at from the messages table.
      rows =
        Repo.query!(
          "SELECT created_at FROM conversation_messages WHERE conversation_id = ?",
          [final_id]
        ).rows

      # All message rows should have the known request_time as created_at.
      # SQLite returns timestamps as ISO 8601 strings, so compare as strings.
      expected_iso = NaiveDateTime.to_iso8601(known_request_time)
      created_at_values = Enum.map(rows, fn [ca] -> ca end)

      assert expected_iso in created_at_values,
             "Expected request_time #{expected_iso} in audit created_at, " <>
               "got: #{inspect(created_at_values)}"
    end
  end

  # ---------------------------------------------------------------------------
  # X-No-Audit end-to-end
  # ---------------------------------------------------------------------------

  describe "X-No-Audit opt-out end-to-end" do
    test "opted_out: true on a Turn 1 conversation produces a tombstone" do
      messages = [
        %{role: "user", content: "My email is optout_test@example.com"},
        %{role: "assistant", content: "Got it."}
      ]

      {:ok, conv} =
        Conversation.find_or_create(messages, %{
          source_provider: :openai,
          opted_out: true
        })

      conv = %{conv | new?: true}

      fingerprint = Fingerprinter.fingerprint_messages(messages)
      conversation_id = Fingerprinter.derive_conversation_id(fingerprint)
      conv = %{conv | conversation_id: conversation_id}

      sanitized_messages =
        Enum.map(messages, fn msg ->
          %{"role" => msg[:role], "content" => msg[:content]}
        end)

      {:ok, final_id} =
        Conversation.persist_turn(
          conversation: conv,
          sanitized_messages: sanitized_messages,
          assistant_message_hash: "",
          mapping: %{},
          reverse_index: %{},
          request_time: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          fingerprint: fingerprint
        )

      assert :ok = sync_writer()

      # The tombstone should exist with opted_out = true and mapping = NULL.
      [row] = rows_in_conversations(final_id)
      assert row["opted_out"] == "true"
      assert row["mapping"] == nil

      # Messages should have been deleted by the opt_out cast.
      assert [] = rows_in_conversation_messages(final_id)
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
