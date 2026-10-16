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
per-label mapping (`ShhAi.Eval.AI4Privacy.label_mapping/0`, in the suite). The
dataset's 54 classes collapse onto the detector's types; labels with no detector
counterpart (age, gender, job area, amounts, currencies, …) are dropped, so the
score reflects the types ShhAi claims to detect rather than the dataset's full
taxonomy.

## Results

<!-- eval:accuracy:start -->
_Run: 2026-10-13T16:47:31.920875Z · dataset: AI4Privacy pii-masking-200k_
_(5000 docs, seed 42) · NER: on_

**Micro** — precision 0.754,
recall 0.397, F1 0.520

**Macro** — precision 0.671,
recall 0.494, F1 0.507

| Type | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| date | 0 | 0 | 1132 | 0.000 | 0.000 | 0.000 |
| device_id | 135 | 2 | 430 | 0.985 | 0.239 | 0.385 |
| email | 474 | 0 | 2 | 1.000 | 0.996 | 0.998 |
| financial | 424 | 428 | 1006 | 0.498 | 0.297 | 0.372 |
| ip_address | 832 | 0 | 1 | 1.000 | 0.999 | 0.999 |
| location | 494 | 22 | 1922 | 0.957 | 0.204 | 0.337 |
| name | 1138 | 106 | 1693 | 0.915 | 0.402 | 0.559 |
| national_id | 0 | 2 | 0 | 0.000 | 0.000 | 0.000 |
| phone | 252 | 729 | 31 | 0.257 | 0.890 | 0.399 |
| secret | 175 | 15 | 327 | 0.921 | 0.349 | 0.506 |
| ssn | 138 | 128 | 106 | 0.519 | 0.566 | 0.541 |
| url | 323 | 1 | 3 | 0.997 | 0.991 | 0.994 |

<!-- eval:accuracy:end -->

**Why the headline recall is 0.397.** Micro recall is dragged down by three
types. `date` is never predicted at all (1,132 gold spans, zero predictions,
zero false positives), `location` finds 0.204 of its gold spans (1,922 missed),
and `name` 0.402 (1,693 missed). `phone` is the mirror image: recall 0.890 but
precision 0.257, from 729 false positives against 252 true positives. Under the
one-to-one span+type rule (see [Scoring](#scoring)) a prediction that overlaps
gold text of the wrong type is a false positive *and* leaves its gold span
unmatched, so over-prediction on one type is paid for twice. The types the
detector is confident about — `email`, `ip_address`, `url` — all sit at ≥0.99
precision and recall. The headline number therefore measures span-boundary and
type-mapping strictness at least as much as it measures missed PII.

**Latency** — NER-on vs NER-off (`Detector.detect/2` vs `Detector.detect/2,
mode: :regex_only`), measured with Benchee by `mix test.eval
test/eval/latency_test.exs` over 25 dataset documents (seed 7; warmup 2 s,
10 s per scenario, `parallel: 1`). Benchee reports one table per input, so the
values below are the per-input metrics aggregated across the 25 inputs
(median of medians; mean of means; ips as requests/second).

| Scenario | Median | Mean | Throughput | Source |
|---|---:|---:|---:|---|
| `ner_on` | 539 ms | 545 ms | 1.8/s | this machine, `mix test.eval test/eval/latency_test.exs` |
| `ner_off` | 0.25 ms | 0.29 ms | 3,520/s | same run |

NER inference is roughly **1,900×** the regex-only path on this workload
(per-input mean ratios ranged 1,475×–2,747×); 99th-percentile latencies were
598 ms (`ner_on`) and 0.60 ms (`ner_off`).

**Environment** — the "pinned machine" these numbers were taken from:
Intel(R) Xeon(R) Gold 6126 @ 2.60 GHz, 4 vCPU (cgroup quota), 39 GiB RAM,
Linux 6.18.54-talos (x86_64); Elixir 1.20.3 on Erlang/OTP 28 (ERTS 16.4.0.5),
EXLA 0.10 CPU backend (`:host` device). The accuracy and latency runs above
were taken on this machine in the same session; refresh both (they are separate
invocations) when the release numbers are re-pinned.

The host is modest — a 2017-vintage 2.6 GHz Xeon limited to 4 vCPU by a cgroup
quota. NER inference is CPU-bound, so read the **latency** figures as a
pessimistic floor rather than what current hardware delivers, and re-pin them on
a faster machine before quoting them. The **accuracy** figures do not depend on
the host.

## Comparators

Published results from other open PII detectors, each citing its source. The
datasets and matching rules differ from ShhAi's, so these are context for the
state of the field, **not** a like-for-like comparison.

The rows below are **not comparable to each other**: the PrivAiTe rows
report recall over flat text, the pii-bench rows report span-level
precision/recall/F1 under a different matching rule, and each was
measured on a different dataset with a different type taxonomy. ShhAi's
own span+type recall on AI4Privacy (0.397, [Results](#results) above) is
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
| **ShhAi 0.1.0** | AI4Privacy `pii-masking-200k` (5,000 docs, seed 42) | micro recall, span+type match | 39.7% | [Results](#results) above (different dataset, type mapping, and matching rule — not comparable to the rows above) |

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
