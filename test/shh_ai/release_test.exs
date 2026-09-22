defmodule ShhAi.ReleaseTest do
  @moduledoc """
  Tests the release migration entrypoint (`ShhAi.Release.migrate/0`,
  `rollback/1`) — the no-Mix surface a container runs (ADR 0015/0016).

  The audit-mode conditionality contract is the load-bearing part:
  `migrate/0` must be a no-op when AUDIT_MODE is off (no database
  file may be created, no Repo started), and must actually migrate
  when it is on.

  As in the real `bin/migrate` eval session, the application tree is
  up but the migration's Repo instance is started by
  `Ecto.Migrator.with_repo/2` from Application env config — not
  supervised by the application — and stopped again after.
  """

  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.Repo

  @migrations_path Application.app_dir(:shh_ai, "priv/repo/migrations")

  setup do
    # Hermetic: snapshot the env vars and the repo config the entrypoint
    # touches, restore both on exit (AuditCase conventions).
    ShhAi.AuditCase.snapshot_env([
      "AUDIT_DB_PATH",
      "AUDIT_MODE",
      "AUDIT_ENCRYPTION_KEY"
    ])

    original_repo_config = Application.get_env(:shh_ai, ShhAi.Repo)

    on_exit(fn ->
      if original_repo_config do
        Application.put_env(:shh_ai, ShhAi.Repo, original_repo_config)
      else
        Application.delete_env(:shh_ai, ShhAi.Repo)
      end
    end)

    tmp_path =
      Path.join([
        System.tmp_dir!(),
        "shh_ai_release_test_#{:erlang.unique_integer([:positive])}.db"
      ])

    File.rm(tmp_path)
    on_exit(fn -> File.rm(tmp_path) end)

    System.delete_env("AUDIT_MODE")
    System.put_env("AUDIT_DB_PATH", tmp_path)
    System.delete_env("AUDIT_ENCRYPTION_KEY")
    Config.load()

    %{tmp_path: tmp_path}
  end

  describe "migrate/0 with audit mode off (ADR 0016)" do
    test "is a no-op: :ok and no database file is created" do
      assert ShhAi.Release.migrate() == :ok

      refute File.exists?(System.get_env("AUDIT_DB_PATH")),
             "audit-off migrate must not create a database"

      refute Process.whereis(Repo), "audit-off migrate must not start a Repo"
    end
  end

  describe "migrate/0 with audit mode on" do
    setup %{tmp_path: tmp_path} do
      System.put_env("AUDIT_ENCRYPTION_KEY", Base.encode32(:crypto.strong_rand_bytes(32)))
      System.put_env("AUDIT_MODE", "true")
      Config.load()
      put_repo_config(tmp_path)

      :ok
    end

    test "migrates the audit database to the latest version" do
      assert ShhAi.Release.migrate() == :ok
      assert migrated_version() == expected_version(:max)
    end

    test "is idempotent: a second run is :ok without change" do
      assert ShhAi.Release.migrate() == :ok
      assert ShhAi.Release.migrate() == :ok
      assert migrated_version() == expected_version(:max)
    end

    test "creates the audit tables" do
      assert ShhAi.Release.migrate() == :ok

      assert tables_in_db() == [
               "conversation_messages",
               "conversations",
               "events",
               "schema_migrations"
             ]
    end

    test "fails loudly when the encryption key is missing while audit is on" do
      # Misconfigured audit deployment: the entrypoint must raise the
      # same boot-path error the application raises, not migrate.
      System.delete_env("AUDIT_ENCRYPTION_KEY")

      assert_raise RuntimeError, ~r/AUDIT_ENCRYPTION_KEY/, fn ->
        ShhAi.Release.migrate()
      end
    end

    test "fails loudly when the database cannot be opened" do
      Application.put_env(
        :shh_ai,
        ShhAi.Repo,
        database: "/proc/nonexistent/audit.db",
        pool_size: 5,
        journal_mode: :wal
      )

      assert_raise DBConnection.ConnectionError, fn ->
        ShhAi.Release.migrate()
      end
    end
  end

  describe "rollback/1" do
    setup %{tmp_path: tmp_path} do
      System.put_env("AUDIT_ENCRYPTION_KEY", Base.encode32(:crypto.strong_rand_bytes(32)))
      System.put_env("AUDIT_MODE", "true")
      Config.load()
      put_repo_config(tmp_path)

      :ok
    end

    test "with audit off is a no-op" do
      System.delete_env("AUDIT_MODE")
      Config.load()

      assert ShhAi.Release.rollback(0) == :ok
      refute File.exists?(System.get_env("AUDIT_DB_PATH"))
    end

    test "rolls back to a version (roll back through the later migration)" do
      assert ShhAi.Release.migrate() == :ok

      # `:down, to: V` undoes every applied version >= V. Rolling back
      # to the FIRST version therefore undoes both migrations; rolling
      # back to the SECOND's version+1 undoes only the events table.
      later = expected_version(:max)
      earlier = expected_version(:min)

      assert ShhAi.Release.rollback(Integer.to_string(later)) == :ok
      assert migrated_version() == earlier

      assert ShhAi.Release.migrate() == :ok

      assert ShhAi.Release.rollback(Integer.to_string(earlier)) == :ok
      assert migrated_version() == 0
    end

    test "accepts an integer or a numeric string" do
      assert ShhAi.Release.migrate() == :ok

      later = expected_version(:max)
      earlier = expected_version(:min)

      assert ShhAi.Release.rollback(later) == :ok
      assert migrated_version() == earlier

      assert ShhAi.Release.migrate() == :ok
      assert ShhAi.Release.rollback(Integer.to_string(earlier)) == :ok
      assert migrated_version() == 0
    end

    test "rejects a non-numeric version" do
      assert {:error, msg} = ShhAi.Release.rollback("not-a-version")
      assert msg =~ "invalid version"
    end
  end

  # The release session configures the Repo purely via Application env
  # (config/runtime.exs reads AUDIT_DB_PATH). Mirror that here: query
  # through a short-lived instance like the one `with_repo` uses.
  defp put_repo_config(database) do
    Application.put_env(:shh_ai, ShhAi.Repo,
      database: database,
      pool_size: 5,
      journal_mode: :wal
    )
  end

  defp query_on_tmp_repo(query) do
    {:ok, pid} = Repo.start_link(pool_size: 2)

    try do
      Repo.query!(query)
    after
      # Stopping the test instance mirrors `with_repo`'s `:stop` path.
      Supervisor.stop(Repo)
    end
  end

  defp migrated_version do
    # A missing schema_migrations table means version 0 (never migrated).
    result =
      query_on_tmp_repo(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'"
      )

    case result.rows do
      [[_]] ->
        # Table exists — read the max version. An empty table yields
        # MAX() = nil (undone by full rollback) → treat as 0.
        %{rows: [[version]]} =
          query_on_tmp_repo("SELECT MAX(version) FROM schema_migrations")

        version || 0

      [] ->
        0
    end
  end

  defp tables_in_db do
    %Exqlite.Result{rows: rows} =
      query_on_tmp_repo("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")

    Enum.map(rows, fn [name] -> name end)
  end

  defp expected_version(:max), do: @migrations_path |> migration_versions() |> Enum.max()

  defp expected_version(:min), do: @migrations_path |> migration_versions() |> Enum.min()

  defp migration_versions(path) do
    Enum.map(File.ls!(path), fn file ->
      {version, _} =
        file
        |> Path.rootname()
        |> Integer.parse()

      version
    end)
  end
end
