defmodule ShhAi.RepoTest do
  @moduledoc """
  Smoke-tests the Audit Mode Ecto Repo: real SQLite in a tmp dir,
  `Ecto.Migrator.run/4` against the migration files, and shape
  assertions on the resulting tables / indexes.
  """

  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.Repo

  setup do
    # Snapshot env vars we touch so the test is hermetic.
    ShhAi.AuditCase.snapshot_env([
      "AUDIT_DB_PATH",
      "AUDIT_ENCRYPTION_KEY",
      "AUDIT_MODE"
    ])

    # Per-test tmp DB path. SQLite creates the file on open; we just
    # make sure any prior copy is gone.
    tmp_path =
      Path.join([
        System.tmp_dir!(),
        "shh_ai_repo_test_#{:erlang.unique_integer([:positive])}.db"
      ])

    File.rm(tmp_path)
    on_exit(fn -> File.rm(tmp_path) end)

    System.put_env("AUDIT_DB_PATH", tmp_path)
    System.delete_env("AUDIT_ENCRYPTION_KEY")
    System.delete_env("AUDIT_MODE")
    Config.load()

    # Audit Mode is off here, so the application supervises no Repo
    # (ADR 0016): bind a test-owned instance to the tmp DB.
    ShhAi.AuditCase.repo_on_path(tmp_path)

    %{}
  end

  describe "Repo + migrations boot" do
    test "creates conversations, conversation_messages, and the conversation_id index" do
      migrations_path = Application.app_dir(:shh_ai, "priv/repo/migrations")
      Ecto.Migrator.run(Repo, migrations_path, :up, all: true, log: false)

      table_result =
        Repo.query!(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('conversations','conversation_messages') ORDER BY name"
        )

      table_names = Enum.map(table_result.rows, fn [n] -> n end)
      assert "conversations" in table_names
      assert "conversation_messages" in table_names

      index_result =
        Repo.query!(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='conversation_messages'"
        )

      index_names = Enum.map(index_result.rows, fn [n] -> n end)

      assert Enum.any?(index_names, fn name ->
               String.contains?(name, "conversation_id")
             end)
    end
  end
end
