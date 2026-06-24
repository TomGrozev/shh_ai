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
    6. Restarts `ShhAi.Repo` bound to the tmp path (using the
       Supervisor API instead of slice A's `Process.exit` pattern —
       the kill-and-restart trips the default supervisor backoff
       after a few test cycles).
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

    Application.put_env(:shh_ai, ShhAi.Repo,
      database: tmp_path,
      pool_size: 5,
      journal_mode: :wal
    )

    restart_repo_to_pick_up_config()

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

  # Restarts the Repo child of the application supervisor so it picks
  # up the test tmp path that was just set via `Application.put_env`.
  #
  # We use the Supervisor API (terminate_child/2 + restart_child/2)
  # rather than the `Process.exit(pid, :kill)` pattern from
  # `test/shh_ai/repo_test.exs` because the latter trips the default
  # `max_restarts: 3` / `max_seconds: 5` supervisor backoff after a
  # few test cycles, leaving the Repo un-restarted for the rest of
  # the file. The explicit API is deterministic and resets the
  # restart-count on each cycle.
  defp restart_repo_to_pick_up_config do
    supervisor = Process.whereis(ShhAi.Supervisor) || raise "ShhAi.Supervisor not running"

    if Process.whereis(Repo) do
      :ok = Supervisor.terminate_child(supervisor, Repo)
    end

    # `restart_child/2` re-reads the child spec from the supervisor's
    # children list at the moment of restart — so the database path
    # it picks up is whatever `Application.get_env(:shh_ai, Repo)`
    # returns NOW, i.e. the tmp path we just `put_env`'d.
    {:ok, _pid} = Supervisor.restart_child(supervisor, Repo)

    # Wait for the Repo to be both registered AND have a working
    # connection pool. `Ecto.Migrator.run/4` calls
    # `Ecto.Repo.Registry.lookup/1` to map the Repo name to its pid,
    # and it fails with "not a key that exists in the table" if the
    # registry hasn't been updated yet. A short sleep after
    # `restart_child/2` covers the worst-case race between the
    # supervisor's restart signal and the Ecto registry's update.
    wait_for_repo(5_000)
    wait_for_ecto_registry(2_000)
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
