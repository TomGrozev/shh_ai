# 02 — Cache policy in PIIPipeline; complete the Conversation facade

> Covering Candidates 2 and 4 combined. The catalogue number is Candidate 2's slot; Candidate 4 is its follow-on.

## Problem

`Sanitizer.sanitize_with_cache/3` is 599 lines of shallow orchestration dressed as a Sanitizer function—it calls `Conversation.lookup_message/2` and `Conversation.cache_message/3`, computes cache deltas internally, and tunnels a 5-tuple return shape through `PIIPipeline` to `ProviderClient`. The Sanitizer's interface is the test surface, and caching is not a PII concern—it is a locality violation dressed as a public function. Separately, the Conversation facade leaks: `PIIPipeline` calls `Store.get_reverse_index/1` directly at line 445 because `Conversation` exposes `get_mapping/1` but not `get_reverse_index/1`. The asymmetry is the leakage across the seam—a `defdelegate` that should exist but doesn't.

## Decision

Extract cache policy from `Sanitizer` into `PIIPipeline`, where the routing decision already lives. `PIIPipeline.sanitize_messages/4` now owns the cache loop: on Turn 1 it calls pure `Sanitizer.sanitize_messages/2` and caches the result; on Turn 2+ it looks up the Message Cache, reuses cached text on hit, merges deltas on miss, and stores new entries. `PIIPipeline` crosses only the Conversation facade—`Store` is never called directly. The return shape changes from a 5-tuple to a `%SanitizationResult{}` struct (typed contract crossing from `PIIPipeline` to `ProviderClient`). On the facade side, `Conversation.get_reverse_index/1` is added as a `defdelegate` symmetric with `get_mapping/1`, closing the leak at line 445. `Conversation.cache_assistant_response/3` stays as-is—it calls `Sanitizer.restore/2` for one well-defined cache-key purpose, a minimal, intentional PII coupling that Candidate 3's `StreamHandler.handle_chunk/3` carries forward in its finalization path.

## Design tree (resolved)

### Candidate 2 — Cache policy in PIIPipeline

1. **Delete `Sanitizer.sanitize_with_cache/3`.** The function disappears. `Sanitizer` returns to 3 pure public functions: `sanitize/2`, `sanitize_messages/2`, `restore/2`. The `sanitize_message_content/3`, `reduce_messages/4`, and `do_sanitize_and_cache/6` helpers are refactored; the cache-aware variant of `do_sanitize_and_cache` moves out with `sanitize_with_cache/3`.

2. **Cache policy lives in `PIIPipeline`.** `PIIPipeline` owns the routing decision (Turn 1 vs Turn 2+), so it owns the cache mechanics. The deepened `sanitize_messages/4` does: (1) look up cache via `Conversation.lookup_message/2`, (2) on miss call pure `Sanitizer.sanitize_messages/2`, (3) on hit reuse cached text + merge deltas, (4) store result via `Conversation.cache_message/3`.

3. **`PIIPipeline` crosses the Conversation facade, not `Store` directly.** After Candidate 4's facade completion, `PIIPipeline`'s only Conversation-related seam is `ShhAi.Conversation`. It does not call `Store` directly.

4. **Return shape: `%SanitizationResult{}` struct.** The current 5-tuple (`{:ok, sanitized_messages, mapping, reverse_index, detection_counts}`) becomes a typed struct. Fields: `sanitized_messages`, `mapping`, `reverse_index`, `detection_counts`. The struct is the contract crossing from `PIIPipeline` to `ProviderClient`. Module location deferred to implementation (`ShhAi.PIIPipeline` or `ShhAi.PII.SanitizationResult`).

5. **`Conversation.cache_assistant_response/3` stays as-is.** It calls `Sanitizer.restore/2` to compute the assistant-response cache key. The restore is a precondition the cache layer needs from the PII layer, not separable PII logic. The cycle is broken: `PIIPipeline` no longer calls `Sanitizer` (which called `Conversation` which called `Sanitizer.restore`). The remaining call is `Conversation → Sanitizer.restore/2` for one well-defined purpose.

### Candidate 4 — Conversation facade completeness

6. **Add `Conversation.get_reverse_index/1`.** Symmetric with `Conversation.get_mapping/1`. Both become `defdelegate` to `Store`. `PIIPipeline`'s line 445 (`Store.get_reverse_index(conversation.conversation_id)`) becomes `Conversation.get_reverse_index(conversation.conversation_id)`.

7. **Keep the 9 `defdelegate` functions.** They save a `Store.` prefix and document the contract. The 3 lifecycle functions (`persist_turn_1`, `finalize_response`, `cache_assistant_response`) are the real interface; the rest is a thin facade. The deepening is the *added* function, not a removal.

8. **No ADR needed.** This is a deepening, not a decision future explorers would re-litigate. The seam is documented in `Conversation`'s `@moduledoc`.

## Module shape

```
   BEFORE (cycle)                    AFTER (broken)

   PIIPipeline                       PIIPipeline
     │                                 │
     │ sanitize_with_cache/3           │ sanitize_messages/4
     ▼                                 │   ├─ lookup: Conversation.lookup_message/2
   Sanitizer                           │   ├─ sanitize: Sanitizer.sanitize_messages/2  ← pure PII
     │   shallow orchestration         │   ├─ merge:   delta application
     │   calls Conversation            │   └─ store:   Conversation.cache_message/3
     ▼         ▲                       │
   Conversation │                       │  returns %SanitizationResult{}
     │          │                      │
     │          │ restore/2            │
     ▼          │                      │
   Store    Sanitizer ──┐              │
     ▲                  │              │
     │  line 445        │              ▼
     │  LEAK            │            Conversation  ← complete facade
   PIIPipeline ─────────┘              │
                                       │  get_mapping/1    (defdelegate)
                                       │  get_reverse_index/1  (defdelegate) ← NEW
                                       │  lookup_message/2
                                       │  cache_message/3
                                       │  persist_turn_1
                                       │  finalize_response
                                       │  cache_assistant_response/3
                                       │     │
                                       │     │ restore/2  ← minimal, intentional coupling
                                       │     ▼
                                       │  Sanitizer (read-only, one purpose)

   The cycle Sanitizer → Conversation → Sanitizer.restore DISAPPEARS.
   The arrow Conversation → Sanitizer.restore/2 REMAINS (one caller, one purpose).
```

Three-module stack after deepening:

```
   ┌─────────────────────────────────────────────┐
   │  Sanitizer (pure PII)                       │
   │  sanitize/2, sanitize_messages/2, restore/2 │
   │  No cache knowledge. No Conversation calls. │
   └─────────────────────┬───────────────────────┘
                         │ called by PIIPipeline (sanitize)
                         │ called by Conversation (restore, cache key only)
                         │
   ┌─────────────────────▼───────────────────────┐
   │  PIIPipeline (orchestration + cache policy) │
   │  sanitize_messages/4                        │
   │  → Sanitizer.sanitize_messages/2 (pure PII) │
   │  → Conversation.lookup_message/2 (cache)    │
   │  → Conversation.cache_message/3 (cache)     │
   │  returns %SanitizationResult{}              │
   └─────────────────────┬───────────────────────┘
                         │ typed contract crossing to ProviderClient
                         │
   ┌─────────────────────▼───────────────────────┐
   │  Conversation (lifecycle + cache primitives)│
   │  persist_turn_1, finalize_response,         │
   │  cache_assistant_response                   │
   │  defdelegate → Store for 10 CRUD functions  │
   │  calls Sanitizer.restore/2 (cache key only) │
   └─────────────────────┬───────────────────────┘
                         │
   ┌─────────────────────▼───────────────────────┐
   │  Store (ETS/Redis)                          │
   │  get_mapping/1, set_mapping/3,              │
   │  get_reverse_index/1, set_reverse_index/3,  │
   │  lookup_message/2, cache_message/3, etc.    │
   └─────────────────────────────────────────────┘
```

## Files affected

- **`lib/shh_ai/pii/sanitizer.ex`** — `sanitize_with_cache/3` deleted; `do_sanitize_and_cache/6` deleted; `sanitize_message_content/3` and `reduce_messages/4` refactored to serve the 3 pure public functions (`sanitize/2`, `sanitize_messages/2`, `restore/2`). The module's interface shrinks to the PII seam.
- **`lib/shh_ai/pii_pipeline.ex`** — `sanitize_messages/4` now owns the cache loop: three-phase pipeline (lookup, sanitize-or-reuse, store). Calls `Conversation` facade for cache ops, `Sanitizer` for pure PII work. Returns `%SanitizationResult{}`. Line 445's `Store.get_reverse_index/1` direct call replaced with `Conversation.get_reverse_index/1`.
- **`lib/shh_ai/conversation.ex`** — `get_reverse_index/1` added as `defdelegate` to `Store`, symmetric with `get_mapping/1`. `@moduledoc` updated to document the completed facade seam. No other changes.
- **`lib/shh_ai/provider_client/stream_handler.ex`** — Candidate 3 dependency: finalization path still calls `Conversation.cache_assistant_response/3`, but the PII info arrives as a field on `%SanitizationResult{}`, not as a 5-tuple element. Unpacking changes from positional to named access.
- **`test/shh_ai/pii/sanitizer_test.exs`** — `sanitize_with_cache/3` tests deleted or migrated to PIIPipeline test suite. Remaining `sanitize/2` and `sanitize_messages/2` tests no longer need ETS setup—the interface is pure.
- **`test/shh_ai/pii_pipeline_test.exs`** — New or expanded tests: cache hit path (pre-cached message returns cached result without calling `Sanitizer.sanitize_messages/2`), cache miss path (uncached message sanitized and stored), delta merge path (message with one new PII entity reuses cached text + adds one placeholder). `%SanitizationResult{}` struct asserted for field presence and types.
- **`test/shh_ai/conversation_test.exs`** — One trivial test: `get_reverse_index/1` delegates correctly to `Store` and returns the expected Reverse Index shape.
- **`test/shh_ai/provider_client/stream_handler_test.exs`** — Updated for `%SanitizationResult{}` struct unpacking in the finalization path. Named field access replaces positional tuple destructuring.

## Tests

- Sanitizer tests become pure—`sanitize/2` and `sanitize_messages/2` accept text and a Mapping, return sanitized text. No ETS, no cache, no `Conversation` mock. The interface is the test surface: call `sanitize_messages/2` with messages and a Mapping, assert sanitized output. That's the whole test.
- Cache-hit, cache-miss, and delta-merge tests move from the Sanitizer test suite to the PIIPipeline test suite. `PIIPipeline.sanitize_messages/4` is the interface under test; the test sets up a pre-cached entry via `Conversation.cache_message/3`, then calls `sanitize_messages/4` and asserts the result struct contains reused cached text (hit) or fresh sanitized text (miss). The Sanitizer is a pure dependency—mock or real, the test doesn't couple to it.
- Conversation tests gain a single `get_reverse_index/1` delegation test—trivial, it's a `defdelegate`. The test verifies the facade seam is complete.
- `StreamHandler` tests updating for the `%SanitizationResult{}` struct: wherever the finalization path unpacked a 5-tuple, it now accesses named struct fields. The compiler catches mismatches—a typed contract across the seam is the test surface.

## Cross-references

- **`docs/architecture/03-streaming-handler.md`** — Candidate 3's `StreamHandler.handle_chunk/3` is a downstream consumer of the new `%SanitizationResult{}` struct. The `pii_info` field (formerly a 5-tuple element) is now a named field on the struct; `StreamHandler`'s finalization path unpacks it accordingly.
- **`docs/architecture/05-stream-accumulator.md`** — Candidate 5 is independent. No overlap. The `Accumulator` struct carries per-chunk state for `StreamHandler`; it does not touch the Message Cache or the `SanitizationResult` struct.
- **`docs/architecture/01-sse-parser.md`** — Candidate 1 deepened the SSE seam. No overlap with caching or facade work.

## Out of scope

- The exact struct module location (`ShhAi.PIIPipeline` vs `ShhAi.PII.SanitizationResult`) is deferred to implementation. Both are valid homes for a typed contract crossing from `PIIPipeline` to `ProviderClient`.
- The 9 `defdelegate` pass-throughs in `Conversation` are kept. No sub-module split. They document the contract and save a `Store.` prefix at each call site.
- The 3 lifecycle functions (`persist_turn_1`, `finalize_response`, `cache_assistant_response`) are the real `Conversation` interface—not flagged for change. They are the deepened seam.
- No ADR needed. This is a deepening of existing modules and a typed-contract change. Future explorers would not re-litigate "should cache policy live where the routing decision lives" or "should the facade expose symmetric functions."

## Status

> Status: Resolved — implemented in issues #13, #15, #17, #19. Cache policy moved to `PIIPipeline`; `Sanitizer` reduced to pure functions; `%SanitizationResult{}` typed return; `Conversation.get_reverse_index/1` defdelegate closes the facade seam.
