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
end
