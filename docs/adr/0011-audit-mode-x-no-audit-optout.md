# Audit Mode and X-No-Audit opt-out

## Status

Accepted

## Date

2026-06-25

## Context

Audit Mode is OFF by default, ON via `AUDIT_MODE=true` env var (boot-time). When ON, the `ShhAi.Audit.Writer` GenServer retains sanitized prompts and PII Mappings in an encrypted SQLite database for admin review.

The `X-No-Audit` HTTP header lets a client opt out of retention for the conversation their request belongs to. The opt-out is per-conversation (sticky, retroactive) — when a request carries this header, the conversation is retroactively excluded from Audit Mode: a tombstone row is written and existing messages are deleted.

## Decision

When a request carries the `X-No-Audit` header:

1. The Provider Client detects the header (case-insensitive) and passes `opted_out: true` through to `Conversation.find_or_create/2`.
2. The Conversation module reads `opted_out` from attrs and sets it on the struct. For new conversations, the flag is written to ETS via `Store.create/1`. For existing conversations, `Store.set_opted_out/1` transitions the ETS flag from false → true (sticky).
3. The Conversation module casts `{:opt_out, conversation_id}` to the Audit Writer (both from `find_or_create` for existing conversations and from `cast_audit_write_conversation` for newly-persisted conversations).
4. The Writer executes an UPDATE on the `conversations` table: `opted_out = 1, mapping = NULL`. This creates or updates the tombstone. The Writer also DELETEs all `conversation_messages` rows for that conversation.
5. Future `write_mapping` and `write_message` casts for that conversation are skipped by the Writer. The Writer first consults ETS via `Store.get_opted_out/1`; if `false`, it performs a sync SQLite read of the `opted_out` column to detect a reactivation tombstone (see [Reactivation across restarts](#reactivation-across-restarts) below).

### Sticky behaviour

Once `opted_out = true` in ETS, it can never be set back to `false`. The `Store.set_opted_out/1` function only transitions false → true. The ETS `create/1` reads `opted_out` from the struct (which defaults to `false`). Neither `touch/1` nor `update_fingerprint/2` clobbers the opt-out state.

### Tombstone

A tombstone is a row in the audit `conversations` table where `opted_out = true` and `mapping = NULL`. The tombstone preserves the opt-out state and conversation_id while erasing the prior mapping. The `write_conversation` UPSERT carries `opted_out: true` from the conversation struct, so the row is created with the flag set. The `opt_out` cast then clears the mapping.

### Reactivation across restarts

When the ETS conversation entry expires (TTL or process restart), the `opted_out` flag is lost from the Hot Store. A new request with the same fingerprint creates a fresh ETS entry with `opted_out = false`. However, the tombstone may still exist in SQLite — the Cold Store is never deleted on ETS expiry.

To handle this, `ShhAi.Audit.Writer` performs a **sync SQLite read** on the `opted_out` column before writing, but only when ETS has `opted_out = false` (the reactivation path). When ETS already has `opted_out = true`, the Writer early-bails cheaply with no sync read.

The sync read flow:
1. ETS has `opted_out = false` → Writer queries `SELECT opted_out FROM conversations WHERE conversation_id = ?`.
2. If SQLite returns `opted_out = true` (tombstone exists), Writer calls `Store.mark_opted_out/1` to flip ETS to `true` and skips the write.
3. If SQLite returns no row or `opted_out = false`, Writer proceeds with the write as normal.

The new `Store.mark_opted_out/1` callback unconditionally sets `opted_out = true` on an existing ETS/Redis entry. Unlike `set_opted_out/1` (which checks the current value for sticky semantics), `mark_opted_out/1` is called only when a confirmed persisted tombstone exists, so it always writes `true`.

**Latency tradeoff**: the sync read adds a SQLite read to the write path for reactivated conversations. This is acknowledged as a known cost; reactivation is rare and the read can later be optimised via an ETS cache of opted-out states.

## Consequences

### Positive

- Per-conversation opt-out is a single HTTP header — no client-side state management needed.
- Retroactive: the opt-out applies to the entire conversation, not just the current request.
- Sticky: once opted out, subsequent requests on the same conversation are no-ops for the Writer.
- Defence-in-depth: the Writer checks `opted_out` before every mapping/message write.

### Negative

- The opt-out is async (fire-and-forget cast) — there is a brief window where messages may be written before the tombstone takes effect. This is acceptable because the Writer's FIFO mailbox ordering ensures the tombstone is processed before subsequent writes.
- For Turn 1 conversations, the `opt_out` cast may arrive before the `write_conversation` row exists (different mailbox paths). The `cast_audit_write_conversation` function also casts `opt_out` to handle this case.

### Neutral

- No events table exists in the current schema, so the cascade delete only covers `conversation_messages`.
- The Redis backend mirrors the ETS opt-out semantics for multi-node parity.
