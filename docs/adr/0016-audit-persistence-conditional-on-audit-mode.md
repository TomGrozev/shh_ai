# Audit persistence starts only in Audit Mode

## Status

Accepted _(2026-09-06)_ — resolves part of #51 (Deployment artifact) for the standalone 0.1 release. Revises the "Repo is always started" neutral consequence of ADR-0010 (SQLite as Audit Mode datastore).

## Context

ADR-0010 established SQLite (via Ecto + `ecto_sqlite3`) as the Cold Store, written only when `AUDIT_MODE=true`, and noted that `ShhAi.Repo` is nonetheless **always** started, with the Writer early-bailing when audit is off. That is harmless in-process, but it becomes a real cost for the 0.1 deployment artifact: the default, non-audit deployment would carry an Ecto Repo it never uses, run migrations at boot for a database it never writes, and — under the read-only-rootfs container (ADR-0015) — need a writable volume mounted for `AUDIT_DB_PATH` that serves no purpose. The proxy request path never touches the Repo; only the audit write path and the admin dashboard's audit *read* path do.

## Decision

`ShhAi.Repo` becomes a **conditional supervision child, started only when `AUDIT_MODE=true`.** Migrations run via a new `ShhAi.Release.migrate/0`, invoked from the container entrypoint **only when `AUDIT_MODE=true`**. When audit is off there is no Repo, no database, no migration step, and no volume requirement — the default deployment is DB-free, consistent with 0.1's "no required external services".

This requires closing the three dashboard read paths that currently query the Repo regardless of Audit Mode; each must return an empty state when audit is off:

- `Conversations.load_conversations_audit_off/1`
- its `load_slideover_stats/2` `:audit_off` branch
- `Activity.open_slideover_stats/1`

The audit deployment mounts a volume for `AUDIT_DB_PATH`; the entrypoint runs `mkdir_p` + `ShhAi.Release.migrate/0` before boot.

## Consequences

### Positive

- The default (non-audit) deployment ships with no database, no migrations, and no volume to provision — the common case is the simple case.
- The supervision tree honestly reflects runtime shape: the Repo exists iff it is used.
- Removes a read-only-rootfs friction point (no unused writable DB volume when audit is off).

### Negative

- The three dashboard read paths above must gain explicit empty-state handling; without it they crash against an unstarted Repo.
- The supervision tree now branches on configuration, marginally more complex than an unconditional child.

### Neutral

- The audit deployment gains an entrypoint migration step (`ShhAi.Release.migrate/0`) and a mounted `AUDIT_DB_PATH` volume — standard for a stateful opt-in mode.
- Supersedes only the "Repo always started" neutral note in ADR-0010; the rest of ADR-0010 (schema, encryption, Writer semantics) stands.
