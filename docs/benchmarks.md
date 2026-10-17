# Detection Benchmark

ShhAi's PII detection quality and latency, measured with a reproducible,
CI-excluded eval suite. The numbers here are refreshed per release from a run
on the pinned machine; this file is the standing record, not a versioned
artifact.

## Running it

```sh
mix test.eval test/eval/detection_accuracy_test.exs   # accuracy only
mix test.eval test/eval/latency_test.exs              # latency only
```

`mix test.eval` is a `test --only eval --color` alias, and the trailing path
restricts it to one suite; ticket #66 requires accuracy and latency to be
separate invocations, so there is no combined alias. The `:eval` tag is excluded in
`test/test_helper.exs`, so neither `mix test` nor CI runs it: the suite is slow
(NER inference over thousands of documents) and its timings are only meaningful
on the pinned machine, not on a shared CI runner.

## Dataset

[AI4Privacy `pii-masking-200k`](https://huggingface.co/datasets/ai4privacy/pii-masking-200k)
(English split, `english_pii_43k.jsonl`) — a public, synthetic, human-validated
corpus of assistant-style text with gold PII spans. It is **not vendored**: the
suite downloads it from the public HuggingFace mirror on first use and caches it
on the machine.

* Cache location: `$SHHAI_EVAL_CACHE_DIR`, default `~/.cache/shh_ai/eval`.
* Subset: a deterministic reservoir sample of **5,000 documents, seed 42**, so
  every run scores the same documents.

Each row carries `source_text` and a `privacy_mask` list of
`%{value, start, end, label}` gold annotations.

## Scoring

A predicted annotation is a **true positive** when it overlaps a gold
annotation **and** carries the same mapped type (span+type match). Matching is
one-to-one; unmatched predictions are false positives and unmatched gold
annotations are false negatives.

* **Micro** precision / recall / F1 across all types is the headline number.
* **Macro** precision / recall / F1 over the types present is reported as a
  secondary.
* A **per-type table** accompanies both.

The gold set is projected onto ShhAi's own type space by a hand-authored
per-label mapping (`test/eval/support/ai4privacy.ex`). The run enables **all
20 supported PII types** (`Config.supported_pii_types/0`), not the product
default list, so the score covers every type the detector can emit.

Mapping decisions:

* **Dropped** — `PREFIX` (honorifics), `ACCOUNTNAME` and `CREDITCARDISSUER`
  (label-like identifiers, not personal data).
* **Added** — `AGE` → `age`; `COMPANYNAME` → `organization`; `JOBTITLE` →
  `title`; the three crypto-address labels (`BITCOINADDRESS`,
  `ETHEREUMADDRESS`, `LITECOINADDRESS`) → `financial`.

Remaining dataset labels with no detector counterpart (gender, job area,
amounts, currencies, …) are dropped, so the score reflects the types ShhAi
claims to detect rather than the dataset's full taxonomy.

## Results

<!-- eval:accuracy:start -->
_Run: 2026-10-17T11:42:11.452591Z · dataset: AI4Privacy pii-masking-200k_
_(5000 docs, seed 42) · NER: on · PII types: all 20 supported_

**Micro** — precision 0.843,
recall 0.768, F1 0.804

**Macro** — precision 0.775,
recall 0.705, F1 0.719

| Type | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| age | 194 | 21 | 90 | 0.902 | 0.683 | 0.778 |
| date | 799 | 101 | 333 | 0.888 | 0.706 | 0.786 |
| device_id | 469 | 10 | 96 | 0.979 | 0.830 | 0.898 |
| email | 474 | 5 | 2 | 0.990 | 0.996 | 0.993 |
| financial | 1147 | 253 | 279 | 0.819 | 0.804 | 0.812 |
| ip_address | 832 | 23 | 1 | 0.973 | 0.999 | 0.986 |
| location | 1656 | 220 | 760 | 0.883 | 0.685 | 0.772 |
| name | 2038 | 582 | 413 | 0.778 | 0.831 | 0.804 |
| national_id | 0 | 10 | 0 | 0.000 | 0.000 | 0.000 |
| organization | 216 | 148 | 56 | 0.593 | 0.794 | 0.679 |
| phone | 270 | 162 | 13 | 0.625 | 0.954 | 0.755 |
| secret | 273 | 74 | 229 | 0.787 | 0.544 | 0.643 |
| ssn | 167 | 17 | 77 | 0.908 | 0.684 | 0.780 |
| title | 24 | 21 | 325 | 0.533 | 0.069 | 0.122 |
| url | 323 | 9 | 3 | 0.973 | 0.991 | 0.982 |

<!-- eval:accuracy:end -->

**Reading the numbers.** The step change from the previous release (strict
micro P 0.754 → 0.843, R 0.397 → 0.768, F1 0.520 → 0.804) comes from two
changes, not from the dataset or matching rule:

* **Regex fixes** (`lib/shh_ai/pii/patterns.ex`): phone is bounded by digit
  lookarounds, SSN requires separators, driver's licence now maps to
  `national_id`, IBAN matches real structure, ZIP/BIC/account-number matches
  require a context word, hyphenated IMEI is recognised, VIN sits at 0.80, and
  IPv6 patterns no longer fire on Elixir's `::` operator. Checksum validators
  (Luhn for card numbers and IMEIs, IBAN mod-97, US SSN structure) now gate
  the bare/unseparated forms, so a digit run is only reported when it is
  actually valid.
* **NER defaults** (`lib/shh_ai/config.ex`): confidence threshold 0.85 → 0.60
  and temperature 1.5 → 1.0 (see [NER threshold](#ner-threshold) below). The
  old combination effectively required a raw score of ~0.93, so most NER
  matches were silently dropped.

Remaining weak spots in the table above:

* `title` recall 0.069 — job titles are barely detected (JOBTITLE gold, little
  model support).
* `secret` recall 0.544 — bare passwords without a label escape.
* `location` recall 0.685 — the model has no street/ZIP labels.
* `phone` precision 0.625 and `organization` precision 0.593 — the noisiest
  types under the one-to-one span+type rule (see [Scoring](#scoring)):
  wrong-type predictions cost a false positive *and* leave their gold span
  unmatched.
* `national_id` has no gold annotations in this dataset revision, so its 10
  false positives are unscored noise.

Fragmented gold spans (FIRSTNAME+LASTNAME vs a single prediction) account for
only ~+0.015 recall; truncation is ruled out (median document 166 chars).

### NER threshold

The NER confidence threshold (0.60) and temperature (1.0) were tuned
off-benchmark: a held-out tuning sample (2,000 docs, seed 7, disjoint from the
seed-42 benchmark set) plus an **over-masking corpus** of 644 PII-free chunks
(this repo's `lib/` and `docs/` plus dependency READMEs, ~336k chars) that
measures how often the detector tags ordinary text. Key rows at T=1.0:

| Threshold | False hits / 1k chars (ordinary text) | % chunks hit | Masked-by-any-type recall (tuning) | Strict precision (tuning) |
|---|---:|---:|---:|---:|
| 0.30 | 1.09 | 25.0% | 0.883 | 0.765 |
| 0.50 | 0.92 | 23.4% | 0.870 | 0.795 |
| 0.55 | 0.64 | 18.5% | 0.853 | 0.814 |
| **0.60 (chosen)** | 0.49 | 16.0% | 0.832 | 0.828 |
| 0.65 | 0.33 | 12.4% | 0.816 | 0.841 |
| 0.80 | 0.12 | 4.5% | 0.735 | 0.875 |
| 0.85 (old, T=1.5) | n/a | n/a | 0.675 | 0.784 |

The detector keeps an unconfirmed NER hit's score unchanged, so the threshold
is the minimum score any NER-only detection can have.

0.60 is the knee: below it, ordinary-text false hits roughly double for a few
points of recall. Known accepted over-masking: common words can still be
tagged as names (e.g. "brown" at 0.75 in "The quick brown fox").

Re-sweep this threshold whenever the NER model or the regex set changes; the
numbers above are tied to the current model
(`gravitee-io/bert-small-pii-detection`).

**Latency** — the numbers below were re-measured for this release after two
NER changes: inputs are no longer padded to the model maximum (512 tokens) —
instead there is one serving per sequence-length bucket (32, 64, 128, 256,
512), each warmed at boot, so a short input is padded only up to the next
bucket; and text longer than 512 tokens is scanned in overlapping windows
(510 tokens, 64-token overlap) instead of being silently truncated. Both
changes trade boot time for per-request latency: warming five servings at
boot takes ~7–9 s instead of ~2–3 s, and a long text costs one model pass per
window.

| Scenario | p50 | p95 | Source |
|---|---:|---:|---|
| `ner_on` (short text) | 562 ms → **42 ms** | 674 ms → **66 ms** | Linux x64, 4-core container, 2 schedulers, `mix test.eval test/eval/latency_test.exs` |
| `ner_off` | not re-measured | not re-measured | same |

The M3 Pro table below predates these changes and is kept for continuity —
its absolute figures are not comparable to the row above (different machine
and different NER serving setup):

| Scenario | Median | Mean | Throughput | Source |
|---|---:|---:|---:|---|
| `ner_on` | 50.8 ms | 51.7 ms | 19.4/s | Apple M3 Pro (11 cores), macOS Tahoe, same suite |
| `ner_off` | 0.103 ms | 0.105 ms | 9,971/s | same run |

**Environment** — the M3 Pro table was taken on an Apple
M3 Pro laptop (11 cores) running macOS Tahoe; Elixir 1.19.4 on Erlang/OTP 28
(ERTS 16.1.2), EXLA 0.10 CPU backend (`:host` device). The p50/p95 figures
above were taken on Linux x64 in a 4-core container with 2 schedulers. The
accuracy block above reflects the current release.

The **accuracy** figures do not depend on the host: re-running the suite on
different hardware reproduced the table above to the digit, changing only the
timestamp. The **latency** figures do: NER inference is CPU-bound and
parallelises across cores, while the regex-only path does not, so the ratio
between the two is a property of the core count as much as of the detector.
Quote it with the machine it came from.

## Comparators

Published results from other open PII detectors, each citing its source. The
datasets and matching rules differ from ShhAi's, so these are context for the
state of the field, **not** a like-for-like comparison.

The rows below are **not comparable to each other**: the PrivAiTe rows
report recall over flat text, the pii-bench rows report span-level
precision/recall/F1 under a different matching rule, and each was
measured on a different dataset with a different type taxonomy. ShhAi's
own span+type recall on AI4Privacy (76.8%, [Results](#results) above) is
included in the last row so the numbers sit in one place — but the
metrics, datasets, and matching rules differ from every other row, so
read each row as a separate data point, not a ranking.

| Tool | Dataset | Metric | Value | Source |
|---|---|---|---|---|
| PrivAiTe (`onnx`, default) | AI4Privacy-family corpus (120 docs, independent auditors) | recall, flat text | 85.2% | [crp4222/PrivAiTe `docs/comparison.md`](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md) |
| Protect AI LLM Guard (Anonymize) | same corpus | recall, flat text | 76.9% | [crp4222/PrivAiTe `docs/comparison.md`](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md) |
| LiteLLM Presidio guardrail | same corpus | recall, flat text | 70.3% | [crp4222/PrivAiTe `docs/comparison.md`](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md) |
| cloud-ru-tech `guardrails-llm-filter` | [`hivetrace/pii-bench`](https://huggingface.co/datasets/hivetrace/pii-bench) (1,810 examples, 13 types) | span F1 / precision / recall | 93.1 / 99.9 / 87.2 | [cloud-ru-tech/guardrails-llm-filter README](https://github.com/cloud-ru-tech/guardrails-llm-filter#качество-на-бенчмарках) |
| GLiGuard pipeline (model + regex) | `hivetrace/pii-bench` | span F1 | 84.4 | [GLiNER Guard paper, arXiv 2605.05277](https://arxiv.org/abs/2605.05277) via the guardrails-llm-filter README |
| **ShhAi 0.1.0** | AI4Privacy `pii-masking-200k` (5,000 docs, seed 42) | micro recall, span+type match | 76.8% (F1 0.804) | [Results](#results) above (different dataset, type mapping, and matching rule — not comparable to the rows above) |

Notes:

* Each row's metric is exactly what its source publishes — "recall, flat
  text" means the detector flagged whether the document contained the
  PII at all, while "span F1 / precision / recall" requires the predicted
  span to match the gold span under that harness's rule. ShhAi's row
  uses the stricter span+type rule described under [Scoring](#scoring),
  which is why its number is not directly comparable to either.
* The PrivAiTe figures come from a reproducible benchmark over 120 documents
  labelled by independent auditors and report **recall only** (flat text); the
  same table reports tool-call-argument leakage, which is out of scope here.
* The `guardrails-llm-filter` figures are span-level over a Russian/English
  multi-dataset harness; F1 for the GLiGuard/GLiNER2 baselines is taken from the
  GLiNER Guard paper, which publishes F1 only.
* ShhAi's own numbers live in the [Results](#results) block above, scored
  against AI4Privacy `pii-masking-200k` with the span+type rule described under
  [Scoring](#scoring).
* **Contamination caveat for AI4Privacy rows:** detectors whose models were
  trained on the AI4Privacy family score optimistically on it — an
  AI4Privacy-tuned mDeBERTa drops from 76.9% to 62.4% recall out-of-distribution
  on a Gretel corpus ([PrivAiTe comparison](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md)).
  ShhAi's model (`gravitee-io/bert-small-pii-detection`) is **not** trained on
  AI4Privacy. NVIDIA's gliner-PII, also not trained on it, reports strict F1
  0.64 on AI4Privacy ([nvidia/gliner-PII](https://huggingface.co/nvidia/gliner-PII)).
