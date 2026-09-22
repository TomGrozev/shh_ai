defmodule ShhAi.Release do
  @moduledoc """
  Release-time tasks for ShhAi, run without Mix inside a production
  release (`bin/shh_ai eval ShhAi.Release.migrate` or `bin/migrate`).

  The only database in ShhAi is the Audit Mode store (ShhAi.Repo,
  SQLite — ADR 0010). Since ADR 0016 the Repo is a conditional
  supervision child: it exists only when AUDIT_MODE is on, and a
  default deployment is database-free. Migrations honour the same
  conditionality: `migrate/0` is a no-op when AUDIT_MODE is off, so
  the container entrypoint does not need its own env check — an
  audit-off deployment cannot migrate a database it does not have.

  See ADR 0015 (deployment artifact) and ADR 0016 (audit persistence
  conditional on Audit Mode).
  """

  @app :shh_ai
  @migrations_path "priv/repo/migrations"

  @doc """
  Runs pending audit migrations.

  No-op when AUDIT_MODE is off (ADR 0016) — there is no database to
  migrate. With AUDIT_MODE on, starts a short-lived Repo instance for
  the migration and runs all pending migrations from the release's
  `priv/repo/migrations` directory.

  Returns `:ok` on success, or `{:error, reason}` when a repo could
  not be brought up. Migration/DDL errors raise (fail loudly —
  migrations must never silently "succeed"); under `bin/migrate`
  (`bin/shh_ai eval`) that exit code is non-zero.
  """
  @spec migrate() :: :ok | {:error, term()}
  def migrate do
    if audit_mode_on?() do
      run(fn repo -> Ecto.Migrator.run(repo, migrations_path(), :up, all: true) end)
    else
      :ok
    end
  end

  @doc """
  Rolls the audit database back to `version`.
  Audit Mode must be on (see `migrate/0`). Same error contract as
  `migrate/0`.
  """
  @spec rollback(String.t() | non_neg_integer()) :: :ok | {:error, term()}
  def rollback(version) when is_binary(version) do
    case Integer.parse(version) do
      {int, ""} -> rollback(int)
      _ -> {:error, "invalid version #{inspect(version)}"}
    end
  end

  def rollback(version) when is_integer(version) do
    if audit_mode_on?() do
      run(fn repo -> Ecto.Migrator.run(repo, migrations_path(), :down, to: version) end)
    else
      :ok
    end
  end

  # Same audit-mode resolution as the application boot path: load the
  # config, then consult it. Loading also performs the
  # "AUDIT_ENCRYPTION_KEY required with audit on" check, so migrations
  # fail as loudly as boot would on a misconfigured audit deployment.
  defp audit_mode_on? do
    ShhAi.Config.load()
    ShhAi.Config.audit_mode?()
  end

  # Starts a short-lived Repo instance for the migration and runs `fun`
  # against it, translating `Ecto.Migrator.with_repo/2`'s tuples to
  # `:ok | {:error, term()}`.
  defp run(fun) do
    load_app()

    case Ecto.Migrator.with_repo(ShhAi.Repo, fun) do
      {:ok, _, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Resolves the migrations directory inside the shipped release, not
  # the (irrelevant, absent at runtime) build-time cwd.
  defp migrations_path do
    path = Application.app_dir(@app, @migrations_path)

    unless File.dir?(path) do
      raise "audit migrations not found at #{path}"
    end

    path
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
