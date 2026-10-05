# Per-conversation provider instance pinning and native model-aware selection

## Status

Accepted _(2026-08-31)_ — refines ADR-0002 (multi-provider architecture) for the standalone 0.1 release. §5 amended _(2026-09-01)_ to specify the retry/fallback mechanism (resolving #49).

## Context

ADR-0002 chose uniform-random provider instance selection **per request**, passing the client's `model` string through unchanged. Resolving #47 (coding-harness integration) surfaced two problems, neither harness-specific:

1. **Cache and stability.** Random per-request selection defeats provider-side prompt caching (every provider keys caching on a stable prefix reaching the *same* provider instance) and destabilizes multi-turn / tool-using sessions (turn N can land on a different provider instance than turn N-1).
2. **Model resolution.** A request for `model: "claude-sonnet-…"` can land on a provider instance that does not serve it and 404, because the `model` string is never checked against the chosen provider instance.

The tension throughout was the boundary with the deferred **LiteLLM integration (0.2)**: how much routing ShhAi does natively without duplicating LiteLLM or breaking the 0.1 principle of *standalone, no required external services*. Research established that (a) LiteLLM's real value is provider-API *normalization* across 100+ providers — which ShhAi already performs for its three native dialects via `ApiConverter` + the OpenAI-canonical pipeline (ADR-0003), including model-listing bodies; (b) LiteLLM is pure Python with no BEAM embedding, so integrating it means running a sidecar that drags in Python and optionally Postgres/Redis; and (c) LiteLLM's remaining value is *advanced routing strategies* (latency/cost/least-busy, weighted deployments, rich fallback chains), which are scale features, not 0.1 essentials.

## Decision

### 1. Per-conversation provider instance pinning

The provider instance chosen on a conversation's first request is stored on the `Conversation` record and reused for every subsequent turn. Storage is an **8th element on the `conversations` ETS tuple** (and the Redis backend), holding the pinned provider's **stable configured name** (e.g. `openai_1`, not the list index — indices shift when config changes; names do not). It is preserved through `touch/1` and `update_fingerprint/2`, exactly like `opted_out` (ADR-0007 amendment).

The pin's lifetime **is** the conversation's lifetime: created on turn 1, deleted when the conversation is evicted by its sliding TTL (ADR-0004/0007, `Config.conversation_ttl`, default 1h *inactivity*). Eviction is the only routine reset of a pin.

### 2. Selection resolves at conversation-lookup, not request entry

Today `Config.select_provider/0` runs at the top of `setup_context/6`, before the conversation is known. Pinning inverts this: the effective target becomes `conversation.pinned_provider_instance || select_provider(model)`, resolved **after** `find_or_create_conversation/3` inside `prepare_request`. Turn 1 (fresh conversation) selects and records the pin at `persist_turn` time (the existing deferred-persistence point); turn 2+ reads the pin off the found record and uses it.

### 3. Native model-aware selection

Each configured provider instance's model catalog is discovered by **probing its listing endpoint** — `/v1/models` (OpenAI/Anthropic) or `/api/tags` (Ollama), the paths the converters already recognize — on **boot and on a periodic refresh** (a `ShhAi.ModelCatalog` GenServer owning a public ETS table the catalog is published into; interval configurable). `select_provider(model)` filters the pool to provider instances whose catalog contains the requested `model`, then picks uniformly at random among those, then pins.

- A provider instance that is **unprobed or whose probe failed serves nothing** until a probe succeeds — it is excluded from model-filtered selection and contributes nothing to the listing. The periodic refresh lets a transiently-failing provider instance rejoin automatically. (Correctness over availability: routing to a provider instance we cannot confirm serves the model would reintroduce the 404 this ADR removes.)
- The catalog is published into a **public ETS table the refresher owns**, not `:persistent_term`: it is rewritten on every refresh, and `persistent_term` is optimised for terms "never or infrequently updated" — each update runs a global GC across every process (OTP's own guidance), whereas an ETS row is a constant-time insert read directly by callers with no message hop. This is the repo's existing shape for runtime state (`Conversation.Store`, ADR-0004; `Metrics.EventBuffer`).
- A request for a `model` **no provider instance serves returns a 4xx** (`model "X" not served by any configured provider instance`) rather than routing somewhere that will 404 — a precise, ShhAi-originated error is more debuggable than a passed-through provider 404.

### 4. `/v1/models` returns the aggregated union

The listing endpoint **always** returns the union of the probed per-provider-instance catalogs, each normalized through the *existing* converters to canonical form, **deduped by model id** (two provider instances serving `gpt-4o` → one listing entry, both remain selection candidates), rendered back into the client's requested dialect. No new conversion code; no cross-provider-instance probing at request time (served from the cached catalog).

### 5. Retry interaction with the pin (co-designed with #49)

- **Pinned provider instance down (transient — still in config):** the pin is **immutable**. Retry the request against another provider instance, but never rewrite the pin, so caching resumes on the original provider instance when it recovers. A failed request to a down provider instance costs no tokens, so keep-pin is cheap. No threshold, no TTL modelling.
- **Pinned provider instance gone (absent from current config — permanent):** **re-pin** to a currently-configured provider instance. This is a clean boolean check ("does the pinned name still resolve in `Config`?"), not a threshold, and there is no cache to thrash.

#### Retry/fallback mechanism (resolving #49)

ShhAi is a proxy: the client must see the provider instance's real answer. Retry therefore fires *only* when the provider instance was genuinely unreachable and no work was done.

- **Retryable = connection-class transport failure only.** A `%Mint.TransportError{}` whose reason is `:econnrefused` / `:nxdomain` / `:econnreset` / `:closed` and the like: the provider instance was unreachable, zero tokens spent, safe to route around. Everything else flows to the client untouched:
  - **Receive-timeout** (`reason: :timeout`) is a **hard error** returned to the client — the request may have been processed server-side, so retrying it risks double-billing and hides a real signal.
  - **Provider HTTP status** (4xx/5xx) is the provider's answer (today already the success path) and passes through unchanged.
- **Fallback selection — exhaust the model-aware pool once.** On a retryable failure, draw the next target uniformly at random from the model-aware pool (§3: provider instances whose probed catalog serves the requested `model`), excluding already-tried provider instances, until one succeeds or the pool is exhausted. This is the *same* mechanism for turn-1 (freshly selected) and turn-2+ (pinned — the pin only chooses the first attempt). Single-provider-instance deployments have no fallback and fail immediately. A fallback target may be a **different dialect** than the pinned one.
- **PII re-entry — reuse the mapping.** The retry loop wraps only the convert-and-send tail. The sanitized canonical-OpenAI body and the conversation mapping computed in `prepare_request` are reused verbatim; only `from_openai_request` (target conversion) re-runs for the new target's dialect. Detection/NER never re-runs — it is the expensive phase, and re-running it would destabilize the conversation's mapping.
- **Streaming — pre-first-byte only.** A streaming request is retried only before the first chunk is forwarded downstream. Once bytes are on the wire, a mid-stream failure terminates the stream; no silent restart.
- **TTL & pin on outcome.** Success-after-retry behaves as a normal success (touch TTL, pin unchanged). Full pool exhaustion touches the conversation TTL (keeping the mapping alive for the next attempt) and emits an error metric; the pin is **never** mutated by retry. Re-pin-on-gone happens at *selection* time before any attempt (above), not as a retry outcome.
- **Observability & exhaustion error.** Each fallback attempt emits a log/metric (failed provider instance → next tried). Pool exhaustion returns a distinct, ShhAi-originated `503`: `no configured provider instance serving "<model>" is currently reachable` — a precise ShhAi error over a passed-through provider error, consistent with §3.

### 6. The 0.1 / 0.2 LiteLLM boundary

- **0.1 native:** static-shape everything above — probed catalog → filter-then-random → per-conversation pin → aggregated `/v1/models`. Stays standalone: no Python, no Postgres, no Redis required.
- **0.2 LiteLLM (optional):** advanced routing strategies, weighted deployments, rich fallback chains, and reaching providers beyond ShhAi's three native dialects. ShhAi treats a LiteLLM proxy as **just another OpenAI-compatible provider instance** — an operator lists its URL as one of ShhAi's provider instances; ShhAi's pin selects it, LiteLLM fans out behind it. No 0.1 work is thrown away, and per-conversation pinning is genuinely orthogonal to LiteLLM's session-affinity (which requires a client-supplied session id + Redis and defaults off).

## Considered alternatives

- **Homogeneous-pool requirement** (operators configure identical model ids across all provider instances; `model` passes through). Rejected: too restrictive to be useful, and pushes a fragile constraint onto operators.
- **Neutral advertised model name remapped per target.** Rejected: heaviest config surface for no 0.1 benefit.
- **Requiring/embedding LiteLLM in 0.1.** Rejected: cannot embed (pure Python), and a sidecar breaks "standalone, no required external services"; its normalization value is already native for the three supported dialects.
- **Threshold-based hybrid re-pin on failure.** Rejected: no single threshold is correct across provider instances with different cache TTLs, and re-pinning churns the cache; the down-vs-gone split achieves the goal without a threshold.

## Consequences

- The `conversations` ETS tuple grows to 8 elements; all pattern matches and both Store backends (ETS, Redis) update, plus `touch/1` / `update_fingerprint/2` preservation.
- Target-provider finalization moves below `find_or_create_conversation/3`; `select_provider/0` gains a `model`-aware arity.
- A new `ShhAi.ModelCatalog` GenServer and its refresh interval config; boot does not block on probes.
- Single-provider-instance and zero-config deployments are unaffected in spirit: one provider instance is always the only candidate, and its catalog is whatever it advertises.
- A provider instance deleted from config mid-conversation triggers a one-time re-pin on its next request; a transiently down one does not.
