defmodule ShhAi.AuditCase do
  @moduledoc """
  Shared setup helper for tests that exercise the Audit Mode data plane
  (`ShhAi.Audit.Writer` and its SQLite sinks). Provides a single
  `setup_audit/0` function that:

    1. Picks a per-test tmp DB path (and removes any prior file).
    2. Sets `AUDIT_MODE=true` and a fresh `AUDIT_ENCRYPTION_KEY`.
    3. Calls `Config.load()` so persistent_term reflects the new env.
    4. Starts the `ShhAi.Audit.Vault` GenServer (needed for encrypt).
    5. Initializes the shared ETS conversation tables.
    6. Points `ShhAi.Repo` at the tmp path with `repo_on_path/1`: with
       AUDIT_MODE on at application boot the supervised child is
       restarted, otherwise a test-owned instance is started
       (a default deployment has no supervised Repo — ADR 0016).
    7. Runs the audit migrations.
    8. Confirms the application-supervised `ShhAi.Audit.Writer` is
       running (no need to start it again — the application
       supervisor already started it).

  Registers an `on_exit` cleanup that restores the env vars it
  touched.

  Also exports `snapshot_env/1` and `restore_env/1` as public
  helpers for tests that need their own env-var snapshot/restore
  without the full `setup_audit/0` stack.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import ShhAi.AuditCase
    end
  end

  alias ShhAi.Audit.Vault
  alias ShhAi.Audit.Writer
  alias ShhAi.Config
  alias ShhAi.Repo

  @doc """
  Sets up the audit data plane for a single test. Returns an empty map
  (use `start_supervised!` for any extra processes the test body needs
  in addition to the Writer). See the `@moduledoc` for the full list
  of side effects.
  """
  def setup_audit do
    snapshot_env([
      "AUDIT_DB_PATH",
      "AUDIT_MODE",
      "AUDIT_ENCRYPTION_KEY"
    ])

    snapshot_repo_config()

    tmp_path =
      Path.join([
        System.tmp_dir!(),
        "shh_ai_audit_test_#{:erlang.unique_integer([:positive])}.db"
      ])

    # Note: We do NOT delete the tmp DB in on_exit. The connection
    # pool from the supervisor-restarted Repo keeps the file open via
    # WAL/SHM sidecars; deleting the file while connections are
    # still alive would cause the NEXT test to fail with "database is
    # locked" / "file not found" depending on timing. We rely on the
    # unique_integer in the path to avoid collisions and let the OS
    # clean up the tmp dir eventually.
    File.rm(tmp_path)

    # Encryption key — slice A's Config.load/0 raises if this is
    # missing/empty when AUDIT_MODE is true.
    key = Base.encode32(:crypto.strong_rand_bytes(32))
    System.put_env("AUDIT_DB_PATH", tmp_path)
    System.put_env("AUDIT_MODE", "true")
    System.put_env("AUDIT_ENCRYPTION_KEY", key)
    Config.load()

    # The Vault GenServer needs to be up — it reads the key in init/1
    # and without an instance `Vault.encrypt/2` will fail.
    start_supervised!(Vault)

    ShhAi.ConversationCase.setup_ets()

    repo_on_path(tmp_path)

    migrations_path = Application.app_dir(:shh_ai, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations_path, :up, all: true, log: false)

    # The Writer is a child of the application supervisor (ADR 0010),
    # so it is already running by the time this setup
    # runs. We deliberately use the supervisor-started instance
    # rather than `start_supervised!/1` to avoid a name collision —
    # the test only needs the process to be alive, not a new one.
    case Process.whereis(Writer) do
      nil -> start_supervised!(Writer)
      _pid -> :ok
    end

    %{}
  end

  @doc """
  Sets up the audit data plane ONCE per test file (use with `setup_all`).
  Creates a single tmp SQLite DB, starts Vault, sets up ETS, restarts
  Repo, and runs migrations. Returns an empty map.

  The tmp_path is stored in the process dictionary under
  `:audit_all_db_path` for cleanup if needed.

  This is the expensive one-time setup. Use `reset_audit_state/0` in
  `setup` blocks to clean up between tests.
  """
  def setup_audit_all do
    snapshot_env([
      "AUDIT_DB_PATH",
      "AUDIT_MODE",
      "AUDIT_ENCRYPTION_KEY"
    ])

    snapshot_repo_config()

    tmp_path =
      Path.join([
        System.tmp_dir!(),
        "shh_ai_audit_all_#{:erlang.unique_integer([:positive])}.db"
      ])

    File.rm(tmp_path)

    key = Base.encode32(:crypto.strong_rand_bytes(32))
    System.put_env("AUDIT_DB_PATH", tmp_path)
    System.put_env("AUDIT_MODE", "true")
    System.put_env("AUDIT_ENCRYPTION_KEY", key)
    Config.load()

    # Start Vault GenServer — use start_supervised! so it's tied to
    # the test process and cleaned up automatically.
    start_supervised!(Vault)

    ShhAi.ConversationCase.setup_ets()

    repo_on_path(tmp_path)

    migrations_path = Application.app_dir(:shh_ai, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations_path, :up, all: true, log: false)

    case Process.whereis(Writer) do
      nil -> start_supervised!(Writer)
      _pid -> :ok
    end

    # Store path in process dictionary for cleanup if needed
    Process.put(:audit_all_db_path, tmp_path)

    %{}
  end

  @doc """
  Resets audit state between tests without restarting Repo or re-running
  migrations. Deletes all rows from audit tables and clears ETS tables.
  Fast (< 5ms) — use in `setup` blocks after `setup_audit_all/0`.
  """
  def reset_audit_state do
    # Delete all rows from audit SQLite tables
    Repo.delete_all("conversations")
    Repo.delete_all("conversation_messages")
    Repo.delete_all("events")

    # Clear ETS tables
    ShhAi.ConversationCase.setup_ets()

    :ok
  end

  @doc """
  Snapshots the given list of environment variable names and registers
  an `on_exit` callback to restore them. Each name should be the
  *uppercase* env-var name (e.g. `"AUDIT_MODE"`).
  """
  @spec snapshot_env([String.t()]) :: :ok
  def snapshot_env(env_var_names) when is_list(env_var_names) do
    original =
      Map.new(env_var_names, fn name ->
        {name, System.get_env(name)}
      end)

    on_exit(fn ->
      for {name, value} <- original do
        if value do
          System.put_env(name, value)
        else
          System.delete_env(name)
        end
      end

      # Config is read from `persistent_term` (e.g. `Config.audit_mode?/0`),
      # so restoring the environment is not enough: without a reload this
      # test's audit state leaks into every test that runs after it — which
      # ADR 0016 makes fatal, since audit-on code paths expect a supervised
      # Repo that a default deployment does not have.
      Config.load()
    end)
  end

  @doc """
  Immediately restores the given env-var map (as returned by a manual
  `System.get_env` snapshot). Useful for one-off tests that need to
  clean up env vars inline without `on_exit`.
  """
  @spec restore_env(%{String.t() => String.t() | nil}) :: :ok
  def restore_env(env_map) when is_map(env_map) do
    for {name, value} <- env_map do
      if value do
        System.put_env(name, value)
      else
        System.delete_env(name)
      end
    end

    :ok
  end

  @doc """
  Points `ShhAi.Repo` at `path` and makes sure an instance is running there.

  With AUDIT_MODE on at application boot the Repo is a supervised child, so
  it is restarted to pick up the new config. With AUDIT_MODE off (the default)
  nothing supervises the Repo — the application is database-free (ADR 0016) —
  so a test-owned instance is started instead.
  """
  def repo_on_path(path) when is_binary(path) do
    Application.put_env(:shh_ai, ShhAi.Repo,
      database: path,
      pool_size: 5,
      journal_mode: :wal
    )

    restart_or_start_repo()
  end

  # Brings a Repo instance up on the tmp path just `put_env`'d: restarting
  # the supervised child when the application owns one, starting a
  # test-owned instance otherwise (ADR 0016).
  defp restart_or_start_repo do
    case Process.whereis(Repo) do
      nil ->
        # Audit Mode was off at application boot: no supervised Repo exists,
        # so the test owns one for its tmp DB (ADR 0016).
        start_supervised!(Repo)

      _pid ->
        restart_supervised_repo()
    end

    # `Ecto.Migrator.run/4` calls `Ecto.Repo.Registry.lookup/1` to map the
    # Repo name to its pid, and it fails with "not a key that exists in the
    # table" if the registry hasn't caught up with the new pid yet.
    wait_for_repo(5_000)
    wait_for_ecto_registry(2_000)
  end

  # Restarts the Repo child of the application supervisor so it picks up the
  # config just `put_env`'d. We use the Supervisor API (terminate_child/2 +
  # restart_child/2) rather than a kill, which trips the default
  # `max_restarts: 3` / `max_seconds: 5` supervisor backoff after a few test
  # cycles and leaves the Repo un-restarted for the rest of the file. The
  # explicit API is deterministic and resets the restart-count on each cycle.
  defp restart_supervised_repo do
    supervisor = Process.whereis(ShhAi.Supervisor) || raise "ShhAi.Supervisor not running"

    :ok = Supervisor.terminate_child(supervisor, Repo)

    # `restart_child/2` re-reads the child spec from the supervisor's
    # children list at the moment of restart — so the database path
    # it picks up is whatever `Application.get_env(:shh_ai, Repo)`
    # returns NOW, i.e. the tmp path we just `put_env`'d.
    {:ok, _pid} = Supervisor.restart_child(supervisor, Repo)
  end

  # Restores `config :shh_ai, ShhAi.Repo` on exit so the harness leaves the
  # application environment as it found it.
  defp snapshot_repo_config do
    original = Application.get_env(:shh_ai, ShhAi.Repo)

    on_exit(fn ->
      if original do
        Application.put_env(:shh_ai, ShhAi.Repo, original)
      else
        Application.delete_env(:shh_ai, ShhAi.Repo)
      end
    end)
  end

  # The Ecto registry is a separate ETS table updated by the
  # `Ecto.Repo` process on `init/2`. After a supervisor restart the
  # Repo pid is new and the registry may not reflect that for a few
  # ms. Poll until `Ecto.Repo.Registry.lookup/1` succeeds.
  defp wait_for_ecto_registry(timeout) do
    if registry_ready?() do
      :ok
    else
      if timeout <= 0 do
        flunk("Ecto.Repo.Registry did not register the Repo within timeout")
      else
        Process.sleep(20)
        wait_for_ecto_registry(timeout - 20)
      end
    end
  end

  defp registry_ready? do
    case Ecto.Repo.Registry.lookup(Repo) do
      %{pid: pid} when is_pid(pid) -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp wait_for_repo(timeout) do
    if Process.whereis(Repo) do
      :ok
    else
      if timeout <= 0 do
        flunk("ShhAi.Repo did not start within timeout")
      else
        Process.sleep(20)
        wait_for_repo(timeout - 20)
      end
    end
  end
end
