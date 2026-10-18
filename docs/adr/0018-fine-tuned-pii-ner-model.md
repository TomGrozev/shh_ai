# Fine-tuned PII NER model

## Status

Proposed _(2026-10-18)_

Supersedes the model choice in
[ADR-0005](0005-ner-model-bumblebee-bert.md) (Bumblebee + bert-small-pii-
detection). Bumblebee as the serving stack is unchanged; what changes is which
model it loads. Issue #79.

## Context

ADR-0005 picked `gravitee-io/bert-small-pii-detection` (~110 MB) because it
ran locally via Bumblebee and supported 24 PII entity types. It was never
tuned for our type space: its label names must be remapped, and its quality on
the types ShhAi actually claims is uneven (see the weak spots in
[benchmarks](../benchmarks.md#results): `title` recall 0.069, `secret` 0.544,
`location` 0.685).

Issue #79 ran a bake-off of candidate base models:

| Candidate | Micro F1 (held-out) |
|---|---:|
| shipped `gravitee-io/bert-small-pii-detection` | 0.811 |
| OpenMed SuperClinical | 0.811 |
| **OpenMed ClinicalE5 (chosen)** | 0.764 |
| OpenMed ModernMed | 0.748 |
| GLiNER edge | 0.711 |

The bake-off scores the *base* models. ClinicalE5 was chosen not on the raw
number — it ties or trails the shipped model — but because it is Apache-2.0
(licensed for commercial use, unlike parts of the field), small enough for the
proxy's latency budget, and its fine-tune can be trained on data shaped
exactly like the product's input.

## Decision

Fine-tune `OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1` (Apache-2.0) as a
token classifier and make it a drop-in replacement for the shipped model,
selected at runtime through `PII_NER_MODEL` (HF repo id, or a local path
starting with `/` or `.`) and `PII_NER_MODEL_REVISION` (`ShhAi.Config`), with
the default still gravitee until the cutover.

* **Training data**: `nvidia/Nemotron-PII` (CC BY 4.0) plus a seeded synthetic
  generator (`training/synthetic.py`) that tops up the types Nemotron
  under-covers (organization, financial, location, title, date). Pipeline
  under `training/`; GPU entrypoint `cd training && EPOCHS=3 BATCH_SIZE=16
  ./run_gpu.sh`.
* **Honest test**: ai4privacy (`pii-masking-200k`) is **never trained on** —
  it stays the benchmark for the shipped model and the tuning harness.
  `training/prepare_data.py` refuses any record whose provenance mentions it.
* **Label map**: the fine-tuned model emits BIO labels whose names are the
  uppercase supported PII types (`B-NAME`, `I-LOCATION`, …; contract in
  `training/pii_contract.py`). Regex keeps api_key / auth_token / private_key,
  which stay out of the trained set. The Elixir loader reads the tag strings,
  so no remapping table is needed.
* **Acceptance gates (from #79)**: the fine-tuned model must (a) beat the
  shipped model's micro F1 on the held-out benchmark
  ([heldout_v1](../benchmarks.md#held-out-benchmark-heldout_v1) — sources
  themselves never trained on), (b) not regress NER latency beyond the
  budget of the shipped model on the pinned machine, and (c) not exceed the
  shipped model's added RAM materially (the latency eval reports the model's
  RSS/BEAM delta for exactly this comparison). Results are recorded once the
  GPU run lands.

## Licences and attribution

* Base model: Apache-2.0 — no attribution obligation beyond keeping the
  notice.
* Training corpus: Nemotron-PII is **CC BY 4.0**, which requires attribution.
  It lives in the fine-tuned model's model card / HF README, which names the
  base model, the Nemotron-PII corpus, and both licences. The HF repo name is
  TBD until the first GPU run lands.
* Held-out sets (gretel-pii-masking-en-v1 and synthetic_pii_finance_multilingual,
  Apache-2.0; text-anonymization-benchmark, MIT) are **evaluation-only**.

## Consequences

### Positive

* A model trained on the product's own type space and input shape, replacing
  the per-label remapping the shipped model needs.
* Fully commercial-usable model + training-data chain (Apache-2.0 / CC BY 4.0),
  unlike ai4privacy-trained alternatives whose contamination the comparators
  table already flags.
* A reproducible, non-ai4privacy benchmark to score any future model swap.

### Negative / follow-up work

* The confidence threshold must be **re-swept** for the new model's score
  distribution — the current 0.60 / T=1.0 pair was tuned for the shipped model
  ([NER threshold](../benchmarks.md#ner-threshold)); swap it back only with
  fresh over-masking numbers.
* The Dockerfile and CI model cache are keyed on the model: the Docker build
  takes `PII_NER_MODEL` / `PII_NER_MODEL_REVISION` build args (it bakes that
  model into the image and loads it at boot), and CI's Bumblebee cache key is
  derived from the same two values (`.github/workflows/ci.yaml`) — both must
  be set to the fine-tune when it ships, so the baked-in cache matches what
  the runtime loads.
* ~33M params vs ~110 MB gravitee changes boot load time and RAM; measured
  once the run lands.
