# Conversation-scoped tracking replaces per-request sessions

## Status

Accepted *(Amended 2026-06-08)*

## Context

The proxy previously created a per-request Session (via SessionStore) that held a PII mapping for a single request/response cycle. The mapping is created when PII is detected, used to restore placeholders in the response, and deleted immediately after. This means:

1. **Repeated sanitization**: Each request re-sanitizes the entire messages array from scratch, even though prior-turn messages were already sanitized in earlier requests.
2. **No placeholder reuse**: The same PII entity (e.g., "alice@corp.com") gets a new placeholder each turn (<EMAIL_1> in turn 1, <EMAIL_2> in turn 2), causing inconsistency in what the LLM sees.
3. **No conversation visibility**: The dashboard shows individual requests with no grouping. Admins cannot see which requests belong to the same multi-turn interaction.

Agentic clients (AI agents making multiple tool calls) and multi-turn chat applications both need placeholder consistency and content caching across turns.

## Decision

Replace per-request Sessions with **Conversations** — a grouping of related proxy requests that share an accumulated PII mapping and message cache.

### Conversation identity

All conversations are identified by **message fingerprinting**. The conversation ID is a deterministic UUID v5 derived from the fingerprint hash. Provider-supplied identifiers (`thread_id`, `conversation`) are stored as metadata on the Conversation record but are not used as lookup keys.

- **Message fingerprinting**: Hash each message using SHA-256, then hash the ordered list of per-message hashes to produce a composite fingerprint. Messages are converted to canonical (OpenAI) format before hashing so cross-provider conversations work naturally.
- **Deterministic UUID v5**: `conversation_id = UUIDv5(namespace_uuid, fingerprint_hash)`. Same fingerprint → same conversation ID across all providers. No `source_provider` in the derivation — conversations are provider-agnostic.
- **Turn 1 (no prior messages)**: No fingerprint is available during the request. A temporary UUID v4 is assigned. After the response returns, the full fingerprint (including the assistant response) is computed, the UUID v5 is derived, and the conversation record is migrated from the UUID v4 key to the UUID v5 key.
- **Turn 2+**: Prior messages exist. Fingerprint is computed from `messages[0..-2]`, UUID v5 derived, and the conversation is found via O(1) ETS lookup on the derived ID.
- **Provider conversation IDs as metadata**: When a client sends `thread_id` (OpenAI Threads/Assistants) or `conversation` (OpenAI Responses API), the value is stored as `provider_conversation_id` on the Conversation record for dashboard display and observability. It is not used for lookups.
- **`previous_response_id` is dropped**: This is a parent pointer to a specific prior response in the OpenAI Responses API, not a stable conversation identifier. Using it causes a new conversation to be created for each turn. It is ignored.
- No custom headers (e.g., `X-Conversation-ID`) — fingerprinting covers all cases without client changes.

### Accumulated mapping

- Each Conversation owns a **Mapping** (`placeholder → original`) that grows across requests.
- A **Reverse Index** (`{original_value, type} → placeholder`) enables O(1) lookup for placeholder reuse when PII is detected again.
- When the sanitizer encounters PII, it checks the reverse index first. If found, the existing placeholder is reused. If not, a new placeholder is assigned and both structures are updated.
- `ets.insert_new/2` is used for atomic placeholder assignment — first writer wins, second writer reuses.

### Message cache

- Each Conversation caches **sanitized versions of messages** it has already processed, keyed by the hash of the unsanitized canonical-format content.
- Both user messages and assistant responses are cached.
- Assistant streaming responses are buffered during streaming and cached as a single entry after the `[DONE]` marker.
- On each new request, messages with cache hits skip sanitization entirely. Only new messages (cache misses) are sanitized.

### Lifecycle

- **Start**: Turn 1 always starts a new Conversation with a temporary UUID v4. After the response returns, the fingerprint is computed and the conversation is migrated to its deterministic UUID v5. Turn 2+ finds existing Conversations via fingerprint-derived UUID v5.
- **End**: Conversations expire via a **sliding TTL** (default 1 hour, configurable). Each new request within a Conversation resets the TTL clock. No explicit "end" signal.
- **On expiry**: The Conversation and all its cached data are deleted. The next request starts a fresh Conversation with fresh placeholders.

### Modified history

- If a client edits, trims, or reorders the message history between turns, the fingerprint won't match any existing Conversation. A new Conversation starts. This is an accepted limitation — the cost is one extra sanitization pass, not data loss.

### Storage layout

Four ETS tables plus a Redis backend option for multi-node:

1. **conversations** — conversation metadata (`conversation_id` (UUID v5 or temporary v4), `source_provider`, `created_at`, `last_active_at`, `provider_conversation_id` (metadata), `fingerprint_hash`)
2. **conversation_mappings** — placeholder → original per conversation
3. **conversation_reverse_index** — (original_value, type) → placeholder per conversation for O(1) reuse
4. **message_cache** — message content hash → sanitized version per conversation

Note: The `conversation_fingerprints` table is not needed — UUID v5 derivation makes it redundant.

### Dashboard

- Two views: **Conversations** (grouped, expandable to show individual requests) and **Requests** (per-request with a Conversation ID column).
- Conversation-level metadata: total PII entities detected, number of turns, provider_conversation_id (metadata), accumulated mapping type summary, duration from first to last request.
- Existing per-request metrics (timing, provider, status) remain available within each Conversation.

## Consequences

### Positive

- Placeholder consistency across turns — the LLM sees `<EMAIL_1>` every time the same email appears.
- CPU savings from message cache — no re-sanitization of previously processed messages.
- Conversation visibility on the dashboard — admins can see grouped multi-turn interactions.
- ETS/Redis backend abstraction stays consistent with the former SessionStore pattern.
- Cross-provider continuity works naturally — fingerprinting operates on canonical format.

### Negative

- Higher memory usage per active Conversation (cached messages + mapping + reverse index) vs per-request sessions.
- Fingerprint collision risk — two different users starting with identical messages could match the same Conversation. Deemed extremely rare with full composite fingerprinting.
- Modified message history breaks conversation continuity — triggers a new Conversation. Accepted trade-off.
- Complexity: 4 ETS tables + Redis option. Turn 1 requires migration from UUID v4 to UUID v5.

### Neutral

- Per-request Events (metrics) are unchanged — they continue to track timing, provider, PII counts per request.
- The `session_id` field in Events becomes a `conversation_id` field.
- The former SessionStore ETS/Redis modules have been replaced — the data model is fundamentally different.

---

## Amendment (2026-06-08): Fingerprinting as Primary Identification

### Rationale

During implementation of issue #5, research into provider conversation IDs across OpenAI, Anthropic, and Ollama revealed:

1. **`previous_response_id` is a parent pointer, not a conversation ID** — it changes every turn in the OpenAI Responses API, causing a new conversation to be created for each request. This breaks placeholder reuse.

2. **No provider returns conversation-level IDs in responses** — Anthropic returns message-level IDs (`msg_xxx`), OpenAI returns response-level IDs (`chatcmpl-xxx`), Ollama has none. Provider conversation IDs exist only in request bodies and are therefore client-provided, not authoritative.

3. **Cross-provider continuity cannot work with provider IDs alone** — Anthropic and Ollama have no stateful conversation concept. A client switching providers would require a secondary aliasing mechanism.

4. **The PRD requires cross-provider continuity** (issue #4, User Story 10) — fingerprinting achieves this naturally since messages are canonicalized before hashing.

### Revised decision

The primary conversation identification mechanism is changed to **message fingerprinting with deterministic UUID v5 derivation** for all APIs, regardless of provider. Provider conversation IDs (`thread_id`, `conversation`) are demoted to metadata — stored for observability, not used for lookups. `previous_response_id` is dropped entirely.

### Consequences

- **UUID v5 derivation**: conversation ID is deterministic from fingerprint. Turn 1 uses a temporary UUID v4 until the response fingerprint is available, then migrates to UUID v5.
- **`find_by_provider_id/2` removed**: No longer needed — fingerprint handles all lookup.
- **Turn 1 migration**: Accepted implementation complexity — the temporary UUID v4 → UUID v5 migration is confined to the first turn of each conversation.
- **Provider IDs still visible**: Dashboard can display which `thread_id` or `conversation` a conversation originated from.
