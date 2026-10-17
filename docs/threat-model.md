# Threat Model

ShhAi 0.1.0 — for security reviewers. This document reflects **shipped**
behaviour on `release/0.1.0`; every claim cites the code or ADR that
implements it. Companion docs: `docs/integrations.md` (harness setup),
`docs/architecture/` (request flow), `docs/adr/` (decision records), and
`SECURITY.md` (reporting).

## 1. Assets and trust boundary

ShhAi is a privacy proxy that sits between coding harnesses and LLM
backends. The assets it protects are:

1. **Prompt/response content** — the PII inside user messages, tool-call
   arguments, and assistant responses.
2. **Backend credentials** — the per-provider API keys configured on the
   ShhAi side (`PROVIDER_*_API_KEY`).
3. **The audit store** — retained conversation content and PII mappings
   when Audit Mode is on.
4. **The admin dashboard** — the operator's view over 1 and 3.

**Trusted:** the operator (holds `ADMIN_PASSWORD`, configures
`PROXY_API_KEYS`, provisioned the backend keys and the audit encryption
key) and the ShhAi host process.

**Untrusted:** proxy clients (harnesses presenting a gate key — they are
gate-authenticated but their content is untrusted), network traffic
between the client and ShhAi, and the LLM backends (ShhAi's central
guarantee is that they never receive un-sanitized PII — see §3).

**The boundary ShhAi enforces:** content crosses from client to backend
only through the sanitize pipeline; credentials cross in one direction
only, from operator config to the outbound request; and every request
crosses one of three named gates — the inbound proxy gate (§2), the
admin dashboard gate (§5), and the outbound header allowlist (§4).

## 2. Inbound gate (`/v1`, `/api`) — fail-closed

The proxy scopes are wrapped in the `:proxy` pipeline whose first plug is
`ShhAiWeb.ProxyAuth` (mounted in `ShhAiWeb.Router`'s `:proxy` pipeline).

- Every request must carry `authorization: Bearer <key>` where `<key>` is
  one of the comma-separated `PROXY_API_KEYS` (trimmed, blanks dropped —
  `ShhAi.Config.proxy_api_keys/0`). Revocation is removal from the list.
- **Unconfigured gate refuses everything:** when `PROXY_API_KEYS` is
  unset the gate returns `503` to every request — a misconfigured
  deployment serves nothing rather than acting as an open relay
  (`ShhAiWeb.ProxyAuth.call/2`; see its moduledoc). Boot logs a single loud
  warning (`ShhAi.Application.start/2`).
- **Bad key → 401** (`ShhAiWeb.ProxyAuth.call/2`).
- Token extraction accepts only a Bearer scheme (case-insensitive);
  missing header, non-Bearer scheme, or empty token all fail
  (`ShhAiWeb.ProxyAuth.bearer_token/1`).
- **Constant-time, length-hiding comparison:** both sides are SHA-256
  hashed before `Plug.Crypto.secure_compare/2`, so comparison timing
  leaks neither a configured key's length nor any prefix match
  (`ShhAiWeb.ProxyAuth.authorized?/2`).

**Outside the boundary:** `/health` and `/ready` are deliberately on a
bare pipeline — no auth, no body parsing, no session — and are excluded
from production `force_ssl` so orchestrators can probe an instance
(`ShhAiWeb.Router`'s bare `:browser`-free pipeline;
`ShhAiWeb.HealthController`; the `force_ssl` block in
`config/prod.exs`). They expose only liveness/readiness status
(`ShhAi.Health.liveness/0` / `readiness/0`), never content.

## 3. Fail policies

### 3.1 PII detector hard errors: fail-closed by default (ADR-0014)

Policy home: `ShhAi.PIIPipeline.sanitize_openai_request/2` (the sanitize
rescue wrapper). Any raise in the
sanitize pipeline is caught and reduced to
`{:error, :pii_sanitization_failed}` (same rescue block), which
propagates through `ShhAi.ProviderClient.prepare_request/6`
so the request fails with a
generic 500 (`"Internal proxy error"`) and **no body is forwarded** to
the backend. ADR-0014 promotes this from incidental behaviour to stated
policy (`docs/adr/0014-detector-failure-fail-closed-policy.md`, Decision).

The default is fixed in config: only the literal `"forward"` changes it;
unset, `"block"`, and any unrecognised value all stay `:block`
(`ShhAi.Config.pii_error_mode/0`).

### 3.2 The fail-open foot-gun: `PII_ERROR_MODE=forward`

**This setting disables the proxy's central guarantee.** With it, a
detector hard error forwards the request **un-sanitized** — original
messages, empty mapping — accepting a leak window
(`ShhAi.PIIPipeline` forward branch; ADR-0014 Negative consequences). The forward
path logs a warning naming the mode and the redacted error class, but
the request still goes out.

Operators should set it only consciously, e.g. to trade privacy for
availability during a detector outage, and remove it afterwards.

### 3.3 False negatives forward silently

If the detector runs cleanly but misses PII, the request forwards; there
is no runtime signal by construction. Accuracy is surfaced out-of-band
(detection metrics, dashboard Flag, `docs/benchmarks.md`). A runtime
uncertainty signal is deferred to 0.2 (ADR-0014, Decision).

### 3.4 Boot-time fail-closed defaults

- **Audit encryption key.** With `AUDIT_MODE=true`, an empty
  `AUDIT_ENCRYPTION_KEY` raises at boot; a non-empty key must Base32-
  decode to exactly 32 bytes (AES-256-GCM) or boot raises with an
  operator message and a generation command
  (`ShhAi.Config.audit_encryption_key/0`). The vault decodes the same way at
  startup (`ShhAi.Audit.Vault.init/1`).
- **NER load is boot-blocking.** With `PII_NER_ENABLED=true`, a model
  that fails to load aborts startup (crash-loop) with a message naming
  the escape hatch `PII_NER_ENABLED=false` (`ShhAi.Config.pii_ner_enabled/0`
  and its load check); the check runs from `ShhAi.Application.start/2`.
  Belt-and-braces: `/ready` reports not-ready while NER is enabled and
  uninitialized (`ShhAi.Health.readiness/0`).
- **Enabled providers need keys.** Every enabled provider instance must
  carry a non-empty API key or boot raises naming the env var and how to
  disable the provider (`ShhAi.Config.require_provider_api_key!/1`).
- **Admin dashboard.** Every `/admin` route refuses to serve (403) until
  `ADMIN_PASSWORD` is set (the `ShhAiWeb.Router` `/admin` pipeline and
  its session routes), with a loud boot warning
  (`ShhAi.Application.start/2`).

## 4. Credential and header handling

Client-supplied auth material never reaches a backend. Two allowlist
chokepoints enforce this:

1. **Inbound, at the controller.** Only `content-type`, `accept`, and
   `x-no-audit` are read off the request; the client's `authorization`
   (the gate token), `x-api-key`, cookies, hop-by-hop headers, and
   `host`/`content-length`/`transfer-encoding` are dropped in
   `ShhAiWeb.ProxyController`'s plug pipeline, filtered by its
   header-allowlist plug. `x-no-audit` is consumed locally (§6.2) and is
   not in the outbound allowlist.
2. **Outbound, at the transport.** Converter-emitted headers are filtered
   to `content-type` and `accept` by
   `ShhAi.ProviderClient.HTTPTransport` (its `build_headers/3` allowlist
   filter, applied on both the request and stream paths); dedup is by lowercased name,
   first occurrence wins. The
   configured per-backend key is then injected — `x-api-key` +
   `anthropic-version` for Anthropic, `authorization: Bearer <key>` for
   OpenAI/Ollama (the transport's header-injection step). This is the
   chokepoint that guarantees the gate token and any client
   `authorization`/`x-api-key` never reach a backend (the same allowlist
   filter that drops unknown inbound header names).

**No client-key fallback:** the outbound credential is always the
resolved/pinned instance's own `config.api_key`, built from the selected
backend's config, not from the request
(`ShhAi.ProviderClient.prepare_request/6`; per-backend keys required by
`ShhAi.Config.require_provider_api_key!/1`).

**No passthrough headers in 0.1:** provider-specific headers (e.g.
`anthropic-beta`) are deliberately not forwarded; adding one is a
deliberate future change to the allowlist (the `ShhAi.ProviderClient.HTTPTransport`
moduledoc).

## 5. Admin dashboard

- Single operator credential: `ADMIN_USER`/`ADMIN_PASSWORD`
  (`ShhAi.Config.admin_user/0` / `admin_password/0`). Login compares both values with
  `Plug.Crypto.secure_compare/2` and always runs both comparisons to
  keep timing uniform (`ShhAiWeb.AdminSessionController`'s create action).
- Session gate: `:admin_authenticated` pipeline plus a LiveView
  `on_mount` re-check on the socket, so there is no unauthenticated
  back door into live pages; the socket gate re-checks configured-ness
  so a stale cookie cannot reach data after `ADMIN_PASSWORD` is unset
  (`ShhAiWeb.Router`'s `:admin_authenticated` pipeline;
  `ShhAiWeb.AdminAuth` `on_mount` hooks).
- **Accepted: a single entry gate.** Any authenticated operator can open
  a conversation and see decrypted PII; there is no per-action re-auth
  (step-up auth is 0.2, issue #58). See §8, limitation 3.

## 6. Audit Mode (opt-in at rest)

### 6.1 Off by default, conditional datastore

Audit Mode is off by default; nothing is retained when off
(`ShhAi.Config.audit_mode?/0`). `ShhAi.Repo` and the Cloak vault are supervision
children **only when `AUDIT_MODE=true`** — the default deployment is
DB-free, never opens or creates an audit database file
(`ShhAi.Application`'s `audit_repo_child/0` / `audit_vault_child/0`;
ADR-0016, `docs/adr/0016-audit-persistence-conditional-on-audit-mode.md`).

### 6.2 Encrypted at rest, with client opt-out

- `mapping` and `sanitized_content` columns are encrypted via
  `ShhAi.Audit.Types.EncryptedBinary` (Cloak, AES-256-GCM, `tag: "v1"`;
  the `ShhAi.Audit.ConversationRecord` and `ShhAi.Audit.ConversationMessage`
  schemas, with the Cloak vault configured in `config/config.exs`).
  The mapping is serialised with `:erlang.term_to_binary/1` before
  encryption (`ShhAi.Audit.Writer`'s mapping-encode step; ADR-0010).
- **`X-No-Audit` opt-out (ADR-0011):** detected case-insensitively per
  request in `ShhAi.ProviderClient` (the header check that builds the
  request context), sticky (false→true only,
  `ShhAi.Conversation.Store.ETS.set_opted_out/1`) and retroactive — the
  Writer UPSERTs a tombstone (`opted_out=true, mapping=NULL`) and deletes
  that conversation's `conversation_messages`
  (`ShhAi.Audit.Writer`'s opt-out handler).
- **Defence in depth:** every Writer cast handler early-bails when
  audit mode is off, and message/mapping writes additionally check the
  per-conversation `opted_out` flag (the `ShhAi.Audit.Writer` cast
  handlers; see its moduledoc). A reactivation sync read re-checks the
  persisted tombstone after an ETS entry expires (the Writer's
  reactivation-sync function).
- **Retention:** periodic cleanup deletes data older than
  `AUDIT_RETENTION_DAYS` (default 30) every `AUDIT_CLEANUP_INTERVAL_HOURS`
  (default 1) (`ShhAi.Config.audit_retention_days/0` /
  `audit_cleanup_interval/0`; the Writer's cleanup job).
- **Events rows** (request metadata: timing, status, PII counts) persist
  only when audit is on; their `error` column is a JSON-encoded TEXT
  field (the `ShhAi.Audit.EventRecord` schema).

### 6.3 Log and persisted-error redaction

Client-facing errors never echo provider or sanitizer internals: every
failure maps to a generic shape — 500 `"Internal proxy error"`, 404
naming only the model, 503 for pool exhaustion, and the two gate
messages (`ShhAiWeb.ProxyController`'s error-rendering paths;
`ShhAiWeb.ProxyAuth.call/2`). No raw
provider body is echoed to the client (`ShhAiWeb.ProxyController`'s
response-forwarding path).

Persisted and logged failure detail is **redacted to a bounded error
class**: `ShhAi.ErrorClass.classify/1` collapses any reason to a small
documented atom set (`:econnrefused`, `:nxdomain`, `:econnreset`,
`:closed`, `:timeout`, `:transport_error`, `:http_error`,
`:model_not_served`, `:pii_sanitization_failed`, exception modules,
`:unknown`) and never returns message content
(`ShhAi.ErrorClass.classify/1`). The persisted audit `error_message`
uses it at every site (`ShhAiWeb.ProxyController`'s audit write,
`ShhAi.ProviderClient`'s error handling, `ShhAi.ProviderClient.StreamTransport`'s
error handling), as do the
sanitize-failure logs (`ShhAi.PIIPipeline`'s rescue and forward paths).

Residual raw detail remains in a few operator-facing `Logger.error`
sites that log `inspect(reason)` (e.g. backend request/stream failures —
`ShhAi.ProviderClient.HTTPTransport` and `ShhAi.ProviderClient.StreamTransport`
error paths, `ShhAi.ProviderClient`'s streaming error handling; model-catalog
probe failures, `ShhAi.ModelCatalog`; conversation-store errors,
`ShhAi.Conversation`). These go to server logs only, not to
clients or the audit store, but an operator with log access may see
exception detail; treat the log sink as part of the trusted operator
boundary.

## 7. Retry/failover posture (ADR-0013 §5, issue #72)

Retry exists and is deliberately narrow. It fires **only** on a
connection-class transport failure (`:econnrefused`, `:nxdomain`,
`:econnreset`, `:closed`) — the provider instance was unreachable and
zero tokens were spent; receive-timeouts and provider HTTP 4xx/5xx are
never retried, so the provider's answer is never hidden and the request
is never double-billed (`ShhAi.ProviderClient` retry policy, exercised in
its request path). Fallback draws uniformly at random from the
model-aware pool, excluding
already-tried instances, until success or exhaustion
(`ShhAi.ProviderClient`'s fallback loop; `ShhAi.TargetProvider`'s pool
exclusion logic). Pool exhaustion returns a distinct ShhAi-originated 503
(`ShhAiWeb.ProxyController`'s error rendering). Streaming retries only before the first
byte reaches the client; a mid-stream failure terminates the stream — no
silent restart, no duplicated chunks (`ShhAi.ProviderClient`'s streaming
retry guard; `ShhAi.ProviderClient.StreamTransport`'s first-byte check).
**PII safety on retry:** the sanitized
canonical body and conversation mapping are reused verbatim; only the
target-dialect conversion re-runs — detection/NER never re-runs and the
sanitization guarantee is not re-evaluated against a different backend
(`ShhAi.ProviderClient`'s retry/fallback path, which reuses the prepared
sanitized request; ADR-0013 §5 "PII re-entry — reuse the
mapping").

## 8. Accepted 0.1 limitations

These are known, accepted exposures in 0.1 (issue #58, "Accepted 0.1
limitations"). Reviewers should weigh them explicitly.

1. **Provider-hosted tool arguments are not sanitised.** The sanitizer
   walks `messages[].content` and `messages[].tool_calls[].function.arguments`
   only (`ShhAi.PII.Sanitizer`'s message-walk functions). Arguments
   executed by provider-hosted tools (web search, code interpreter,
   provider-side functions) are not represented in the canonical message
   body and reach the provider intact.
2. **Conversation identity is anchored on the first exchange only.**
   The fingerprint covers the first two messages (first user message +
   first assistant response) and derives the conversation UUID v5 from
   it (`docs/adr/0007-conversation-tracking.md`, "Modified history";
   `ShhAi.ProviderClient`'s conversation-resolution path). Editing the
   first exchange starts a
   new conversation; edits to later messages do not. Practical upshot:
   the "same conversation" grouping — and the `X-No-Audit` opt-out, which
   is per-conversation — can be escaped by re-opening the exchange.
3. **Single dashboard entry gate.** Any authenticated operator sees
   decrypted PII on conversation-open; no step-up auth (§5, issue #52).
   This exposure exists only when Audit Mode is on — with it off, nothing
   is retained, so there is no dashboard data to view.
4. **TLS terminates outside the app.** ShhAi ships no in-app certificate
   management; production relies on the `force_ssl` posture
   (`rewrite_on: [:x_forwarded_proto]`, HSTS, `/health` and `/ready`
   excluded — the `force_ssl` block in `config/prod.exs`) and expects the
   operator's
   reverse proxy to terminate TLS (issue #52).
5. **JSON-schema structural keys pass through the field sanitizer.** The
   sanitizer walks every top-level string field except
   `messages`/`input`/`model` (`ShhAi.PIIPipeline`'s
   `sanitize_request_fields`), including `tools` descriptions, `metadata`,
   and `user`, all on one shared placeholder mapping. Inside those values,
   JSON-schema structural keys (`type`, `required` property-name lists) are
   left as-is so schemas survive intact — property *names* and *descriptions*
   are sanitised, but the sanitiser's type-space is its own; a schema whose
   plumbing collides with a placeholder shape is forwarded unchanged.
6. **No audit-key rotation mechanism** in 0.1 (ADR-0010, Negative
   consequences); rotating `AUDIT_ENCRYPTION_KEY` is a manual re-encrypt
   exercise for the operator.
7. **False negatives are silent** (§3.3) — accepted risk in 0.1,
   mitigated only after the fact (ADR-0014).

## 9. Reviewer checklist

- [ ] Gate configured and fail-closed verified: unset `PROXY_API_KEYS` →
      every `/v1`/`/api` request 503.
- [ ] `PII_ERROR_MODE` is unset or `block` in the deployment environment
      (§3.2 — `forward` is an explicit, logged leak window).
- [ ] With `AUDIT_MODE=true`: `AUDIT_ENCRYPTION_KEY` is a Base32-encoded
      32-byte key, stored with the same care as the backend keys, and
      `AUDIT_DB_PATH` points at a protected volume.
- [ ] Backend keys present only in ShhAi's environment; harness configs
      carry only the proxy gate key (`docs/integrations.md`).
- [ ] TLS terminated by the reverse proxy; `force_ssl` exclusions
      (`/health`, `/ready`, localhost) acceptable for the network
      topology.
- [ ] `ADMIN_PASSWORD` set; dashboard exposure limited to the operator
      network (single entry gate, §5/§8.3).
