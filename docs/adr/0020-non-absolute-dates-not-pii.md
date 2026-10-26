# Non-absolute dates are not PII for the proxy

## Status

Accepted _(2026-10-26)_ — issue #79 (fine-tuned PII NER model). Amends
[ADR-0019](0019-heldout-neutral-quasi-identifiers.md).

## Context

The detector's `date` type covers every date-like surface the sources mark.
That includes surfaces that carry no individual-level date element:

* relative phrases ("the past two days"),
* durations ("five (5) years"),
* frequencies ("monthly"),
* placeholders ("this ___ day of ___, 20__").

Only a calendar date, a date of birth, a time or a year is a date element
tied to an individual, which is what the HIPAA Safe Harbor de-identification
list counts. Masking "the past two days" or "monthly" removes context the
downstream LLM needs without protecting anyone.

The single classifier for this is `date_class` in `training/pii_contract.py`.
When a surface is in doubt, it counts as absolute and stays `DATE`.

## Decision

**The proxy does not treat non-absolute dates as PII and does not mask them.**
They are not `DATE` in training, in the gold of the held-out benchmark, or in
the runtime output.

Concretely:

* **Benchmark.** `training/build_heldout.py` moves non-absolute gold `DATE`
  spans into `neutral` ranges (595 spans; the rebuilt file has sha256
  `f7edb039...908d`). A prediction on them counts as neither true positive
  nor false positive, by the [ADR-0019](0019-heldout-neutral-quasi-identifiers.md)
  neutral rule.
* **Training.** Non-absolute `DATE` spans are dropped from the gold in the
  gretel train and dev rows and in the Nemotron rows, so they train as `O`.
  The date oversampling quota (the 70% non-absolute DATE share of the gretel
  pool) is removed. Synthetic relative and placeholder dates are now `O`
  negatives, and `DATE_CLAUSE_SHARE` drops from 0.55 to 0.30.

Calendar dates, dates of birth, times and years stay `DATE` and stay masked.

## Consequences

### Positive

- The proxy stops masking text that carries no identifying date element, so
  prompts keep temporal context such as "monthly" or "the past two days".
- The `date` type now measures what it claims: dates tied to an individual.

### Negative

- **The held-out benchmark is not comparable with earlier runs.** Every
  held-out number published before this ADR, including the baselines in
  ADR-0018, ADR-0019 and [benchmarks](../benchmarks.md), was scored with
  non-absolute dates as gold and is not comparable with runs against the
  rebuilt file.
- A surface the classifier calls relative but a reader would call absolute
  leaves the prompt unmasked. The when-in-doubt rule bounds this: ambiguity
  resolves to `DATE`.
- The shipped model was not trained with this rule and still tags
  non-absolute dates, so its `date` false positives rise on the rebuilt
  benchmark. Re-training is required to realise the decision in the model.

### New baseline (rebuilt file, non-absolute dates neutral)

Micro F1 from `mix test.eval test/eval/heldout_accuracy_test.exs`; macro in
brackets.

| Model | overall | gretel-en | gretel-finance | TAB |
|---|---:|---:|---:|---:|
| shipped `gravitee-io/bert-small-pii-detection` | 0.742 (0.643), P 0.653 R 0.860 | 0.808 | 0.775 | 0.319 |
| fine-tuned `training/export/pii-ner` (run 2, commit 29dae60) | 0.696 (0.613), P 0.616 R 0.800 | 0.739 | 0.654 | 0.786 |

Date row on the rebuilt file: shipped F1 0.848. Per-source and per-type
numbers for both models are in
[benchmarks](../benchmarks.md#held-out-benchmark-heldout_v1).
