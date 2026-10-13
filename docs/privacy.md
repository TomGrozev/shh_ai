# Privacy

ShhAi is an LLM privacy proxy: it strips personally identifiable information
(PII) from traffic between your tools and LLM providers, then restores it on
the way back. This page says plainly what that does — and does not — cover.

For the operator-level threat analysis (trust boundaries, credential handling,
fail-closed policies), see `docs/threat-model.md`.

## What PII protection does

When `PII_ENABLED=true` (the default), every request body passing through the
proxy is sanitised before it reaches the backend provider:

- **Detection** runs two complementary detectors over the message contents:
  a regex-based detector (configurable types and confidence threshold) and,
  in the full image, a neural BERT-based NER detector. Together they look for
  16 types by default: name, location, email, phone, SSN, financial data,
  medical IDs, IP addresses, API keys, secrets, auth tokens, private keys,
  URLs, national IDs, device IDs, and passports. `PII_TYPES` narrows this set.
- **Replacement** swaps detected spans for reversible placeholders (e.g.
  `<EMAIL_1>`). The provider only ever sees the placeholders; the real values
  stay inside ShhAi.
- **Restoration** maps the placeholders back to the original values in the
  provider's response before it is returned to your tool, so the assistant's
  answer still reads correctly to the user.
- **Context-aware handling:** some types are preserved inside system messages
  (`PII_PRESERVE_IN_SYSTEM` — location, organization, date by default) where
  they carry instructions rather than personal data; the most sensitive types
  (`PII_ALWAYS_SANITIZE`) are sanitised regardless of context.
- **Conversation-aware mapping:** values are mapped per conversation, so the
  same person's email stays consistent across turns and is restored correctly.

## What PII protection does not cover

These are accepted 0.1 limitations. Know them before trusting the proxy with
sensitive traffic.

1. **Provider-hosted tools are not sanitised.** When the provider executes
   tools on its own side (web search, code interpreter, provider-side
   functions), those calls happen outside the proxy. Tool *arguments* for such
   tools reach the provider intact, unsanitised.
2. **Tool definitions are not sanitised.** The `tools` array in a request
   (names, descriptions, parameter schemas) is author-controlled and passes
   through untouched. Only message contents and the tool-call arguments of
   client-executed tools are visited by the sanitizer.
3. **First-exchange identity only.** Conversation identity (and with it the
   mapping that enables consistent placeholder/replacement) is anchored on a
   fingerprint of the first exchange only. Editing the *first* user message or
   assistant response starts a new conversation; edits to later messages do
   not — their PII mapping follows the original conversation.
4. **Detector false negatives are not blocked.** When a detector runs clean
   but misses PII, the value is forwarded silently — by design. 0.1 does not
   add an "uncertainty" signal to responses; misses are surfaced out-of-band,
   via the metrics and dashboards (and the detection benchmarks in
   `docs/benchmarks.md`), not by blocking the request.
5. **Audit Mode is opt-in.** By default nothing is persisted. If you want the
   encrypted audit trail (what was sanitised, per conversation), you must turn
   Audit Mode on and supply an encryption key — see Installation. Without it,
   there is no record of what the proxy saw.

## Detector failures: fail closed by default

If the PII detector itself fails hard (not "misses", but *errors*), the proxy
**blocks the request** rather than forward un-sanitised text — this is the
default (`PII_ERROR_MODE=block`).

Setting `PII_ERROR_MODE=forward` inverts this: on a detector error the request
is forwarded **un-sanitised**. This is a deliberate availability-over-privacy
trade-off and disables the proxy's central guarantee while set. Leave it at
`block` unless you have a specific reason.

## Audit Mode: what is stored, and how

When Audit Mode is on:

- A SQLite database (default path `priv/audit/audit.db`, or `AUDIT_DB_PATH` —
  point it at a mounted volume in containers) records conversations and
  messages.
- The PII **mapping** and the sanitised message contents are encrypted at rest
  with AES-256-GCM using `AUDIT_ENCRYPTION_KEY` (Base32, 32 bytes; required at
  boot when Audit Mode is on).
- A periodic job deletes records older than `AUDIT_RETENTION_DAYS`
  (default 30).
- Any conversation can opt out with an `X-No-Audit` header on a request: the
  opt-out is **sticky** (it cannot be un-set for that conversation) and
  **retroactive** — stored messages and the mapping for that conversation are
  deleted.

Note that anyone with the dashboard credential (`ADMIN_PASSWORD`) can open a
conversation in the admin dashboard and see decrypted PII — 0.1 has a single
entry gate, no step-up authentication. Treat the dashboard credential as
sensitive as the encryption key.

## What ShhAi is not

- **Not a TLS terminator.** Production deployments should terminate TLS at a
  reverse proxy in front of ShhAi; the app itself has no certificate
  management (it sets HSTS and redirects for configured paths only).
- **Not an anonymiser against the provider's other signals.** Sanitisation
  covers message text and client-side tool-call arguments. Request timing,
  model choice, conversation structure, and non-sanitised fields (tool
  definitions, provider-hosted tool arguments) still reach the provider.
- **Not perfect detection.** Regex plus NER substantially reduces PII leakage,
  but false negatives exist (see limitation 4) and false positives occur.
  Measure it for your workload with the eval suite in `docs/benchmarks.md`.

## Related docs

- `docs/installation.md` — getting ShhAi running, including Audit Mode setup.
- `docs/configuration.md` — every PII and audit environment variable.
- `docs/threat-model.md` — operator-level threat analysis and ADR links
  (in particular ADR-0007 conversation tracking, ADR-0011 audit opt-out,
  ADR-0014 fail-closed policy).
