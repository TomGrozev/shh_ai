# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-13

The first release: a self-hosted LLM privacy proxy that intercepts provider
traffic, strips PII before forwarding, and restores it in the response.

### Added

- **Multi-provider proxy** — OpenAI, Anthropic, and Ollama API dialects, with
  free cross-conversion between a request's source and target format.
- **PII sanitisation pipeline** — regex and NER (Bumblebee BERT) detection in
  canonical (OpenAI) format, placeholder substitution, and restoration in both
  buffered and streaming responses.
- **Model-aware provider selection** with per-conversation pinning, plus an
  ETS-backed model catalog probed from backend listings (ADR
  [0013](docs/adr/0013-provider-instance-pinning-and-model-aware-routing.md)).
- **Conversation tracking** — first-exchange fingerprinting with an
  ETS-or-Redis conversation store, accumulating a per-conversation PII mapping
  across turns (ADR [0007](docs/adr/0007-conversation-tracking.md)).
- **Audit Mode** — optional encrypted (AES-256-GCM, Cloak) SQLite audit store
  for admin review, with a per-request `X-No-Audit` opt-out; off by default, no
  PII retained when off (ADRs [0010](docs/adr/0010-sqlite-audit-mode-datastore.md),
  [0011](docs/adr/0011-audit-mode-x-no-audit-optout.md),
  [0016](docs/adr/0016-audit-persistence-conditional-on-audit-mode.md)).
- **Operator dashboard** — login-gated conversation queue, conversation
  slide-over, and PII detection review with flags.
- **Inbound API-key gate and outbound header allowlist** for the proxy, with
  per-backend credentials.
- **Health endpoints** — `/health` (liveness) and `/ready` (readiness, with NER
  load guaranteed by a boot-blocking fail-closed load).
- **Deployment** — `mix release` with an audit migration entrypoint
  (`ShhAi.Release.migrate/0`), pinned to Elixir 1.19.4 / OTP 28.
- **Documentation** — README, a hand-written `docs/` tree, and architecture
  decision records under `docs/adr/`.

[Unreleased]: https://github.com/TomGrozev/shh_ai/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/TomGrozev/shh_ai/releases/tag/v0.1.0
