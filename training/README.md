# PII NER fine-tuning pipeline (issue #79)

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

## Running

```sh
cd training && EPOCHS=3 BATCH_SIZE=16 ./run_gpu.sh
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
`EPOCHS` (3), `BATCH_SIZE` (16), `LR` (5e-5), `MAX_LENGTH` (512), `SEED` (42),
`PUSH_TO_HUB` (HF repo id; leave unset).

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

## Licence / attribution

* Base model: Apache-2.0.
* Training corpus: Nemotron-PII is **CC BY 4.0**, which requires attribution.
  Attribution lives in the fine-tuned model's model card / HF README (state
  the base model, the Nemotron-PII corpus, and their licences); the repo name
  is TBD until the first GPU run lands.
