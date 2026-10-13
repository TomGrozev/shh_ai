# Detection Benchmark

ShhAi's PII detection quality and latency, measured with a reproducible,
CI-excluded eval suite. The numbers here are refreshed per release from a run
on the pinned machine; this file is the standing record, not a versioned
artifact.

## Running it

```sh
mix test.eval                      # accuracy + latency
mix test.eval test/eval/latency_test.exs   # latency only
```

`mix test.eval` is a `test --only eval` alias. The `:eval` tag is excluded in
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
_Not yet recorded on this branch. Run `mix test.eval` on the pinned machine to populate this block._
<!-- eval:accuracy:end -->

Latency (`NER-on` vs `NER-off`, Benchee) is printed to the console by
`test/eval/latency_test.exs`; record the summary alongside the accuracy table
above when refreshing this file.

## Comparators

Published results from other open PII detectors, each citing its source. The
datasets and matching rules differ from ShhAi's, so these are context for the
state of the field, **not** a like-for-like comparison.

| Tool | Dataset | Metric | Value | Source |
|---|---|---|---|---|
| PrivAiTe (`onnx`, default) | AI4Privacy-family corpus (120 docs, independent auditors) | recall, flat text | 85.2% | [crp4222/PrivAiTe `docs/comparison.md`](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md) |
| Protect AI LLM Guard (Anonymize) | same corpus | recall, flat text | 76.9% | [crp4222/PrivAiTe `docs/comparison.md`](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md) |
| LiteLLM Presidio guardrail | same corpus | recall, flat text | 70.3% | [crp4222/PrivAiTe `docs/comparison.md`](https://github.com/crp4222/PrivAiTe/blob/main/docs/comparison.md) |
| cloud-ru-tech `guardrails-llm-filter` | [`hivetrace/pii-bench`](https://huggingface.co/datasets/hivetrace/pii-bench) (1,810 examples, 13 types) | span F1 / precision / recall | 93.1 / 99.9 / 87.2 | [cloud-ru-tech/guardrails-llm-filter README](https://github.com/cloud-ru-tech/guardrails-llm-filter#качество-на-бенчмарках) |
| GLiGuard pipeline (model + regex) | `hivetrace/pii-bench` | span F1 | 84.4 | [GLiNER Guard paper, arXiv 2605.05277](https://arxiv.org/abs/2605.05277) via the guardrails-llm-filter README |

Notes:

* The PrivAiTe figures come from a reproducible benchmark over 120 documents
  labelled by independent auditors and report **recall only** (flat text); the
  same table reports tool-call-argument leakage, which is out of scope here.
* The `guardrails-llm-filter` figures are span-level over a Russian/English
  multi-dataset harness; F1 for the GLiGuard/GLiNER2 baselines is taken from the
  GLiNER Guard paper, which publishes F1 only.
* ShhAi's own numbers live in the [Results](#results) block above, scored
  against AI4Privacy `pii-masking-200k` with the span+type rule described under
  [Scoring](#scoring).
