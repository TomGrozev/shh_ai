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

**Mapping**: `{session_id → %{"EMAIL_1" => "john@example.com"}}` — stored in SessionStore.
_Avoid_: Lookup table, Replacement dict

**Placeholder**: `<TYPE_N>` format — uppercase type, sequential number.
_Avoid_: Token, Mask, Tag

**Preserved PII**: PII NOT sanitized because context rules say keep it. `always_sanitize` types are never preserved.
_Avoid_: Whitelisted PII, Safe PII

**Cross-validation**: NER + regex overlap. Matching types get +0.1 boost; conflicts use regex type.
_Avoid_: Validation, Agreement

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
- **Session-scoped mappings** — deleted on completion; after TTL, restoration fails.
- **`always_sanitize` overrides everything** — no context preserves it.
- **`persistent_term` is write-once** — config frozen at startup, no hot reload.
- **Random provider selection** — uniform distribution, no health checks.
- **Finch pools per-host** — 5 pools × 10 connections per provider URL.

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

### Session TTL

> **Dev:** "Why 5-minute TTL? Why not keep mappings forever?"
>
> **Domain expert:** "Memory. Mapping grows with PII count per request. Forever means
> memory leak. 5 minutes covers normal request/response cycles. If restoration fails
> after TTL, the client retries — same as a crashed session store."

## Flagged ambiguities

- **"Gateway"** → Use **Proxy**. Gateway implies routing logic we don't have.
- **"Unmask" / "Desanitize"** → Use **Restore**. Unmask sounds reversible in-place;
  Restore emphasizes mapping lookup.
- **"Cache"** → Use **SessionStore**. Cache implies read-through; SessionStore is
  write-once per request with TTL.
- **"Standard format"** → Use **Canonical format**. Standard implies a spec;
  canonical is our chosen interchange.
- **"Backend provider"** → Use **Target provider**. "Backend" is ambiguous —
  could mean any downstream service.
- **"Whitelisted PII"** → Use **Preserved PII**. Whitelist implies security;
  preservation is contextual.
