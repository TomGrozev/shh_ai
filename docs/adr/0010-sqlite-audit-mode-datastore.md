# SQLite as Audit Mode datastore

## Status

Accepted

## Context

The privacy proxy's request path runs entirely on the Hot Store (ETS or Redis) — no disk I/O. A separate need exists for operator-facing durability: when `AUDIT_MODE=true`, retain sanitized prompts and PII Mappings for admin review. This is the Cold Store, distinct from the Hot Store.

## Decision

SQLite is the Audit Mode datastore. Ecto + ecto_sqlite3 are used write-only; no boot loading from the Cold Store into the Hot Store; PII columns are encrypted at rest with Cloak (AES-256-GCM); WAL journal mode is enabled.

- **Two tables**: `conversations` (one row per conversation, `mapping` BLOB encrypted, `opted_out` column) and `conversation_messages` (one row per cached message, `sanitized_content` BLOB encrypted, FK to `conversations.conversation_id`, index on `conversation_id`).
- **`ShhAi.Audit.Writer`** GenServer receives fire-and-forget casts from the `Conversation` facade. It early-bails when Audit Mode is off, and additionally checks ETS `opted_out` before writing mapping or message data.
- **Two env vars gate and configure**: `AUDIT_MODE` (bool, default `false`) and `AUDIT_ENCRYPTION_KEY` (Base32-encoded 32 bytes, required iff `AUDIT_MODE=true`). The app fails to start with a clear error if `AUDIT_MODE=true` and the key is missing or empty.
- **Two more env vars configure the store**: `AUDIT_DB_PATH` (default `priv/audit/audit.db`) and `AUDIT_RETENTION_DAYS` (default 30, for the future retention cleanup job).
- **WAL mode** enables concurrent reads (admin queries) without blocking the Writer.
- **The `opted_out` flag** is set via the `X-No-Audit` request header (a future slice plumbs the header into `Store.create/1`). The Writer, ETS tuple shape, and audit `conversations` table are already wired for it.

## Consequences

### Positive

- Zero disk I/O on the request path — the Hot Store (ETS/Redis) is never loaded from SQLite.
- PII is encrypted at rest — plaintext never touches the SQLite file.
- Operator visibility without operational burden — Audit Mode is opt-in, off by default.
- The `AUDIT_ENCRYPTION_KEY` startup check prevents misconfiguration from silently running without encryption.
- WAL mode keeps the SQLite file readable by admin queries while the Writer is writing.

### Negative

- The `:ecto_sqlite3` dependency adds roughly 1.8 MB to the release size.
- SQLite write contention — a single Writer process is intentional; a future concurrent-write requirement would need a design change.
- The `AUDIT_ENCRYPTION_KEY` must be provisioned and rotated out of band; there is no key rotation mechanism in this slice.

### Neutral

- The events table and `Metrics.EventBuffer` integration are out of scope for this ADR; they are a separate vertical slice.
- The `ShhAi.Repo` supervisor is always started (even when `AUDIT_MODE=false`), but the Writer early-bails cheaply when Audit Mode is off.
