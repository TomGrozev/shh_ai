# PII detector failure is fail-closed by default

## Status

Accepted _(2026-08-31)_ — resolves #48 (Audit Mode threat model and detector failure policy) for the standalone 0.1 release.

## Context

ShhAi's core trust claim is that PII never reaches the upstream provider un-sanitized. Two runtime failure modes threaten that claim, and they are fundamentally different:

1. **Hard error** — the PII pipeline throws or returns an error mid-sanitization (NER model unavailable, detector crash, malformed canonical body). Today `ShhAi.PIIPipeline.sanitize_openai_request/3` returns `{:error, :pii_sanitization_failed}`, which `ProviderClient.setup_context/6` propagates so the request fails to the client and no data leaves the proxy. This is *de facto* fail-closed, but incidental — nothing documents it as policy, and there is no operator escape hatch.
2. **False negative** — the detector runs cleanly but misses real PII. This is undetectable at request time by construction: the proxy cannot block on what it did not detect without rejecting every request. It is only observable post-hoc via detection metrics, the dashboard Flag, and the #46 benchmark.

The tension is privacy vs. availability: strict fail-closed means a detector outage takes down all proxying, which an operator may consciously not want during an incident.

## Decision

**Hard errors fail closed by default.** A pipeline error blocks the request (5xx); no request body is forwarded to the provider. This is promoted from incidental behaviour to stated policy.

**An operator escape hatch exists: `PII_ERROR_MODE` (default `block`).** Setting `PII_ERROR_MODE=forward` makes hard errors fail *open* — the request is forwarded un-sanitized, accepting a leak window — so an operator can consciously trade privacy for availability during a detector outage. The default is the safe one; fail-open is never silent-by-default.

**False negatives forward silently.** There is no runtime signal a false negative can produce; the request forwards. Detection accuracy is surfaced out-of-band (metrics, dashboard Flag, benchmark), not at request time. A runtime uncertainty signal is deferred to 0.2.

**The policy is documented in `docs/threat-model.md`** — the written threat model shipping in 0.1 (trust boundary; what is sanitized in transit; what is retained only under `AUDIT_MODE=true`, encrypted at rest, with per-conversation `X-No-Audit` override; and this fail policy). The threat model is the artifact #50 (security review) audits against.

## Consequences

### Positive

- The core trust claim holds by default: un-sanitized PII never reaches the provider unless the operator explicitly opts into fail-open.
- Operators retain an availability lever for detector outages without a code change or redeploy.
- #50 has a concrete, written policy to audit against.

### Negative

- `PII_ERROR_MODE=forward` is a foot-gun by design; the threat model must state plainly that it disables the proxy's central guarantee.
- False negatives remain a silent, accepted risk in 0.1, mitigated only after the fact.

### Neutral

- `PII_ERROR_MODE` joins the existing env-var config surface (`PII_ENABLED`, `AUDIT_MODE`, …) read via `ShhAi.Config`.
