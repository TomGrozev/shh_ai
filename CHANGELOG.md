# Changelog

## [Unreleased]

### Added

- **Configurable NER model** — `PII_NER_MODEL` (HuggingFace repo id or local
  path) and `PII_NER_MODEL_REVISION` select which Bumblebee token classifier
  the detector loads; the default remains
  `gravitee-io/bert-small-pii-detection`. The Dockerfile takes the same values
  as build args (it bakes that model into the image and loads it at boot), and
  CI's Bumblebee cache key derives from them
  ([ADR-0018](docs/adr/0018-fine-tuned-pii-ner-model.md), #79).
- **Held-out PII benchmark** (`heldout_v1`) — a 1,000-document evaluation set
  built reproducibly by `python training/build_heldout.py` from
  licence-clean sources (gretel-pii-masking-en-v1, synthetic_pii_finance_multilingual,
  text-anonymization-benchmark; evaluation-only, never trained on), scored by
  `mix test.eval test/eval/heldout_accuracy_test.exs` (#79).
- **Training pipeline** (`training/`) — Python fine-tune of
  `OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1` on Nemotron-PII (CC BY 4.0)
  plus a seeded synthetic generator, emitting BIO labels named after the
  supported PII types; GPU entrypoint `EPOCHS=3 BATCH_SIZE=16 ./run_gpu.sh`
  (#79).

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-13

The first release: a self-hosted LLM privacy proxy that intercepts provider
traffic, strips PII before forwarding, and restores it in the response.

### Added

- **Multi-provider proxy** — OpenAI, Anthropic, and Ollama API dialects, with
  free cross-conversion between a request's source and target format.
- **PII sanitisation pipeline** — regex and NER (Bumblebee BERT) detection in
  canonical (OpenAI) format, placeholder substitution, and restoration in both
  buffered and streaming responses.
  - Every top-level string field of the request (`tools` descriptions,
    `metadata`, `user`, ...) is sanitised on the same placeholder mapping as
    the messages; `messages`/`input` are handled by the message pipeline and
    `model` is left untouched, as are JSON-schema structural keys (`type`,
    `required`).
  - NER inputs are no longer padded to 512 tokens: per-length servings
    (32/64/128/256/512 tokens, warmed at boot) cut short-text latency from
    p50 562 ms to 42 ms (p95 674 → 66 ms; Linux x64, 4-core container,
    2 schedulers), at the cost of ~7–9 s boot NER load instead of ~2–3 s.
    Text longer than 512 tokens is scanned in overlapping windows (510
    tokens, 64-token overlap) instead of being silently truncated.
  - Checksum validators (Luhn for card numbers and IMEIs, IBAN mod-97, US
    SSN structure) gate the bare/unseparated pattern forms.
  - New `PII_NER_TYPE_THRESHOLDS` env var: per-type NER confidence floors
    (`title:0.4,date:0.5`); unlisted types keep
    `PII_NER_CONFIDENCE_THRESHOLD`, and a malformed entry fails boot.
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
