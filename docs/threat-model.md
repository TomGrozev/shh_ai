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
`ShhAiWeb.ProxyAuth` (`lib/shh_ai_web/router.ex:33-37`).

- Every request must carry `authorization: Bearer <key>` where `<key>` is
  one of the comma-separated `PROXY_API_KEYS` (trimmed, blanks dropped —
  `lib/shh_ai/config.ex:516-527`). Revocation is removal from the list.
- **Unconfigured gate refuses everything:** when `PROXY_API_KEYS` is
  unset the gate returns `503` to every request — a misconfigured
  deployment serves nothing rather than acting as an open relay
  (`lib/shh_ai_web/proxy_auth.ex:33-36`; moduledoc `proxy_auth.ex:9-12`).
  Boot logs a single loud warning
  (`lib/shh_ai/application.ex:38-43`).
- **Bad key → 401** (`proxy_auth.ex:39`).
- Token extraction accepts only a Bearer scheme (case-insensitive);
  missing header, non-Bearer scheme, or empty token all fail
  (`proxy_auth.ex:56-64`).
- **Constant-time, length-hiding comparison:** both sides are SHA-256
  hashed before `Plug.Crypto.secure_compare/2`, so comparison timing
  leaks neither a configured key's length nor any prefix match
  (`proxy_auth.ex:68-71`).

**Outside the boundary:** `/health` and `/ready` are deliberately on a
bare pipeline — no auth, no body parsing, no session — and are excluded
from production `force_ssl` so orchestrators can probe an instance
(`lib/shh_ai_web/router.ex:41-47`; `lib/shh_ai_web/controllers/health_controller.ex:6-12`;
`config/prod.exs:12-22`). They expose only liveness/readiness status
(`lib/shh_ai/health.ex:52-66`), never content.

## 3. Fail policies

### 3.1 PII detector hard errors: fail-closed by default (ADR-0014)

Policy home: `lib/shh_ai/pii_pipeline.ex:96-123`. Any raise in the
sanitize pipeline is caught and reduced to
`{:error, :pii_sanitization_failed}` (`pii_pipeline.ex:96-103`), which
propagates through `ShhAi.ProviderClient.prepare_request/6`
(`lib/shh_ai/provider_client.ex:207-237`) so the request fails with a
generic 500 (`"Internal proxy error"`) and **no body is forwarded** to
the backend. ADR-0014 promotes this from incidental behaviour to stated
policy (`docs/adr/0014-detector-failure-fail-closed-policy.md`, Decision).

The default is fixed in config: only the literal `"forward"` changes it;
unset, `"block"`, and any unrecognised value all stay `:block`
(`lib/shh_ai/config.ex:125`, `:636-637`).

### 3.2 The fail-open foot-gun: `PII_ERROR_MODE=forward`

**This setting disables the proxy's central guarantee.** With it, a
detector hard error forwards the request **un-sanitized** — original
messages, empty mapping — accepting a leak window
(`pii_pipeline.ex:110-135`; ADR-0014 Negative consequences). The forward
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
  (`lib/shh_ai/config.ex:494-518`). The vault decodes the same way at
  startup (`lib/shh_ai/audit/vault.ex:14-15`).
- **NER load is boot-blocking.** With `PII_NER_ENABLED=true`, a model
  that fails to load aborts startup (crash-loop) with a message naming
  the escape hatch `PII_NER_ENABLED=false` (`lib/shh_ai/config.ex:437-445`);
  the check runs from `Application.start/2` (`application.ex:22`).
  Belt-and-braces: `/ready` reports not-ready while NER is enabled and
  uninitialized (`lib/shh_ai/health.ex:51-63`).
- **Enabled providers need keys.** Every enabled provider instance must
  carry a non-empty API key or boot raises naming the env var and how to
  disable the provider (`lib/shh_ai/config.ex:342-360`).
- **Admin dashboard.** Every `/admin` route refuses to serve (403) until
  `ADMIN_PASSWORD` is set (`lib/shh_ai_web/router.ex:19-21`, `:129-138`),
  with a loud boot warning (`application.ex:28-34`).

## 4. Credential and header handling

Client-supplied auth material never reaches a backend. Two allowlist
chokepoints enforce this:

1. **Inbound, at the controller.** Only `content-type`, `accept`, and
   `x-no-audit` are read off the request; the client's `authorization`
   (the gate token), `x-api-key`, cookies, hop-by-hop headers, and
   `host`/`content-length`/`transfer-encoding` are dropped here
   (`lib/shh_ai_web/controllers/proxy_controller.ex:26-33`, filter at
   `:160-164`). `x-no-audit` is consumed locally (§6.2) and is not in the
   outbound allowlist.
2. **Outbound, at the transport.** Converter-emitted headers are filtered
   to `content-type` and `accept`
   (`lib/shh_ai/provider_client/http_transport.ex:12`, filter at `:61-64`);
   dedup is by lowercased name, first occurrence wins (`:67-69`). The
   configured per-backend key is then injected — `x-api-key` +
   `anthropic-version` for Anthropic, `authorization: Bearer <key>` for
   OpenAI/Ollama (`http_transport.ex:126-134`). This is the chokepoint
   that guarantees the gate token and any client `authorization`/
   `x-api-key` never reach a backend (`http_transport.ex:44-50`).

**No client-key fallback:** the outbound credential is always the
resolved/pinned instance's own `config.api_key`, built from the selected
backend's config, not from the request
(`lib/shh_ai/provider_client.ex:227-230`; per-backend keys required at
`config.ex:342-360`).

**No passthrough headers in 0.1:** provider-specific headers (e.g.
`anthropic-beta`) are deliberately not forwarded; adding one is a
deliberate future change to the allowlist (`http_transport.ex:5-11`).

## 5. Admin dashboard

- Single operator credential: `ADMIN_USER`/`ADMIN_PASSWORD`
  (`lib/shh_ai/config.ex:520-531`). Login compares both values with
  `Plug.Crypto.secure_compare/2` and always runs both comparisons to
  keep timing uniform (`lib/shh_ai_web/controllers/admin_session_controller.ex:70-79`).
- Session gate: `:admin_authenticated` pipeline plus a LiveView
  `on_mount` re-check on the socket, so there is no unauthenticated
  back door into live pages; the socket gate re-checks configured-ness
  so a stale cookie cannot reach data after `ADMIN_PASSWORD` is unset
  (`lib/shh_ai_web/router.ex:71-86`; `lib/shh_ai_web/admin_auth.ex:32-56`).
- **Accepted: a single entry gate.** Any authenticated operator can open
  a conversation and see decrypted PII; there is no per-action re-auth
  (step-up auth is 0.2, issue #58). See §8, limitation 3.

## 6. Audit Mode (opt-in at rest)

### 6.1 Off by default, conditional datastore

Audit Mode is off by default; nothing is retained when off
(`config.ex:480`). `ShhAi.Repo` and the Cloak vault are supervision
children **only when `AUDIT_MODE=true`** — the default deployment is
DB-free, never opens or creates an audit database file
(`lib/shh_ai/application.ex:95-100`, `audit_repo_child/0`/`audit_vault_child/0`
at `:150-158`; ADR-0016, `docs/adr/0016-audit-persistence-conditional-on-audit-mode.md`).

### 6.2 Encrypted at rest, with client opt-out

- `mapping` and `sanitized_content` columns are encrypted via
  `ShhAi.Audit.Types.EncryptedBinary` (Cloak, AES-256-GCM, `tag: "v1"`;
  `lib/shh_ai/audit/types/encrypted_binary.ex:11`,
  `lib/shh_ai/audit/conversation_record.ex:29`,
  `lib/shh_ai/audit/conversation_message.ex:21`, `config/config.exs:44-48`).
  The mapping is serialised with `:erlang.term_to_binary/1` before
  encryption (`lib/shh_ai/audit/writer.ex:445-450`; ADR-0010).
- **`X-No-Audit` opt-out (ADR-0011):** detected case-insensitively per
  request (`provider_client.ex:447-456`), sticky (false→true only,
  `lib/shh_ai/conversation/store/ets.ex:268-288`) and retroactive — the
  Writer UPSERTs a tombstone (`opted_out=true, mapping=NULL`) and deletes
  that conversation's `conversation_messages` (`writer.ex:411-437`).
- **Defence in depth:** every Writer cast handler early-bails when
  audit mode is off, and message/mapping writes additionally check the
  per-conversation `opted_out` flag (`writer.ex:181-234`; moduledoc
  `writer.ex:14-21`). A reactivation sync read re-checks the persisted
  tombstone after an ETS entry expires (`writer.ex:266-298`).
- **Retention:** periodic cleanup deletes data older than
  `AUDIT_RETENTION_DAYS` (default 30) every `AUDIT_CLEANUP_INTERVAL_HOURS`
  (default 1) (`config.ex:485-490`; `writer.ex:33-38`, `:520-534`).
- **Events rows** (request metadata: timing, status, PII counts) persist
  only when audit is on; their `error` column is a JSON-encoded TEXT
  field (`lib/shh_ai/audit/event_record.ex:6-9`, `:33`).

### 6.3 Log and persisted-error redaction

Client-facing errors never echo provider or sanitizer internals: every
failure maps to a generic shape — 500 `"Internal proxy error"`, 404
naming only the model, 503 for pool exhaustion, and the two gate
messages (`proxy_controller.ex:113-149`; `proxy_auth.ex:33-39`). No raw
provider body is echoed to the client (`proxy_controller.ex:95-105`).

Persisted and logged failure detail is **redacted to a bounded error
class**: `ShhAi.ErrorClass.classify/1` collapses any reason to a small
documented atom set (`:econnrefused`, `:nxdomain`, `:econnreset`,
`:closed`, `:timeout`, `:transport_error`, `:http_error`,
`:model_not_served`, `:pii_sanitization_failed`, exception modules,
`:unknown`) and never returns message content
(`lib/shh_ai/error_class.ex:31-45`). The persisted audit `error_message`
uses it at every site (`proxy_controller.ex:124`,
`provider_client.ex:347`, `stream_transport.ex:126`), as do the
sanitize-failure logs (`pii_pipeline.ex:102`, `:267`).

Residual raw detail remains in a few operator-facing `Logger.error`
sites that log `inspect(reason)` (e.g. backend request/stream failures —
`http_transport.ex:95-97`, `stream_transport.ex:119`,
`provider_client.ex:116`, `:558-560`; model-catalog probe failures,
`model_catalog.ex:193-195`; conversation-store errors,
`conversation.ex:486-488`). These go to server logs only, not to
clients or the audit store, but an operator with log access may see
exception detail; treat the log sink as part of the trusted operator
boundary.

## 7. Retry/failover posture (ADR-0013 §5, issue #72)

Retry exists and is deliberately narrow. It fires **only** on a
connection-class transport failure (`:econnrefused`, `:nxdomain`,
`:econnreset`, `:closed`) — the provider instance was unreachable and
zero tokens were spent; receive-timeouts and provider HTTP 4xx/5xx are
never retried, so the provider's answer is never hidden and the request
is never double-billed (`provider_client.ex:359-372`).
Fallback draws uniformly at random from the model-aware pool, excluding
already-tried instances, until success or exhaustion
(`provider_client.ex:374-396`; `lib/shh_ai/target_provider.ex:43-50`).
Pool exhaustion returns a distinct ShhAi-originated 503
(`proxy_controller.ex:129-138`). Streaming retries only before the first
byte reaches the client; a mid-stream failure terminates the stream — no
silent restart, no duplicated chunks (`provider_client.ex:497-516`;
`stream_transport.ex:87-92`). **PII safety on retry:** the sanitized
canonical body and conversation mapping are reused verbatim; only the
target-dialect conversion re-runs — detection/NER never re-runs and the
sanitization guarantee is not re-evaluated against a different backend
(`provider_client.ex:398-425`; ADR-0013 §5 "PII re-entry — reuse the
mapping").

## 8. Accepted 0.1 limitations

These are known, accepted exposures in 0.1 (issue #58, "Accepted 0.1
limitations"). Reviewers should weigh them explicitly.

1. **Provider-hosted tool arguments are not sanitised.** The sanitizer
   walks `messages[].content` and `messages[].tool_calls[].function.arguments`
   only (`lib/shh_ai/pii/sanitizer.ex:483-486`, `:538-563`). Arguments
   executed by provider-hosted tools (web search, code interpreter,
   provider-side functions) are not represented in the canonical message
   body and reach the provider intact.
2. **Conversation identity is anchored on the first exchange only.**
   The fingerprint covers the first two messages (first user message +
   first assistant response) and derives the conversation UUID v5 from
   it (`docs/adr/0007-conversation-tracking.md`, "Modified history";
   `provider_client.ex:278-308`). Editing the first exchange starts a
   new conversation; edits to later messages do not. Practical upshot:
   the "same conversation" grouping — and the `X-No-Audit` opt-out, which
   is per-conversation — can be escaped by re-opening the exchange.
3. **Single dashboard entry gate.** Any authenticated operator sees
   decrypted PII on conversation-open; no step-up auth (§5, issue #52).
4. **TLS terminates outside the app.** ShhAi ships no in-app certificate
   management; production relies on the `force_ssl` posture
   (`rewrite_on: [:x_forwarded_proto]`, HSTS, `/health` and `/ready`
   excluded — `config/prod.exs:12-22`) and expects the operator's
   reverse proxy to terminate TLS (issue #52).
5. **Tool `definitions` are not sanitised.** The request `tools` array
   (names, descriptions, parameter schemas) is author-controlled and
   passes through the converters untouched
   (`lib/shh_ai/api_converter/anthropic.ex:31`, `:765`;
   `lib/shh_ai/api_converter/ollama.ex:32`, `:71`); the sanitizer never
   visits the top-level `tools` array — only messages
   (`pii_pipeline.ex:138-146`). Anything an author embeds in a tool
   description or schema goes to the backend verbatim.
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
