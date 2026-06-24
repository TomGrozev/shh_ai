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

    # Update the Repo app config so any supervisor restart uses the
    # tmp path, then kill the auto-started Repo and wait for the
    # supervisor to bring up a new one bound to the test path. After
    # the restart, the process registered as `ShhAi.Repo` is the
    # one bound to our tmp DB.
    Application.put_env(:shh_ai, ShhAi.Repo,
      database: tmp_path,
      pool_size: 5,
      journal_mode: :wal
    )

    restart_repo_to_pick_up_config()

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

  # Force a supervisor restart of the Repo by killing it; the
  # supervisor's `:one_for_one` strategy brings it back with the
  # latest app config, which we just set to the test tmp DB.
  defp restart_repo_to_pick_up_config do
    case Process.whereis(Repo) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
    end

    # Wait until the supervisor-restarted Repo is up and bound to
    # our process registry.
    wait_for_repo(5_000)
  end

  defp wait_for_repo(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if Process.whereis(Repo) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("ShhAi.Repo did not start within #{timeout}ms")
      else
        Process.sleep(20)
        wait_for_repo(deadline - System.monotonic_time(:millisecond))
      end
    end
  end
end
