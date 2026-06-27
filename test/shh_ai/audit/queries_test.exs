defmodule ShhAi.Audit.QueriesTest do
  @moduledoc """
  Tests for `ShhAi.Audit.Queries` — the read-only Ecto query layer
  for the Audit Mode dashboard.

  Mirrors the test patterns from `ShhAi.Audit.WriterTest` (per-test
  tmp SQLite DB via `ShhAi.AuditCase.setup_audit/0`).
  """

  use ExUnit.Case, async: false
  use ShhAi.AuditCase

  alias ShhAi.Audit.EventRecord
  alias ShhAi.Audit.Queries
  alias ShhAi.Audit.ConversationRecord
  alias ShhAi.Repo

  setup do
    ShhAi.AuditCase.setup_audit()
    :ok
  end

  # Helpers (mirror writer_test.exs)

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

    %ConversationRecord{}
    |> ConversationRecord.insert_changeset(defaulted)
    |> Repo.insert!()
  end

  defp insert_event(id, inserted_at, conversation_id \\ nil) do
    %EventRecord{}
    |> EventRecord.changeset(%{
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

  # ---------------------------------------------------------------------------
  # audit_mode?/0
  # ---------------------------------------------------------------------------

  describe "audit_mode?/0" do
    test "returns true when audit mode is ON" do
      assert Queries.audit_mode?() == true
    end

    test "returns false when audit mode is OFF" do
      snapshot_env(["AUDIT_MODE"])
      System.put_env("AUDIT_MODE", "false")
      ShhAi.Config.load()

      try do
        assert Queries.audit_mode?() == false
      after
        System.put_env("AUDIT_MODE", "true")
        ShhAi.Config.load()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # list_conversations/1
  # ---------------------------------------------------------------------------

  describe "list_conversations/1" do
    test "returns all conversations ordered by last_active_at DESC" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      insert_conversation("conv-a", NaiveDateTime.add(now, -3600, :second),
        last_active_at: NaiveDateTime.add(now, -3600, :second)
      )

      insert_conversation("conv-b", NaiveDateTime.add(now, -60, :second),
        last_active_at: NaiveDateTime.add(now, -60, :second)
      )

      insert_conversation("conv-c", now, last_active_at: now)

      result = Queries.list_conversations()

      assert length(result) == 3
      assert Enum.map(result, & &1.conversation_id) == ["conv-c", "conv-b", "conv-a"]
    end

    test "respects :limit option" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      for i <- 1..5 do
        ts = NaiveDateTime.add(now, -i * 60, :second)
        insert_conversation("conv-#{i}", ts, last_active_at: ts)
      end

      assert length(Queries.list_conversations(limit: 2)) == 2
    end

    test "filters by :source_provider" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-openai", now, source_provider: "openai")
      insert_conversation("conv-anthropic", now, source_provider: "anthropic")

      result = Queries.list_conversations(source_provider: "anthropic")

      assert length(result) == 1
      assert hd(result).conversation_id == "conv-anthropic"
    end

    test "filters by :opted_out (true)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-active", now, opted_out: false)
      insert_conversation("conv-opted-out", now, opted_out: true)

      result = Queries.list_conversations(opted_out: true)

      assert length(result) == 1
      assert hd(result).conversation_id == "conv-opted-out"
    end

    test "filters by :opted_out (false)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-active", now, opted_out: false)
      insert_conversation("conv-opted-out", now, opted_out: true)

      result = Queries.list_conversations(opted_out: false)

      assert length(result) == 1
      assert hd(result).conversation_id == "conv-active"
    end

    test "filters by :since (last_active_at >= since)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      old = NaiveDateTime.add(now, -3600, :second)
      recent = NaiveDateTime.add(now, -60, :second)
      insert_conversation("conv-old", old, last_active_at: old)
      insert_conversation("conv-recent", recent, last_active_at: recent)

      cutoff = NaiveDateTime.add(now, -300, :second)
      result = Queries.list_conversations(since: cutoff)

      assert length(result) == 1
      assert hd(result).conversation_id == "conv-recent"
    end

    test "combines multiple filters" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-1", now, source_provider: "openai", opted_out: false)
      insert_conversation("conv-2", now, source_provider: "anthropic", opted_out: true)
      insert_conversation("conv-3", now, source_provider: "anthropic", opted_out: false)

      result =
        Queries.list_conversations(
          source_provider: "anthropic",
          opted_out: false,
          limit: 10
        )

      assert length(result) == 1
      assert hd(result).conversation_id == "conv-3"
    end
  end

  # ---------------------------------------------------------------------------
  # list_events/1
  # ---------------------------------------------------------------------------

  describe "list_events/1" do
    test "returns all events ordered by inserted_at DESC" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_event("evt-1", NaiveDateTime.add(now, -120, :second))
      insert_event("evt-2", NaiveDateTime.add(now, -60, :second))
      insert_event("evt-3", now)

      result = Queries.list_events()

      assert length(result) == 3
      assert Enum.map(result, & &1.id) == ["evt-3", "evt-2", "evt-1"]
    end

    test "respects :limit option" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      for i <- 1..5 do
        insert_event("evt-#{i}", NaiveDateTime.add(now, -i * 60, :second))
      end

      assert length(Queries.list_events(limit: 2)) == 2
    end

    test "filters by :conversation_id (string)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_event("evt-a", now, "conv-1")
      insert_event("evt-b", now, "conv-2")
      insert_event("evt-c", now, "conv-1")

      result = Queries.list_events(conversation_id: "conv-1")

      assert length(result) == 2
      assert Enum.map(result, & &1.id) |> Enum.sort() == ["evt-a", "evt-c"]
    end

    test "filters by :conversation_id = nil returns events with NULL conversation_id" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_event("evt-with-conv", now, "conv-1")
      insert_event("evt-without-conv-a", now, nil)
      insert_event("evt-without-conv-b", now, nil)

      result = Queries.list_events(conversation_id: nil)

      assert length(result) == 2

      assert Enum.map(result, & &1.id) |> Enum.sort() == [
               "evt-without-conv-a",
               "evt-without-conv-b"
             ]
    end

    test "filters by :since (inserted_at >= since)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      old = NaiveDateTime.add(now, -3600, :second)
      recent = NaiveDateTime.add(now, -60, :second)
      insert_event("evt-old", old)
      insert_event("evt-recent", recent)

      cutoff = NaiveDateTime.add(now, -300, :second)
      result = Queries.list_events(since: cutoff)

      assert length(result) == 1
      assert hd(result).id == "evt-recent"
    end

    test "combines multiple filters (conversation_id + limit + since)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      for i <- 1..3 do
        insert_event("evt-#{i}", now, "conv-1")
      end

      insert_event("evt-other", now, "conv-2")

      cutoff = NaiveDateTime.add(now, -300, :second)

      result =
        Queries.list_events(
          conversation_id: "conv-1",
          since: cutoff,
          limit: 2
        )

      assert length(result) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # count_metadata_for_conversations/1
  # ---------------------------------------------------------------------------

  describe "count_metadata_for_conversations/1" do
    test "returns empty map for empty list" do
      assert Queries.count_metadata_for_conversations([]) == %{}
    end

    test "returns event count and total pii per conversation_id" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-meta", now)

      insert_event("evt-meta-1", now, "conv-meta")
      insert_event("evt-meta-2", now, "conv-meta")

      result = Queries.count_metadata_for_conversations(["conv-meta"])

      assert %{"conv-meta" => %{event_count: 2, total_pii: 0}} = result
    end

    test "excludes conversations with no events (returns partial map)" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-no-events", now)

      result = Queries.count_metadata_for_conversations(["conv-no-events"])

      # Empty — caller uses Map.get/3 with defaults.
      assert result == %{}
    end

    test "sums pii_detected_count correctly across multiple events" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      insert_conversation("conv-pii", now)

      # Insert events with explicit pii_detected_count values.
      %EventRecord{}
      |> EventRecord.changeset(%{
        id: "evt-pii-1",
        started_at: now,
        ended_at: now,
        duration_ms: 1.0,
        source_provider: "openai",
        target_provider: "openai",
        streaming: false,
        pii_detected_count: 3,
        pii_sanitized_count: 3,
        pii_preserved_count: 0,
        pii_types: "[]",
        timings: "{}",
        conversation_id: "conv-pii",
        inserted_at: now
      })
      |> Repo.insert!()

      %EventRecord{}
      |> EventRecord.changeset(%{
        id: "evt-pii-2",
        started_at: now,
        ended_at: now,
        duration_ms: 1.0,
        source_provider: "openai",
        target_provider: "openai",
        streaming: false,
        pii_detected_count: 2,
        pii_sanitized_count: 2,
        pii_preserved_count: 0,
        pii_types: "[]",
        timings: "{}",
        conversation_id: "conv-pii",
        inserted_at: now
      })
      |> Repo.insert!()

      result = Queries.count_metadata_for_conversations(["conv-pii"])

      assert %{"conv-pii" => %{event_count: 2, total_pii: 5}} = result
    end
  end
end
