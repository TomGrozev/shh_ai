# ShhAi

An LLM Privacy Proxy built with Phoenix. Sits between client applications and LLM
backend providers, intercepting API requests to strip PII before forwarding.

## Language

### Core concepts

**Proxy**: The system as a whole — a transparent intermediary that intercepts, sanitizes, forwards, restores.
_Avoid_: Gateway (implies routing), Middleware (too generic)

**Source Provider**: The API format the client request arrived in (`:openai` | `:anthropic` | `:ollama`).
_Avoid_: Client provider, Origin format

**Target Provider**: The randomly-selected backend LLM. Can differ from source — proxy cross-converts freely.
_Avoid_: Backend, Destination

**Canonical Format**: OpenAI API format. All PII operations happen here regardless of source/target.
_Avoid_: Standard format, Intermediate format

### PII processing

**PII Pipeline**: Orchestrates sanitize/restore. Operates in canonical format only.
_Avoid_: Sanitization engine, PII module

**Mapping**: An accumulated PII placeholder-to-original mapping scoped to a Conversation. Grows across requests as new PII is detected; reused across requests within the same Conversation. Stored in ConversationStore.
_Avoid_: Lookup table, Replacement dict

**Placeholder**: `<TYPE_N>` format — uppercase type, sequential number.
_Avoid_: Token, Mask, Tag

**Reverse Index**: A lookup table from `(original_value, type) → placeholder` within a Conversation, enabling O(1) placeholder reuse when the sanitizer encounters PII it has already seen. Stored alongside the Mapping in ConversationStore.
_Avoid_: Reverse mapping, Lookup index

**Preserved PII**: PII NOT sanitized because context rules say keep it. `always_sanitize` types are never preserved.
_Avoid_: Whitelisted PII, Safe PII

**Cross-validation**: NER + regex overlap. Matching types get +0.1 boost; conflicts use regex type.
_Avoid_: Validation, Agreement

**Audit Mode**: Global toggle that enables retention of sanitized prompts and Mappings for admin review. When OFF, no PII data is retained — behavior is identical to today. When ON, full Mappings and sanitized text are stored (encrypted at rest) for flagging by admins.
_Avoid_: Logging mode, Debug mode, Track mode

**Audit Record**: A stored request snapshot containing the sanitized prompt, sanitized response, Mapping, and detection metadata. Created only when Audit Mode is ON and the request hasn't opted out.
_Avoid_: Audit log, Inspection record, Review item

**Flag**: Admin mark on a PII detection indicating it was incorrect. False positive ("sanitized something that wasn't PII") or false negative ("missed actual PII in the text"). Tied to an Audit Record.
_Avoid_: Report, Correction, Feedback

**Opt-out Header**: HTTP header (`X-No-Audit`) that clients send to exclude a request from Audit Mode retention. Even when Audit Mode is ON, requests with this header are not stored.
_Avoid_: Skip header, Privacy header, Exclude header

### Conversation tracking

**Conversation**: A group of related proxy requests sharing an accumulated PII Mapping. Identified by first-exchange fingerprinting — a deterministic UUID v5 derived from the first user message and first assistant response in canonical format. Conversation IDs are stable from creation. Provider-supplied identifiers (thread_id, conversation) are stored as metadata for observability. Persists for the duration of a multi-turn interaction.
_Avoid_: Session (old per-request concept), Chat, Thread (that's a specific OpenAI concept)

**Message Fingerprinting**: The primary conversation identification mechanism for all APIs. The lookup fingerprint hashes only the first exchange (first user message + first assistant response) in canonical format, deriving a deterministic UUID v5. Same first exchange → same conversation ID across all providers, regardless of how many turns the conversation has. Turn 1 defers persistence until the first-exchange fingerprint is available, then persists with a stable UUID v5. No migration needed.
_Avoid_: Message matching, Content hashing

**Accumulated Mapping**: The PII mapping owned by a Conversation, which grows as new PII is detected across requests and reuses existing placeholders for PII seen in prior turns.
_Avoid_: Shared mapping, Session mapping, Conversation dictionary

**ConversationStore**: The storage backend for Conversations and their accumulated mappings. Same backend options as the former SessionStore (ETS or Redis).
_Avoid_: Session store, Conversation cache

**Message Cache**: Per-conversation ETS-backed cache mapping message content hashes to their sanitized versions. Avoids re-sanitizing messages seen in prior turns. Both user messages and assistant responses are cached. Assistant responses are cached after the stream completes.
_Avoid_: Response cache, Content cache

**Conversation Fingerprint**: Two variants: (1) the **first-exchange fingerprint** (first 2 messages) used for conversation ID derivation, and (2) the **full fingerprint** (all messages) stored as metadata for observability. Both are ordered composites of per-message hashes in canonical format. Used uniformly across all providers.
_Avoid_: Request hash, Message hash

**Provider Conversation ID**: A client-supplied conversation identifier (e.g., `thread_id` from OpenAI Threads, `conversation` from OpenAI Responses API). Stored as metadata on the Conversation for dashboard display and debugging. NOT used as a primary lookup key.
_Avoid_: Stateful API signal, Conversation key

**Sliding TTL**: Conversation expiration strategy where each new request resets the TTL clock. Default 1 hour, configurable. After TTL expires, the Conversation is deleted and the next request starts a new one.
_Avoid_: Hard TTL, Fixed expiry

### Streaming transport

**SSEEvent**: A typed record representing a single Server-Sent Events wire-frame — one of `:data` (a JSON payload line), `:done` (the `[DONE]` stream-termination marker), or `:event` (a typed event line with an `event_name` such as Anthropic's `content_block_delta`). The contract for crossing between wire-format parsing and provider-specific event handling.
_Avoid_: SSE chunk, SSE frame, raw chunk, raw event

### Performance Testing

**Performance Suite**: Benchmarks that measure timing of PII operations. Runs via `mix test.performance`.
_Avoid_: Benchmark tests, Perf tests

**Stress Suite**: Benchmarks with extreme data sizes (100KB–1MB). Runs via `mix test.stress`, not in CI.
_Avoid_: Load tests, Heavy tests

**Baseline**: Reference benchmark results stored in CI artifacts or `.perf/baselines/`. Used for comparison.
_Avoid_: Reference results, Gold standard

**Common-case**: Realistic payload sizes (1KB, 10KB, 50KB) — what production typically handles.
_Avoid_: Normal load, Standard size

**Major Regression**: >50% slowdown compared to baseline. Blocks CI.
_Avoid_: Severe regression, Critical regression

**Minor Regression**: 20–50% slowdown compared to baseline. Warns in CI, doesn't block.
_Avoid_: Moderate regression, Warning regression

## Relationships

- **Source ≠ Target** — an Anthropic request may forward to OpenAI. Cross-conversion.
- **OpenAI format is canonical** — PII ops never happen in other formats.
- **Conversation-scoped mappings** — accumulated across requests; PII placeholders reused within a Conversation. After TTL, restoration fails and a new Conversation starts.
- **`always_sanitize` overrides everything** — no context preserves it.
- **`persistent_term` is write-once** — config frozen at startup, no hot reload.
- **Random provider selection** — uniform distribution, no health checks.
- **Finch pools per-host** — 5 pools × 10 connections per provider URL.
- **Audit Mode is OFF by default** — zero PII at rest when disabled; opt-in transparency.
- **Opt-out overrides Audit Mode** — `X-No-Audit` header prevents retention even when the toggle is ON.
- **Audit Records are encrypted at rest** — Mappings stored with encryption; decrypted only in admin UI on demand.
- **Fingerprinting is the primary conversation identification mechanism** — all APIs use message fingerprinting with deterministic UUID v5. Conversation IDs are stable from creation via first-exchange fingerprinting (first 2 messages); no migration from v4 to v5. Provider conversation IDs (thread_id, conversation) are metadata only. `previous_response_id` is ignored — it is a parent pointer, not a conversation ID.
- **Each proxy request is part of a Conversation** — the per-request Session concept no longer exists. Metrics are still tracked per-request via Events.
- **Message cache keys are hashes of unsanitized canonical-format content** — both user and assistant messages are cached by the content the client sends (which contains original PII after restoration).
- **Streaming responses are buffered and cached on completion** — the full sanitized response is cached after the `[DONE]` marker, not chunk-by-chunk.
- **SSE wire format crosses the Proxy through a typed event contract** — `SSEEvent` is the only shape that crosses between wire-format parsing, provider conversion, and the PII Pipeline; raw bytes do not cross these seams.
- **Modified first exchange starts a new Conversation** — if the client edits the first user message or first assistant response, the lookup fingerprint changes and a fresh Conversation begins. Edits to later messages do not affect conversation identity (the lookup fingerprint is derived from the first exchange only). This is an accepted limitation.
- **Conversations are source-format agnostic** — all messages are canonicalized to OpenAI format before fingerprinting, so the same conversation is identified regardless of which provider the client request arrived from.
- **Sliding TTL resets on each request** — active Conversations never expire; only idle ones do.

## Performance Testing

- **Separation of concerns** — Unit tests assert correctness; Performance tests measure timing. Never mix.
- **Fixed seed by default** — Benchmark data uses deterministic RNG (seed 42) for reproducible comparisons; configurable via `PERF_SEED` environment variable.
- **Baseline auto-updates** — CI updates baseline on merge to `main`; PRs compare against stored baseline.
- **Data generated, not hardcoded** — Performance tests use programmatic `DataGenerator` module; unit tests use inline fixtures.
- **Block on major, warn on minor** — CI fails if any benchmark regresses >50%; comments on PR if 20–50%.

## Example dialogue

### Canonical format choice

> **Dev:** "Why OpenAI as canonical? Why not Anthropic?"
>
> **Domain expert:** "OpenAI's chat format is the de facto standard — most models
> support it directly. Anthropic and Ollama both have well-defined conversions to/from
> OpenAI. Picking any other format would require more conversion edge cases."

### Provider selection

> **Dev:** "Why random selection? No health checks?"
>
> **Domain expert:** "Health checks add latency and complexity. The proxy is for
> privacy, not reliability. If you need smart routing, put a load balancer in front.
> Random is simple and sufficient."

### Hybrid detection

> **Dev:** "Why both regex and NER? Why not just one?"
>
> **Domain expert:** "Regex catches known formats (SSN, email, API keys) with high
> confidence. NER catches contextual entities (names, organizations) that regex can't.
> Cross-validation boosts confidence when both agree, limits false positives when
> they conflict. You get the best of both."

### Conversation TTL

> **Dev:** "Why not keep Conversation mappings forever?"
>
> **Domain expert:** "Memory. Accumulated mappings grow with PII count across turns. Forever means memory leak. A sliding TTL of 1 hour covers typical multi-turn conversations. If a Conversation expires, the client starts a new one — PII detected fresh, new placeholders assigned. The cost is redundant re-sanitization, not data loss."

### First exchange and conversation identity

> **Dev:** "What happens when a client modifies message history between turns?"
>
> **Domain expert:** "It depends on which messages change. The lookup fingerprint is derived from the first exchange only — the first user message and first assistant response. If the client edits those, the fingerprint changes and a new Conversation starts. But edits to later messages are invisible to lookup — the same first exchange always maps to the same Conversation. This is an accepted trade-off: conversation identity is anchored to the opening exchange, not the full history."

## Flagged ambiguities

- **"Gateway"** → Use **Proxy**. Gateway implies routing logic we don't have.
- **"Unmask" / "Desanitize"** → Use **Restore**. Unmask sounds reversible in-place;
  Restore emphasizes mapping lookup.
- **"Cache"** → Use **ConversationStore**. Cache implies read-through; ConversationStore
  accumulates mappings across requests with TTL.
- **"Standard format"** → Use **Canonical format**. Standard implies a spec;
  canonical is our chosen interchange.
- **"Backend provider"** → Use **Target provider**. "Backend" is ambiguous —
  could mean any downstream service.
- **"Whitelisted PII"** → Use **Preserved PII**. Whitelist implies security;
  preservation is contextual.
- **"Audit log"** → Use **Audit Record**. Log implies append-only event stream; a Record is a reviewable snapshot.
- **"Session"** → Use **Conversation**. Session was the old per-request concept; Conversation groups multiple requests with shared PII mapping.
