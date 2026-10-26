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

## Held-out benchmark (`heldout_v1`)

The AI4Privacy suite above measures the shipped model, but the model that
replaces it (issue #79) must be scored on data it was **never trained on** —
ai4privacy is deliberately absent from the training corpus. The held-out
benchmark fills that role: a deterministic, licensed-for-commercial-use set
built reproducibly by `python3 training/build_heldout.py` into
`~/.cache/shh_ai/eval/heldout_v1.jsonl` (`$SHHAI_EVAL_CACHE_DIR` honoured).

Run it with:

```sh
mix test.eval test/eval/heldout_accuracy_test.exs
```

(when the JSONL is absent the suite prints a skip notice instead of failing).
Swap models under test with `PII_NER_MODEL` / `PII_NER_MODEL_REVISION` and run
the suite twice for a like-for-like comparison against the shipped model.

### Sources and licences

| Source | Licence | Use |
|---|---|---|
| [gretelai/gretel-pii-masking-en-v1](https://huggingface.co/datasets/gretelai/gretel-pii-masking-en-v1) | Apache-2.0 | evaluation only |
| [gretelai/synthetic_pii_finance_multilingual](https://huggingface.co/datasets/gretelai/synthetic_pii_finance_multilingual) (English rows) | Apache-2.0 | evaluation only |
| [ildpil/text-anonymization-benchmark](https://huggingface.co/datasets/ildpil/text-anonymization-benchmark) (ECHR dev + test; train excluded) | MIT | evaluation only |

All three are evaluation-only: none appears in the training corpus
(`training/prepare_data.py` reads Nemotron-PII + synthetic only, and refuses
records whose provenance mentions ai4privacy).

### Shaping

1,000 documents (seed 79), already mapped into ShhAi's own type space, mixed
across buckets:

* 400 single gretel-en docs, 400 single gretel-finance docs.
* 120 single ECHR docs (naturally long) and 15 ECHR doc pairs joined until
  they clear the model's 512-token window.
* 65 gretel docs concatenated past 600 words (long-input coverage).
* 35% of all documents are wrapped as chat-style user messages ("Can you
  check the following text for personal data? …") so the set exercises the
  proxy's actual input shape.

Gold spans are validated, deduplicated (earliest-then-longest), and offset
rebuilt where the source gives surfaces but no offsets.

### Per-type gold counts

| Type | Gold spans |
|---|---:|
| date | 2087 |
| name | 1684 |
| organization | 786 |
| location | 738 |
| medical_id | 400 |
| email | 280 |
| ssn | 248 |
| financial | 252 |
| phone | 240 |
| ip_address | 179 |
| device_id | 124 |
| national_id | 55 |
| secret | 52 |
| passport | 17 |
| url | 3 |

`title` and `age` are absent — the sources carry no gold for them and the
per-type numbers for those two are **not measured** on this set (they remain
covered by the AI4Privacy suite above).

### Scoring and results

Scoring matches the AI4Privacy suite: span+type one-to-one matching, micro
F1 as the headline number, macro and per-type table alongside.

Each source is scored only on the types its gold covers
(`ShhAi.Eval.Scorer.score_by_source/1`), the rule the training dev metric
uses. The detector runs over every supported type, then each document is
projected onto the gold types of its source before scoring. TAB gold uses
`name` and `organization` only, so its ECHR `date` and `location` mentions are
not scored; per source, the gold types are:

| Source | Gold types |
|---|---|
| gretel-en | all types in the table above except `title`/`age` |
| gretel-finance | all types in the table above except `title`/`age` |
| TAB (ECHR) | `name` (279 spans), `organization` (3 spans) |

TAB annotates under its own policy: `DIRECT` mentions are gold, `QUASI`
(context-dependent) mentions are written to the file as `neutral` ranges, and
`NO_MASK` mentions are ordinary prose. A prediction that matches no gold span
but overlaps a neutral range is dropped from the score, so a hit on a
context-dependent name or place is neither required nor wrong (see
[ADR-0019](adr/0019-heldout-neutral-quasi-identifiers.md)). `NO_MASK` hits
stay false positives. The current file carries 6058 neutral ranges across its
135 TAB documents.

Because one source's policy can move an aggregate, the suite prints the
all-source headline and then one micro/macro block per source (gretel-en,
gretel-finance, TAB). Scores from runs against a file built before the neutral
ranges existed are not comparable with this table.

**Offset fix note.** `test/eval/support/heldout.ex` (`parse_line`) now
converts the gold codepoint offsets to UTF-8 byte offsets, the unit the
detector works in. Before this fix every non-ASCII document was scored
against gold spans shifted by the byte/codepoint difference: 21 gretel-en
docs, 106 gretel-finance docs and all 135 TAB docs. Every held-out number
published before this fix understate both models and are **not comparable**
with the table below.

**Non-absolute dates.** Relative phrases ("the past two days"), durations
("five (5) years"), frequencies ("monthly") and placeholder dates
("this ___ day of ___, 20__") are not PII for this proxy (see
[ADR-0020](adr/0020-non-absolute-dates-not-pii.md)): they do not identify a
person, so masking them only takes context from the LLM. The builder moves
the 595 non-absolute gold `DATE` spans into `neutral` ranges; a prediction on
them counts as neither true positive nor false positive. Calendar dates,
dates of birth, times and years stay `DATE` gold. Scores from runs against a
file built before this change are **not comparable** with the table below.

**Implausible gold spans dropped.** `training/build_heldout.py`
(`drop_implausible`) drops gretel gold spans that cannot be right:
punctuation-only spans, dates with no calendar word, and spans that cut a
word in half. The current written file drops 85 such spans (133 across the
fetched pool, which training also reads). Rebuilt file: sha256
`16a634e5...6fd4`, 6508 gold spans. Scores from runs against an earlier file
are **not comparable** with the table below.

| Model | Source | Micro P | Micro R | Micro F1 | Macro F1 |
|---|---|---:|---:|---:|---:|
| shipped `gravitee-io/bert-small-pii-detection` | all | 0.653 | 0.860 | 0.742 | 0.643 |
| shipped | gretel-en | | | 0.808 | |
| shipped | gretel-finance | | | 0.775 | |
| shipped | TAB (ECHR) | | | 0.319 | |
| fine-tuned `training/export/pii-ner` (run 2, commit 29dae60) | all | 0.616 | 0.800 | 0.696 | 0.613 |
| fine-tuned | gretel-en | | | 0.739 | |
| fine-tuned | gretel-finance | | | 0.654 | |
| fine-tuned | TAB (ECHR) | | | 0.786 | |

Selected per-type F1 on the rebuilt file. Shipped: date 0.848, location
0.887, name 0.792, organization 0.537, medical_id 0.366, url 0.023.
Fine-tuned: name 0.780, location 0.622, organization 0.435, medical_id
0.629, ip_address 0.937, email 0.922.

Per-source micro P/R are not recorded here; the suite prints them per run.
The headline P/R/F1 rows come from `mix test.eval
test/eval/heldout_accuracy_test.exs` on the rebuilt file.

The offset fix also moves the TAB picture: the shipped model now reaches TAB
micro F1 0.319 against the 282 gold spans, and the fine-tuned model 0.786.
Earlier analyses that counted TAB false positives by class (the 0.096/0.153
precision readings and the 64%/79% type-mismatch shares) were computed on
shifted gold and are kept in
[ADR-0019](adr/0019-heldout-neutral-quasi-identifiers.md) as the record of
that run, not as a current baseline. The per-source block keeps the TAB
weakness visible instead of blending it into the headline (see
[ADR-0019](adr/0019-heldout-neutral-quasi-identifiers.md)).

## AI4Privacy dataset

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

**RAM** — the latency suite also reports the memory the NER model adds,
measured across model load + EXLA warm-up: OS RSS (VmRSS from
`/proc/self/status`, Linux only) and the BEAM's own total
(`:erlang.memory/0`). Both deltas are printed by
`mix test.eval test/eval/latency_test.exs`, so the footprint of a swapped-in
fine-tune can be compared against the shipped model under the same
`PII_NER_MODEL` mechanism. When NER was already initialised by an earlier
suite in the same run the delta is ~0, and the notice says so.

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
