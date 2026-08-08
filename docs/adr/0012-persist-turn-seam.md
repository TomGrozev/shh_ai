# Persist-turn seam owns all durable writes; facade methods become pure ETS state

## Status

Accepted _(2026-07-05)_

## Context

ADR-0007 established conversation-scoped tracking: fingerprint-derived UUID v5 identity, an accumulated Mapping keyed by conversation, a Message Cache, and the Hot Store / Audit Writer split. ADR-0010 layered Audit Mode on top by adding the SQLite `conversations` and `conversation_messages` tables and the `Audit Writer` GenServer.

The implementation glued two unrelated concerns onto the same ETS-state-mutation calls:

- `Conversation.cache_message/4` writes to the `:conversation_message_cache` ETS table AND casts `AuditWriter.write_message/4`.
- `Conversation.add_mapping/4` writes to the `:conversation_mappings` / `:conversation_reverse_index` tables AND casts `AuditWriter.update_mapping/3`.

Both casts are gated by `Config.audit_mode?()` and fire-and-forget. The caller has no visibility that a durability write is being triggered — the function name advertises only the ETS state mutation.

### The defect this produced

Turn 1 of a new conversation intentionally bypasses the PII Pipeline's `reduce_with_cache` loop (`pii_pipeline.ex:175-178`) because the `conversation_id` does not exist yet — it is derived from the first-exchange fingerprint only after the response returns. The bypass is correct *for the cache* (no conversation to cache against), but because `cache_message` was the same call that triggered the audit message write, the bypass also skipped the audit write. **Zero `conversation_messages` rows are written for Turn 1 user messages**, so the dashboard's `first_user_message_for_conversations` query finds nothing and every conversation shows "No message preview available."

### Guiding principle

> A facade method should either mutate ETS state OR durably write to the Cold Store — never both.

When a method does both, the durability write becomes a hidden side effect of a perf optimization. Skipping the optimization for a legitimate reason (no `conversation_id` available) silently skips the durability write — an unrelated concern glued to the same lifecycle moment.

### Other findings this refactor closes while the seam is open

- **#2 Streaming vs non-streaming divergence** — the streaming path eagerly caches the assistant response via `cache_assistant_response`; the non-streaming path lazily caches on the next turn. The "response complete → persist + cache" semantics diverge across two modules.
- **#3 `new?` branching duplicated across callers** — `StreamHandler` and `ProviderClient` both branch on `ctx.conversation.new?` between `persist_turn_1` and `finalize_response`, in lockstep.
- **#4 `audit_message_extract` opaque-tuple contract** — `cache_message` destructures `{:user_message, sanitized_text, _mapping, _ri, _counts}` / `{:assistant_message, pre_restored_content}` from tuples built in `PIIPipeline` and `cache_assistant_response` with no shared type. A shape change silently produces `"unknown"`-role audit rows.
- **#5 `cache_assistant_response` calls `PII.Sanitizer.restore`** — the Conversation facade reaches into the PII layer, creating a bidirectional dependency.
- **#8 Raw `openai_body` carried through response handlers** — the unsanitized request body is held on `RequestContext` past prepare-time purely so `persist_turn_1` / `finalize_response` can re-extract messages for fingerprinting. The raw-PII surface is wider than necessary.
- **#9 `add_mapping` hidden audit cast** — same double-duty antipattern as `cache_message`, for the Mapping path.
- The **original bug** itself (Turn 1 user messages missing from the audit DB).

## Decision

### 1. A single `persist_turn` seam owns all durable writes for a turn

Introduce `Conversation.persist_turn/1` (keyword-list form, NOT `persist_turn_1` — unified across Turn 1 and Turn 2+). It is the **only** entry point that performs Cold Store writes. It receives everything it needs from the caller as already-extracted values; it does not call `PII.Sanitizer`, does not re-derive the `conversation_id`, and does not pattern-match on PII-internal tuple shapes.

```elixir
@spec persist_turn(keyword()) :: {:ok, conversation_id :: String.t()} | {:error, term()}
```

Inputs (no new `%TurnRecord{}` struct — explicitly rejected; the seam takes its args directly):

| Argument | Type | Source |
|---|---|---|
| `:conversation_id` | `String.t()` | **Derived upstream by the caller** via `Fingerprinter.fingerprint_messages([first_user, first_assistant])` → `Fingerprinter.derive_conversation_id/1`. Never computed inside the seam. |
| `:is_new` | `boolean()` | The `new?` flag from the request context. Dispatches to the Turn 1 vs Turn 2+ sub-paths internally. |
| `:conversation` | `%Conversation{}` | The hot-store record (for `source_provider`, `provider_conversation_id`, `opted_out`, `created_at`). `mapping`/`reverse_index` fields on the struct are ignored. |
| `:sanitized_messages` | `[%{role: binary, content: binary}, ...]` | Plain OpenAI-canonical maps, already sanitized by the PII Pipeline. **Only** sanitized content crosses the seam — never raw PII. Includes user messages and the assistant message for this turn. |
| `:assistant_message_hash` | `String.t()` | Hash of the restored assistant content (what the client saw), computed upstream. Used as the Message Cache key so the next turn hits cache for the assistant response. |
| `:mapping_delta` | `map()` | `{placeholder → original}` deltas newly detected this turn (guaranteed sanitized — placeholders only). Empty map if no new PII. |
| `:reverse_index_delta` | `map()` | `{{original, type} → placeholder}` deltas for the new mapping. |
| `:request_time` | `NaiveDateTime.t()` | The timestamp for all Cold Store rows in this turn. |

The seam never receives raw `openai_body` and never receives raw user messages — it cannot leak PII even if a future contributor adds logging inside it.

Behavior, in order:

1. **Hot-store conversation row.** Turn 1: `Store.create/1` with the derived `conversation_id` and `fingerprint_hash` (now derived upstream — no longer fingerprinted inside the seam). Turn 2+: `Store.touch/1` (TTL reset) only.
2. **Hot-store mapping accumulation.** `Store.add_mapping/3` when `map_size(mapping_delta) > 0`. No audit cast.
3. **Hot-store message cache.** `Store.cache_message/3` for each user message (key = hash of reconstructed content) and once for the assistant message (key = `:assistant_message_hash`). No audit cast.
4. **Cold-store conversation row (Turn 1 only).** `AuditWriter.write_conversation/2`, gated by `Config.audit_mode?()`. The opt-out path stays routed through here.
5. **Cold-store message rows.** `AuditWriter.write_message/4` for each user message in `sanitized_messages` and once for the assistant message. Gated by `Config.audit_mode?()`. Roles come from `m.role` on the input maps — `audit_message_extract` is eliminated.
6. **Cold-store mapping merge (Turn 2+ with delta only).** `AuditWriter.update_mapping/3` when `map_size(mapping_delta) > 0` and `is_new == false`. Gated by `Config.audit_mode?()`. On Turn 1 the mapping is part of `write_conversation` (preserved current behavior).

All six durability paths share the same `Config.audit_mode?()` gate; the existing double-gating in `AuditWriter` handlers stays as defense-in-depth.

### 2. Fingerprinting and `conversation_id` derivation move upstream

The response handlers (`stream_handler.ex` and `provider_client.ex`) already build `full_messages` at response completion. They now additionally:

1. Call `Fingerprinter.fingerprint_messages([hd(full_messages), Enum.at(full_messages, 1)])` — the **first-exchange** fingerprint.
2. Derive `conversation_id = Fingerprinter.derive_conversation_id(fingerprint)`.
3. Pass `conversation_id` into `persist_turn`.

The fingerprint computation is the only place raw user/assistant content is touched downstream of prepare-time.

### 3. Both completion paths route through the single seam

- **Streaming** (`stream_handler.ex`): on response completion, gather `sanitized_messages` (from `ctx.sanitized_messages` plus the streamed assistant response), the mapping delta, and `request_time`, then call `persist_turn`. `cache_assistant_response` and the `new?`-branched `persist_turn_1`/`finalize_response` calls are deleted from this module.
- **Non-streaming** (`provider_client.ex`): on `handle_request_success`, do the same. The "non-streaming lazily caches the assistant response on the next turn" divergence is removed — both paths persist the assistant message in the same `persist_turn` call.

### 4. The facade loses its double-duty methods

- `Conversation.cache_message/4` → becomes a private ETS write inside `persist_turn` (or `Store.cache_message/3` only, no public wrapper). The `AuditWriter.write_message` cast is gone from it.
- `Conversation.add_mapping/4` → same — pure ETS write inside `persist_turn`. The `AuditWriter.update_mapping` cast is gone from it.
- `Conversation.cache_assistant_response/4` → deleted entirely. The restore and hash computation it did (`Sanitizer.restore` + `Fingerprinter.hash_message`) move upstream to the response handler.
- `Conversation.persist_turn_1` and `Conversation.finalize_response` → deleted, replaced by `persist_turn`.
- `Conversation.audit_message_extract/1` → deleted. The opaque tuple shapes `{:user_message, ...}` / `{:assistant_message, ...}` are no longer the transport shape across the seam — `sanitized_messages` is plain OpenAI canonical maps.
- `Conversation.cast_audit_write_conversation/5` → folded into `persist_turn` (or kept as a private helper called only from within `persist_turn`); not callable from outside the seam.

### 5. The PII Pipeline stops triggering audit writes

`PIIPipeline.reduce_with_cache` and `handle_message_with_cache` currently call `Conversation.cache_message` purely to populate the ETS Message Cache. With the audit cast removed from `cache_message`, this loop becomes a pure ETS-cache optimization — no durability side effect. `maybe_update_conversation` calls `Conversation.add_mapping` purely to seed the ETS mapping; same — pure ETS.

This means `reduce_with_cache` no longer needs to be skipped on Turn 1 *for audit reasons*; it can still be skipped *for cache reasons* (no `conversation_id` yet). The audit writes are no longer attached to it.

### 6. `RequestContext` narrows

`provider_client.ex` currently stores `openai_body` (raw, unsanitized) so `handle_request_success` can re-extract messages for fingerprinting. With fingerprinting moved upstream to the response handler (where `full_messages` is already built from the same `openai_body`), `openai_body` can be dropped from `RequestContext` *across the prepare→response boundary*, OR narrowed to only the two messages fingerprinting needs. The sanitized message list (`sanitized_messages`) is carried forward so it reaches `persist_turn`.

## Out of scope (separate tickets)

- **#1** — `Fingerprinter.fingerprint_messages` silently discards messages beyond the first two. The first-exchange-only contract should be made explicit.
- **#6** — `%Conversation{}` struct carries stale `mapping`/`reverse_index` fields.
- **#7** — synthetic `%Conversation{}` transport in `cast_audit_write_conversation`.
- **#10** — `reconstruct_sanitized_body` knows body shapes; should be encapsulated by `SanitizationResult`.
- **#11** — `process_typed_events` arity-overload duplication (SSE restore; unrelated concern).

## Consequences

### Positive

- **The original bug is fixed structurally**, not patched. Turn 1 user messages reach the Cold Store because `persist_turn` writes them unconditionally — there is no cache-loop bypass to skip them by accident.
- **The double-duty antipattern is eliminated** for both `cache_message` and `add_mapping`. Future contributors cannot repeat the same class of bug.
- **Streaming and non-streaming converge** on one seam; the "complete response → persist + cache" semantics live in one function.
- **`new?` dispatch is encapsulated** in `persist_turn`; the two callers stop branching in lockstep.
- **PII dependency becomes one-directional** — `PII.Sanitizer` no longer imports the Conversation facade for restore; the response handler carries the result into the seam.
- **Raw-PII surface narrows** to the fingerprint call site and disappears from `RequestContext` downstream of prepare-time.
- **The opaque-tuple transport contract is gone** — `audit_message_extract`'s implicit three-module coupling is replaced by plain maps with `role`/`content`.

### Negative

- **`persist_turn` has a wide keyword-arg list.** A `%TurnRecord{}` struct was considered and explicitly rejected to avoid introducing a type whose only consumer is one function. The trade-off is login-readable keyword args at two call sites.
- **The seam does all six durable paths in one function.** Separating them was considered (e.g. `persist_messages/3` called from `persist_turn`); rejected as premature — the steps share the same lifecycle moment and the same `request_time`. If a future requirement splits them, the seam is the right place to extract sub-functions from.
- **`finalize_response` is deleted**, which removes the (already no-op) `Store.update_fingerprint/2` call. This is fine — on Turn 2+, the fingerprint was written on Turn 1 and `Store.touch/1` resets the TTL. The fingerprint hash does not change.
- **Two response handlers now both compute the fingerprint.** ~2 lines of duplication. Acceptable; if a third handler appears, factor a helper.

### Neutral

- **`conversation_messages` stays display-only.** No operational code reads it; this refactor does not change that. The Message Cache (ETS) and the Cold Store remain separate stores with separate consumers.
- **Audit Mode double-gating stays.** The seam gates `Config.audit_mode?()` before each cast; the Writer gates it again on receipt. Defense-in-depth unchanged.
- **Opt-out path stays inside the seam.** `Conversation.opted_out → AuditWriter.opt_out/1` continues to flow through `persist_turn`'s audit-write path (Turn 1) and the existing `set_opted_out` path. Unchanged.

## Tests

- **Turn 1:** assert `persist_turn(is_new: true, ...)` produces a `conversations` row AND one `conversation_messages` row per user message AND one for the assistant — after `:sync`.
- **Turn 2+:** assert `persist_turn(is_new: false, ...)` produces NO new `conversations` row, one `conversation_messages` row per user message, and `AuditWriter.update_mapping` was cast when `mapping_delta` is non-empty.
- **No audit cast from `cache_message` or `add_mapping`.** After deletion, there is no public `cache_message`/`add_mapping` to call — but the existing test suite asserting `AuditWriter` was cast from these facades must be deleted/updated, and a test asserting the cast only comes from `persist_turn` is added.
- **Audit Mode OFF:** assert `persist_turn` produces zero Cold Store writes (the gate short-circuits).
- **Opt-out:** assert `persist_turn` with `conversation.opted_out == true` writes a tombstone and does not write messages — preserves current behavior.
- **Dashboard regression:** the existing integration check that `first_user_message_for_conversations` returns a preview after a Turn 1 request — closes the original bug at the UI boundary.