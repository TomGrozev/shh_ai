# PII NER fine-tuning pipeline

Python pipeline that fine-tunes a token-classifier for ShhAi's NER detector as
a drop-in replacement for the shipped `gravitee-io/bert-small-pii-detection`
model. The Elixir side needs no code change: the model is selected at runtime
by `PII_NER_MODEL` / `PII_NER_MODEL_REVISION` (see
[Configuration](../docs/configuration.md#pii-detection)), and the fine-tuned
model emits BIO labels whose names are the uppercase ShhAi PII types
(`B-NAME`, `I-LOCATION`, …), which the loader reads natively
(`training/pii_contract.py` is the single source of that label space).

## Model

* Base: [`OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1`](https://huggingface.co/OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1) (Apache-2.0).
* Training data: [`nvidia/Nemotron-PII`](https://huggingface.co/datasets/nvidia/Nemotron-PII) (CC BY 4.0) plus the seeded synthetic generator in `training/synthetic.py`, which tops up the contract types Nemotron under-covers (organization, financial, location, title, date).
* **ai4privacy is never trained on** — it stays the honest benchmark
  (`training/prepare_data.py` refuses records whose provenance mentions it).

## Layout

| File | Role |
|---|---|
| `pii_contract.py` | The shared contract: trained type set, BIO label order, span-JSONL record shape. Imported by every other module so nothing drifts. |
| `prepare_data.py` | Builds `train.jsonl` / `validation.jsonl` from Nemotron-PII + synthetic. The validation split is for early stopping / threshold selection only — it is not the held-out benchmark. |
| `synthetic.py` | Seeded synthetic record generator. |
| `train.py` | Fine-tunes the token classifier. Device: `--device auto|cuda|mps|cpu`, default `auto` (CUDA, else Apple MPS, else CPU). |
| `export.py` | Exports a Bumblebee-loadable model dir (bakes `id2label` into `config.json`); optional `--push-to-hub`. |
| `build_heldout.py` | Builds the held-out benchmark (`heldout_v1.jsonl`) — see [benchmarks](../docs/benchmarks.md#held-out-benchmark-heldout_v1). |
| `run_gpu.sh` | End-to-end GPU entrypoint: venv → prepare → train → export. |

## How training works

* The classifier head is warm-started from the base model's Nemotron head.
* All subtokens are labelled; pass `--first-subtoken-only` to label only the
  first subtoken of each span.
* Each record is split into 512-token windows with a 64-token overlap, which
  matches the runtime inference windowing.
* Each dev source is scored only on the entity types its own gold covers
  (same rule as the held-out eval), and per-type counts are pooled into
  macro F1. The training log prints a per-source block and a per-type table
  at each eval. Selection drives early stopping (patience 4).

## Data

`prepare_data.py` applies these rules when building `train.jsonl` and
`validation.jsonl`:

* Adjacent first/last name spans are merged into a single NAME span.
* Occupation strings that name an organisation are relabelled to ORGANIZATION.
* Synthetic data is capped at about 10% of the training set.
* Identifiers with labels the contract does not map become `ignore` ranges.
  An optional record key `"ignore": [[start, end], ...]` holds codepoint
  offsets; tokens inside those ranges are excluded from training.
* The dev set (`validation.jsonl`) is gretel-en and gretel finance rows
  outside the held-out benchmark plus a Nemotron slice. TAB is not used for
  dev: its gold marks only DIRECT mentions, so correct predictions of QUASI
  mentions would count as false positives. TAB stays in the held-out
  benchmark. The dev set is checked to be disjoint from the held-out set.

## Running

```sh
cd training && EPOCHS=5 BATCH_SIZE=16 ./run_gpu.sh
```

`run_gpu.sh` installs a venv (uv if present, else `python3 -m venv`), picks the
accelerator — a CUDA torch build when `nvidia-smi` is present, otherwise the
PyPI macOS arm64 wheel, which is already MPS-enabled — then runs prepare →
train → export and prints the exported model directory. If the installed torch
cannot run a CUDA op on the GPU (a CPU-only wheel, or a CUDA 13 wheel on a GPU
older than compute capability 7.5, such as Pascal), it reinstalls the CUDA 12.6
build. A machine with neither CUDA nor MPS is reported as CPU-only rather than
silently trained on the CPU.
Point the runtime at it with:

```sh
PII_NER_MODEL=/abs/path/to/training/export/pii-ner mix ...
```

Useful overrides (all optional): `VENV`, `DATA_DIR`, `OUTPUT_DIR`,
`EXPORT_DIR`, `SAMPLE` (Nemotron rows, 0 = all), `SYNTHETIC` (default 4000),
`EPOCHS` (5), `BATCH_SIZE` (16), `LR` (3e-5, encoder), `HEAD_LR` (2e-4,
classifier head), `EVAL_STEPS` (500), `WARMUP_RATIO` (0.05), `MAX_LENGTH`
(512), `STRIDE` (64), `SEED` (42), `PUSH_TO_HUB` (HF repo id; leave unset).

## Kaggle

A full run on a T4 takes an estimated 2 to 5 hours for 5 epochs, about 6 hours
at worst, inside the 12-hour limit. Recommended command:

```sh
PYTHONUNBUFFERED=1 bash run_gpu.sh 2>&1 | tee /kaggle/working/train.log
```

## Evaluating

Build the held-out set once, then run the Elixir eval:

```sh
python3 training/build_heldout.py     # -> ~/.cache/shh_ai/eval/heldout_v1.jsonl
mix test.eval test/eval/heldout_accuracy_test.exs
```

Compare the fine-tuned model against the shipped one by running the same eval
twice, with and without `PII_NER_MODEL` set. Licence note: the held-out
sources (gretel-pii-masking-en-v1 and synthetic_pii_finance_multilingual,
Apache-2.0; text-anonymization-benchmark, MIT) are **evaluation-only** — none
of them are used for training.

After training, tune the NER threshold again for the new model. The current
value is 0.60 in `lib/shh_ai/config.ex`.

## Licence / attribution

* Base model: Apache-2.0.
* Training corpus: Nemotron-PII is **CC BY 4.0**, which requires attribution.
  Attribution lives in the fine-tuned model's model card / HF README (state
  the base model, the Nemotron-PII corpus, and their licences); the repo name
  is TBD until the first GPU run lands.
