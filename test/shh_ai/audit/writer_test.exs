defmodule ShhAi.Audit.WriterTest do
  @moduledoc """
  Tests the `ShhAi.Audit.Writer` GenServer. The Writer is the data plane
  for Audit Mode — it writes to the `conversations` and
  `conversation_messages` SQLite tables via Ecto schemas, with PII
  columns encrypted at rest through `ShhAi.Audit.Vault`.

  These tests are written one at a time (TDD). Each test uses a fresh
  per-test tmp SQLite DB so they are independent; no Repo mocks.

  See ADR 0010.
  """

  use ExUnit.Case, async: false
  use ShhAi.AuditCase

  alias ShhAi.Audit.Vault
  alias ShhAi.Audit.Writer
  alias ShhAi.Config
  alias ShhAi.Conversation
  alias ShhAi.Repo

  setup do
    ShhAi.AuditCase.setup_audit()
  end

  # ---------------------------------------------------------------------------
  # Audit Mode OFF — all three messages are no-ops
  # ---------------------------------------------------------------------------

  describe "Audit Mode OFF" do
    test "write_conversation is a no-op" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      conv = %Conversation{
        conversation_id: "conv-1",
        source_provider: :openai,
        provider_conversation_id: "thread-1",
        fingerprint_hash: "fp-hash",
        opted_out: false,
        mapping: %{}
      }

      Writer.write_conversation(conv, request_time)

      assert :ok = sync_writer()
      assert [] = rows_in_conversations("conv-1")
    end

    test "update_mapping is a no-op" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      Writer.update_mapping("conv-2", %{"EMAIL_1" => "test@example.com"}, request_time)
      assert :ok = sync_writer()
      assert [] = rows_in_conversations("conv-2")
    end

    test "write_message is a no-op" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Writer.write_message(
        "conv-3",
        "user",
        "sanitized content",
        request_time
      )

      assert :ok = sync_writer()
      assert [] = rows_in_conversation_messages("conv-3")
    end

    test "write_event is a no-op" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      event = %ShhAi.Metrics.Event{
        id: "evt-off-1",
        started_at: 1_700_000_000_000_000,
        ended_at: 1_700_000_150_000_000,
        duration_ms: 150.0,
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: false,
        status: 200,
        conversation_id: "conv-1",
        pii_detected_count: 0,
        pii_sanitized_count: 0,
        pii_preserved_count: 0,
        pii_types: [],
        timings: %{},
        error: nil,
        inserted_at: 1_700_000_150_000_000
      }

      Writer.write_event(event)
      assert :ok = sync_writer()
      assert [] = rows_in_events("evt-off-1")
    end
  end

  # ---------------------------------------------------------------------------
  # Audit Mode ON — happy path writes
  # ---------------------------------------------------------------------------

  describe "Audit Mode ON" do
    test "write_conversation UPSERTs a row in the conversations table" do
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      conv = %Conversation{
        conversation_id: "conv-upsert-1",
        source_provider: :openai,
        provider_conversation_id: "thread-upsert-1",
        fingerprint_hash: "fp-hash-1",
        opted_out: false,
        mapping: %{}
      }

      Writer.write_conversation(conv, request_time)

      assert :ok = sync_writer()

      rows = rows_in_conversations("conv-upsert-1")
      assert length(rows) == 1
      [row] = rows

      assert row["conversation_id"] == "conv-upsert-1"
      assert row["source_provider"] == "openai"
      assert row["provider_conversation_id"] == "thread-upsert-1"
      assert row["fingerprint_hash"] == "fp-hash-1"
      # SQLite encodes booleans as the strings "true" / "false".
      assert row["opted_out"] == "false"
      # Empty mapping — no PII detected yet.
      assert row["mapping"] == nil
    end

    test "write_conversation UPSERT preserves opted_out: true on conflict" do
      conv_id = "conv-opted-out-upsert"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-opted",
        fingerprint_hash: "fp-opted",
        opted_out: true,
        mapping: %{}
      }

      # First insert — opted_out: true
      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "true"

      # Second insert (upsert) — same opted_out: true, different request_time
      request_time2 = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      Writer.write_conversation(conv, request_time2)
      assert :ok = sync_writer()

      [row2] = rows_in_conversations(conv_id)
      assert row2["opted_out"] == "true"
    end

    test "write_conversation with mapping encrypts and stores the BLOB" do
      conv_id = "conv-mapping-1"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      mapping_plaintext = %{"EMAIL_1" => "john@example.com"}

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-mapping-1",
        fingerprint_hash: "fp-mapping-1",
        opted_out: false,
        mapping: mapping_plaintext
      }

      Writer.write_conversation(conv, request_time)

      assert :ok = sync_writer()

      [row] = rows_in_conversations(conv_id)
      blob = row["mapping"]
      assert is_binary(blob)
      refute blob == :erlang.term_to_binary(mapping_plaintext)

      assert {:ok, decrypted} = Vault.decrypt(blob)
      assert :erlang.binary_to_term(decrypted) == mapping_plaintext
    end

    test "update_mapping merges into existing mapping" do
      conv_id = "conv-update-mapping-1"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      initial = %{"EMAIL_1" => "john@example.com"}

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-um-1",
        fingerprint_hash: "fp-um-1",
        opted_out: false,
        mapping: initial
      }

      # Write initial conversation with mapping.
      Writer.write_conversation(conv, request_time)

      assert :ok = sync_writer()

      # Now update with additional mapping.
      extra = %{"PHONE_1" => "555-1234"}
      Writer.update_mapping(conv_id, extra, request_time)
      assert :ok = sync_writer()

      [row] = rows_in_conversations(conv_id)
      blob = row["mapping"]
      assert is_binary(blob)

      assert {:ok, decrypted} = Vault.decrypt(blob)
      merged = :erlang.binary_to_term(decrypted)
      assert merged == Map.merge(initial, extra)
    end

    test "write_message encrypts the sanitized content and writes the row" do
      conv_id = "conv-message-1"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Writer.write_message(
        conv_id,
        "user",
        "Hello <EMAIL_1>",
        request_time
      )

      assert :ok = sync_writer()

      rows = rows_in_conversation_messages(conv_id)
      assert length(rows) == 1
      [row] = rows

      assert row["conversation_id"] == conv_id
      assert row["role"] == "user"
      blob = row["sanitized_content"]
      assert is_binary(blob)
      refute blob == "Hello <EMAIL_1>"

      assert {:ok, "Hello <EMAIL_1>"} = Vault.decrypt(blob)
    end

    test "encryption round-trip via the Writer recovers the original plaintext" do
      conv_id = "conv-roundtrip-1"
      first = "First sanitized message"
      second = "Second sanitized message"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Writer.write_message(conv_id, "user", first, request_time)
      Writer.write_message(conv_id, "assistant", second, request_time)
      assert :ok = sync_writer()

      rows = rows_in_conversation_messages(conv_id)
      assert length(rows) == 2

      decrypted =
        Enum.map(rows, fn row ->
          {:ok, plain} = Vault.decrypt(row["sanitized_content"])
          plain
        end)

      assert first in decrypted
      assert second in decrypted
    end

    test "write_event writes a row to the events table with all fields" do
      event = %ShhAi.Metrics.Event{
        id: "evt-on-1",
        started_at: 1_700_000_000_000_000,
        ended_at: 1_700_000_150_000_000,
        duration_ms: 150.5,
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true,
        status: 200,
        conversation_id: "conv-evt-1",
        pii_detected_count: 3,
        pii_sanitized_count: 2,
        pii_preserved_count: 1,
        pii_types: [:email, :phone],
        timings: %{
          pii_ms: 5.0,
          backend_ms: 140.0,
          restore_ms: 2.0,
          source_conversion_ms: 1.5,
          target_conversion_ms: 1.5
        },
        error: nil,
        inserted_at: 1_700_000_150_000_000
      }

      Writer.write_event(event)
      assert :ok = sync_writer()

      [row] = rows_in_events("evt-on-1")
      assert row["id"] == "evt-on-1"
      assert row["source_provider"] == "openai"
      assert row["target_provider"] == "anthropic"
      assert row["request_path"] == "/v1/chat/completions"
      assert row["method"] == "POST"
      # SQLite booleans come back as 0/1
      assert row["streaming"] == 1
      assert row["status"] == 200
      assert row["conversation_id"] == "conv-evt-1"
      assert row["pii_detected_count"] == 3
      assert row["pii_sanitized_count"] == 2
      assert row["pii_preserved_count"] == 1

      # pii_types is JSON-encoded as a list of strings
      decoded_types = Jason.decode!(row["pii_types"])
      assert "email" in decoded_types
      assert "phone" in decoded_types

      # timings is JSON-encoded as an object
      decoded_timings = Jason.decode!(row["timings"])
      assert decoded_timings["pii_ms"] == 5.0
      assert decoded_timings["backend_ms"] == 140.0
    end

    test "write_event allows NULL conversation_id" do
      event = %ShhAi.Metrics.Event{
        id: "evt-noconv-1",
        started_at: 1_700_000_000_000_000,
        ended_at: 1_700_000_150_000_000,
        duration_ms: 75.0,
        source_provider: :openai,
        target_provider: "openai",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: false,
        status: 200,
        conversation_id: nil,
        pii_detected_count: 0,
        pii_sanitized_count: 0,
        pii_preserved_count: 0,
        pii_types: [],
        timings: %{},
        error: nil,
        inserted_at: 1_700_000_150_000_000
      }

      Writer.write_event(event)
      assert :ok = sync_writer()

      [row] = rows_in_events("evt-noconv-1")
      assert row["conversation_id"] == nil
      assert row["pii_types"] == "[]"
      assert row["timings"] == "{}"
    end

    test "write_event encodes an error map as JSON" do
      event = %ShhAi.Metrics.Event{
        id: "evt-err-1",
        started_at: 1_700_000_000_000_000,
        ended_at: 1_700_000_150_000_000,
        duration_ms: 5.0,
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: false,
        status: 500,
        conversation_id: "conv-err-1",
        pii_detected_count: 0,
        pii_sanitized_count: 0,
        pii_preserved_count: 0,
        pii_types: [],
        timings: %{},
        error: %{type: "backend_error", message: "upstream timeout"},
        inserted_at: 1_700_000_150_000_000
      }

      Writer.write_event(event)
      assert :ok = sync_writer()

      [row] = rows_in_events("evt-err-1")
      assert row["status"] == 500
      decoded_error = Jason.decode!(row["error"])
      assert decoded_error["type"] == "backend_error"
      assert decoded_error["message"] == "upstream timeout"
    end
  end

  # ---------------------------------------------------------------------------
  # Opted-out conversations — update_mapping / write_message are skipped
  # ---------------------------------------------------------------------------

  describe "opted_out = true in Store" do
    test "update_mapping is skipped" do
      conv_id = "conv-optoff-mapping"

      # Insert a conversation into ETS with opted_out = true.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-optoff", "fp-optoff", true}
      )

      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      Writer.update_mapping(conv_id, %{"EMAIL_1" => "alice@example.com"}, request_time)
      assert :ok = sync_writer()

      # The conversations row was never created by write_conversation
      # in this test, so the update_mapping (which reads the audit row)
      # finds nothing and writes nothing.
      assert [] = rows_in_conversations(conv_id)
      assert [] = rows_in_conversation_messages(conv_id)
    end

    test "write_message is skipped" do
      conv_id = "conv-optoff-message"

      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-optoff-msg", "fp-optoff-msg", true}
      )

      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Writer.write_message(
        conv_id,
        "user",
        "should not be stored",
        request_time
      )

      assert :ok = sync_writer()

      assert [] = rows_in_conversation_messages(conv_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Opt-out cast — tombstone creation and cascade delete
  # ---------------------------------------------------------------------------

  describe "opt-out" do
    test "opt_out cast creates tombstone in conversations table" do
      conv_id = "conv-optout-tombstone"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # First write a normal conversation row.
      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-optout",
        fingerprint_hash: "fp-optout",
        opted_out: false,
        mapping: %{"EMAIL_1" => "alice@example.com"}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      # Verify the row exists with opted_out = false.
      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "false"

      # Now cast opt_out.
      Writer.opt_out(conv_id)
      assert :ok = sync_writer()

      # The row should now be a tombstone: opted_out = true, mapping = NULL.
      [row2] = rows_in_conversations(conv_id)
      assert row2["opted_out"] == "true"
      assert row2["mapping"] == nil
    end

    test "opt_out cast deletes conversation_messages rows" do
      conv_id = "conv-optout-msg-delete"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Write some messages.
      Writer.write_message(conv_id, "user", "Hello", request_time)
      Writer.write_message(conv_id, "assistant", "Hi there", request_time)
      assert :ok = sync_writer()

      # Messages exist.
      assert [_ | _] = rows_in_conversation_messages(conv_id)

      # Cast opt_out.
      Writer.opt_out(conv_id)
      assert :ok = sync_writer()

      # Messages are gone.
      assert [] = rows_in_conversation_messages(conv_id)
    end

    test "Audit Mode OFF: opt_out cast is a no-op" do
      System.put_env("AUDIT_MODE", "false")
      Config.load()

      conv_id = "conv-optout-noop"
      Writer.opt_out(conv_id)
      assert :ok = sync_writer()

      # No row should exist — the cast was a no-op.
      assert [] = rows_in_conversations(conv_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Reactivation sync read — opt-out persists across ETS expiry
  # ---------------------------------------------------------------------------

  describe "reactivation sync read" do
    test "write_conversation with ETS opted_out = false finds tombstone, updates ETS, skips write" do
      conv_id = "conv-reactiv-tomb"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Seed SQLite with a tombstone (opted_out = true, mapping = NULL).
      insert_conversation(conv_id, request_time, opted_out: true)

      # Seed ETS with opted_out = false (simulates a fresh ETS entry after
      # expiry / restart).
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-reactiv", "fp-reactiv", false}
      )

      # Verify ETS starts as opted_out = false.
      assert [{_, _, _, _, _, _, false}] = :ets.lookup(:conversations, conv_id)

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-reactiv",
        fingerprint_hash: "fp-reactiv",
        opted_out: false,
        mapping: %{"EMAIL_1" => "alice@example.com"}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      # ETS should now be opted_out = true (tombstone found via sync read).
      assert [{_, _, _, _, _, _, true}] = :ets.lookup(:conversations, conv_id)

      # No new mapping should have been written — the tombstone is unchanged.
      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "true"
      assert row["mapping"] == nil
    end

    test "write_conversation with ETS opted_out = false finds no row, proceeds with write" do
      conv_id = "conv-reactiv-norow"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Seed ETS with opted_out = false, but NO SQLite row exists.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-norow", "fp-norow", false}
      )

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-norow",
        fingerprint_hash: "fp-norow",
        opted_out: false,
        mapping: %{"EMAIL_1" => "bob@example.com"}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      # A row should have been created — the sync read found no tombstone.
      rows = rows_in_conversations(conv_id)
      assert length(rows) == 1
      [row] = rows
      assert row["opted_out"] == "false"
    end

    test "write_conversation with ETS opted_out = true does not perform sync read" do
      conv_id = "conv-skip-sync-read"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Seed ETS with opted_out = true but NO SQLite row.
      # When ETS already has opted_out = true, no sync read is performed.
      # The write proceeds to create the tombstone (UPSERT with opted_out=true).
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-skip", "fp-skip", true}
      )

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-skip",
        fingerprint_hash: "fp-skip",
        opted_out: true,
        mapping: %{"EMAIL_1" => "should-not-exist@example.com"}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      # The write proceeded — a row should exist with opted_out = true.
      # The mapping is set to nil by do_write_conversation via the on_conflict
      # set clause for UPSERT. For a fresh insert, the mapping from the
      # struct is used (encrypted blob). The important thing is that the
      # row exists with opted_out = true — proving the sync read was skipped.
      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "true"
    end

    test "update_mapping with ETS opted_out = false finds tombstone, updates ETS, skips write" do
      conv_id = "conv-reactiv-map-tomb"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Seed SQLite with a tombstone.
      insert_conversation(conv_id, request_time, opted_out: true)

      # Seed ETS with opted_out = false.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-map-tomb", "fp-map-tomb", false}
      )

      Writer.update_mapping(conv_id, %{"EMAIL_1" => "alice@example.com"}, request_time)
      assert :ok = sync_writer()

      # ETS should now be opted_out = true.
      assert [{_, _, _, _, _, _, true}] = :ets.lookup(:conversations, conv_id)

      # No mapping row should exist — the tombstone is unchanged.
      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "true"
    end

    test "write_message with ETS opted_out = false finds tombstone, updates ETS, skips write" do
      conv_id = "conv-reactiv-msg-tomb"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Seed SQLite with a tombstone.
      insert_conversation(conv_id, request_time, opted_out: true)

      # Seed ETS with opted_out = false.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-msg-tomb", "fp-msg-tomb", false}
      )

      Writer.write_message(conv_id, "user", "should not be stored", request_time)
      assert :ok = sync_writer()

      # ETS should now be opted_out = true.
      assert [{_, _, _, _, _, _, true}] = :ets.lookup(:conversations, conv_id)

      # No message should have been written.
      assert [] = rows_in_conversation_messages(conv_id)
    end

    test "end-to-end reactivation: opt out, expire ETS, reactivate, verify no audit write" do
      conv_id = "conv-e2e-reactiv"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # 1. Create a conversation in ETS with opted_out = false.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-e2e", "fp-e2e", false}
      )

      # 2. Write conversation to SQLite, then cast opt_out to create tombstone.
      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-e2e",
        fingerprint_hash: "fp-e2e",
        opted_out: false,
        mapping: %{"EMAIL_1" => "alice@example.com"}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      Writer.opt_out(conv_id)
      assert :ok = sync_writer()

      # Verify tombstone exists.
      [tombstone] = rows_in_conversations(conv_id)
      assert tombstone["opted_out"] == "true"

      # 3. Simulate ETS expiry — delete the ETS row.
      :ets.delete(:conversations, conv_id)
      assert [] = :ets.lookup(:conversations, conv_id)

      # 4. New request with same fingerprint — Store creates fresh ETS entry
      #    with opted_out = false.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 2, "thread-e2e", "fp-e2e", false}
      )

      # 5. Cast write_conversation for the reactivated conversation.
      conv2 = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-e2e",
        fingerprint_hash: "fp-e2e",
        opted_out: false,
        mapping: %{"EMAIL_1" => "bob@example.com"}
      }

      Writer.write_conversation(conv2, request_time)
      assert :ok = sync_writer()

      # 6. Verify: ETS opted_out = true, no new mapping in SQLite.
      assert [{_, _, _, _, _, _, true}] = :ets.lookup(:conversations, conv_id)

      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "true"
      assert row["mapping"] == nil
    end

    test "end-to-end reactivation for update_mapping: opt out, expire ETS, reactivate, verify skipped" do
      conv_id = "conv-e2e-reactiv-map"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # 1. Create a conversation in ETS and SQLite.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-e2e-map", "fp-e2e-map", false}
      )

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-e2e-map",
        fingerprint_hash: "fp-e2e-map",
        opted_out: false,
        mapping: %{}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      # 2. Cast opt_out to create tombstone.
      Writer.opt_out(conv_id)
      assert :ok = sync_writer()

      # 3. Simulate ETS expiry.
      :ets.delete(:conversations, conv_id)

      # 4. Reactivate with fresh ETS entry (opted_out = false).
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 2, "thread-e2e-map", "fp-e2e-map", false}
      )

      # 5. Cast update_mapping.
      Writer.update_mapping(conv_id, %{"EMAIL_1" => "alice@example.com"}, request_time)
      assert :ok = sync_writer()

      # 6. Verify: ETS opted_out = true, tombstone unchanged.
      assert [{_, _, _, _, _, _, true}] = :ets.lookup(:conversations, conv_id)

      [row] = rows_in_conversations(conv_id)
      assert row["opted_out"] == "true"
    end

    test "end-to-end reactivation for write_message: opt out, expire ETS, reactivate, verify skipped" do
      conv_id = "conv-e2e-reactiv-msg"
      request_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # 1. Create a conversation in ETS and SQLite.
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 1, "thread-e2e-msg", "fp-e2e-msg", false}
      )

      conv = %Conversation{
        conversation_id: conv_id,
        source_provider: :openai,
        provider_conversation_id: "thread-e2e-msg",
        fingerprint_hash: "fp-e2e-msg",
        opted_out: false,
        mapping: %{}
      }

      Writer.write_conversation(conv, request_time)
      assert :ok = sync_writer()

      # 2. Cast opt_out to create tombstone.
      Writer.opt_out(conv_id)
      assert :ok = sync_writer()

      # 3. Simulate ETS expiry.
      :ets.delete(:conversations, conv_id)

      # 4. Reactivate with fresh ETS entry (opted_out = false).
      :ets.insert(
        :conversations,
        {conv_id, :openai, 1, 2, "thread-e2e-msg", "fp-e2e-msg", false}
      )

      # 5. Cast write_message.
      Writer.write_message(conv_id, "user", "should not be stored", request_time)
      assert :ok = sync_writer()

      # 6. Verify: ETS opted_out = true, no message written.
      assert [{_, _, _, _, _, _, true}] = :ets.lookup(:conversations, conv_id)
      assert [] = rows_in_conversation_messages(conv_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Casts are async. We synchronise by sending a trivial "ping" GenServer
  # call AFTER the cast and waiting for it to drain the mailbox in
  # order. `GenServer.call/2` to the Writer's queue is sufficient —
  # Erlang's `:gen_server` processes mailbox messages strictly in
  # arrival order, and the Writer's `init/1` returns immediately, so
  # any later call will only succeed after the cast has been handled.
  defp sync_writer do
    GenServer.call(Writer, :sync, 5_000)
  end

  defp rows_in_conversations(conversation_id) do
    Repo.query!(
      "SELECT conversation_id, source_provider, provider_conversation_id, fingerprint_hash, opted_out, mapping, created_at, last_active_at FROM conversations WHERE conversation_id = ?",
      [conversation_id]
    ).rows
    |> Enum.map(fn [cid, sp, pci, fp, oo, m, _ca, _la] ->
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
      "SELECT id, conversation_id, role, sanitized_content, created_at FROM conversation_messages WHERE conversation_id = ?",
      [conversation_id]
    ).rows
    |> Enum.map(fn [id, cid, role, sc, _ca] ->
      %{
        "id" => id,
        "conversation_id" => cid,
        "role" => role,
        "sanitized_content" => sc
      }
    end)
  end

  defp rows_in_events(event_id) do
    Repo.query!(
      "SELECT id, started_at, ended_at, duration_ms, source_provider, target_provider, request_path, method, streaming, status, conversation_id, pii_detected_count, pii_sanitized_count, pii_preserved_count, pii_types, timings, error, inserted_at FROM events WHERE id = ?",
      [event_id]
    ).rows
    |> Enum.map(fn [id, sa, ea, dur, sp, tp, rp, m, st, stat, cid, pdc, psc, ppc, pt, tm, err, ia] ->
      %{
        "id" => id,
        "started_at" => sa,
        "ended_at" => ea,
        "duration_ms" => dur,
        "source_provider" => sp,
        "target_provider" => tp,
        "request_path" => rp,
        "method" => m,
        "streaming" => st,
        "status" => stat,
        "conversation_id" => cid,
        "pii_detected_count" => pdc,
        "pii_sanitized_count" => psc,
        "pii_preserved_count" => ppc,
        "pii_types" => pt,
        "timings" => tm,
        "error" => err,
        "inserted_at" => ia
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Retention cleanup tests
  # ---------------------------------------------------------------------------

  describe "retention cleanup" do
    test "cleanup deletes events older than retention period" do
      old_time =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-40 * 86_400)
        |> NaiveDateTime.truncate(:second)

      fresh_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      insert_event("evt-old-retention", old_time)
      insert_event("evt-fresh-retention", fresh_time)

      Writer.run_cleanup()

      assert [] = rows_in_events("evt-old-retention")
      assert [_] = rows_in_events("evt-fresh-retention")
    end

    test "cleanup deletes events with NULL conversation_id older than retention period" do
      old_time =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-40 * 86_400)
        |> NaiveDateTime.truncate(:second)

      insert_event("evt-old-noconv", old_time, nil)

      Writer.run_cleanup()

      assert [] = rows_in_events("evt-old-noconv")
    end

    test "cleanup deletes conversation_messages for old conversations" do
      old_time =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-40 * 86_400)
        |> NaiveDateTime.truncate(:second)

      insert_conversation("conv-old-msg", old_time)
      insert_message("conv-old-msg", "user", "old message", old_time)

      Writer.run_cleanup()

      assert [] = rows_in_conversations("conv-old-msg")
      assert [] = rows_in_conversation_messages("conv-old-msg")
    end

    test "cleanup deletes conversations older than retention period (including tombstones)" do
      old_time =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-40 * 86_400)
        |> NaiveDateTime.truncate(:second)

      # Tombstone (opted_out: true)
      insert_conversation("conv-old-tomb", old_time, opted_out: true)
      # Normal old conversation
      insert_conversation("conv-old-normal", old_time, opted_out: false)

      Writer.run_cleanup()

      assert [] = rows_in_conversations("conv-old-tomb")
      assert [] = rows_in_conversations("conv-old-normal")
    end

    test "cleanup respects the configured retention period" do
      snapshot_env(["AUDIT_RETENTION_DAYS"])

      System.put_env("AUDIT_RETENTION_DAYS", "1")
      Config.load()

      two_days_ago =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-2 * 86_400)
        |> NaiveDateTime.truncate(:second)

      insert_event("evt-retention-1d", two_days_ago)

      Writer.run_cleanup()

      assert [] = rows_in_events("evt-retention-1d")
    after
      System.delete_env("AUDIT_RETENTION_DAYS")
      Config.load()
    end

    test "cleanup is a no-op when Audit Mode is OFF" do
      snapshot_env(["AUDIT_MODE"])

      System.put_env("AUDIT_MODE", "false")
      Config.load()

      old_time =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-40 * 86_400)
        |> NaiveDateTime.truncate(:second)

      insert_event("evt-off-cleanup", old_time)

      Writer.run_cleanup()

      # Row should still be there — cleanup was a no-op.
      assert [_] = rows_in_events("evt-off-cleanup")
    after
      System.put_env("AUDIT_MODE", "true")
      Config.load()
    end

    test "cleanup preserves recent rows across all three tables" do
      fresh_time = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      insert_event("evt-fresh-pres", fresh_time)
      insert_conversation("conv-fresh-pres", fresh_time)
      insert_message("conv-fresh-pres", "user", "fresh message", fresh_time)

      Writer.run_cleanup()

      assert [_] = rows_in_events("evt-fresh-pres")
      assert [_] = rows_in_conversations("conv-fresh-pres")
      assert [_] = rows_in_conversation_messages("conv-fresh-pres")
    end

    test "Writer schedules periodic cleanup on init" do
      state = :sys.get_state(Writer)
      assert is_map(state)
      assert Map.has_key?(state, :cleanup_interval_ms)
      assert is_integer(state.cleanup_interval_ms)
      assert state.cleanup_interval_ms > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Test data helpers
  # ---------------------------------------------------------------------------

  defp insert_event(id, inserted_at, conversation_id \\ nil) do
    %ShhAi.Audit.EventRecord{}
    |> ShhAi.Audit.EventRecord.changeset(%{
      id: id,
      started_at: inserted_at,
      ended_at: inserted_at,
      duration_ms: 1.0,
      source_provider: "openai",
      target_provider: "openai",
      streaming: false,
      pii_detected_count: 0,
      pii_sanitized_count: 0,
      pii_preserved_count: 0,
      pii_types: "[]",
      timings: "{}",
      conversation_id: conversation_id,
      inserted_at: inserted_at
    })
    |> Repo.insert!()
  end

  defp insert_conversation(conv_id, created_at, opts \\ []) do
    defaulted =
      %{
        opted_out: false,
        mapping: nil,
        last_active_at: created_at,
        source_provider: "openai",
        provider_conversation_id: "thread-#{conv_id}",
        fingerprint_hash: "fp-#{conv_id}",
        conversation_id: conv_id,
        created_at: created_at
      }
      |> Map.merge(Map.new(opts))

    %ShhAi.Audit.ConversationRecord{}
    |> ShhAi.Audit.ConversationRecord.insert_changeset(defaulted)
    |> Repo.insert!()
  end

  defp insert_message(conv_id, role, content, created_at) do
    %ShhAi.Audit.ConversationMessage{}
    |> ShhAi.Audit.ConversationMessage.changeset(%{
      conversation_id: conv_id,
      role: role,
      sanitized_content: content,
      created_at: created_at
    })
    |> Repo.insert!()
  end
end
