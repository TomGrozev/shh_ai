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

Two sizes are available, selected with `MODEL_SIZE` in `run_gpu.sh`
(`small` by default, `large` for the 109M variant):

* `small`: [`OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1`](https://huggingface.co/OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1) (33M, Apache-2.0), 5 epochs, exported to `training/export/pii-ner`.
* `large`: [`OpenMed/OpenMed-PII-ClinicalE5-Base-109M-v1`](https://huggingface.co/OpenMed/OpenMed-PII-ClinicalE5-Base-109M-v1) (BERT, 109M, Apache-2.0, same 106-label head and warm-start map), 3 epochs, exported to `training/export/pii-ner-large`. It costs about 3 to 4 times the CPU latency and memory of the small model (estimate).

Pick the model at runtime with `PII_NER_MODEL` (a local path or an HF repo id).

* Training data: [`nvidia/Nemotron-PII`](https://huggingface.co/datasets/nvidia/Nemotron-PII) (CC BY 4.0), a share of the two gretel sources the held-out benchmark is built from, and the seeded synthetic generator in `training/synthetic.py`, which tops up the contract types Nemotron under-covers (organization, financial, location, title, date).
* **ai4privacy is never trained on** — it stays the honest benchmark
  (`training/prepare_data.py` refuses records whose provenance mentions it).

## Layout

| File | Role |
|---|---|
| `pii_contract.py` | The shared contract: trained type set, BIO label order, span-JSONL record shape. Imported by every other module so nothing drifts. |
| `prepare_data.py` | Builds `train.jsonl` / `validation.jsonl` from Nemotron-PII, gretel-en, gretel finance and synthetic. The validation split is for early stopping / threshold selection only; it is not the held-out benchmark. |
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
  macro F1. Predicted spans are decoded the way the runtime groups tokens
  and matched to gold spans by overlap and same type, one-to-one per
  document. Macro F1 over types is the checkpoint-selection metric; early
  stopping uses it too (patience 4).

## Data

`prepare_data.py` applies these rules when building `train.jsonl` and
`validation.jsonl`:

* Adjacent first/last name spans are merged into a single NAME span.
* Adjacent Nemotron address parts (street, city, state, postcode, country)
  separated only by commas and spaces merge into one LOCATION span, even when
  the parts carry different labels, so `California, USA` merges. Same-label
  pairs (`Portland, Seattle`) stay separate. A merge does not require a
  street_address or postcode anchor any more. This matches gretel gold, which
  marks a whole address as one span.
* A lone numeric address part (a bare postcode like `97205`) is dropped from
  the gold and trains as `O`. The run prints how many parts this drops
  (`numeric_address_parts`). This trades a little location recall for fewer
  false positives on bare digit runs.
* Nemotron `api_key` values train as `O`: the label is ignored, matching both
  gretel maps, which drop `api_key` too.
* Occupation strings that name an organisation are relabelled to ORGANIZATION.
* Non-absolute DATE spans (relative phrases, durations, frequencies,
  placeholders) are dropped from the gold in the gretel train and dev rows
  and in the Nemotron rows, so they train as `O`: they do not identify a
  person and the proxy does not mask them (see
  [ADR-0020](../docs/adr/0020-non-absolute-dates-not-pii.md)). Calendar
  dates, dates of birth, times and years stay `DATE`. The classifier is
  `date_class` in `pii_contract.py`; a surface in doubt counts as absolute.
* The gretel pool is sampled by quota, not at random: for gretel finance 40%
  of taken rows carry two or more ORGANIZATION spans. The run prints the
  actual take against each quota under `--- gretel pool composition ---`.
* Synthetic data is capped at about 10% of the training set. It adds
  whole-address spans, company names with legal suffixes and descriptive
  organisation names ("Association of X", "IT department"), and
  financial-message blocks (SWIFT MT940, XBRL, FpML) whose tag values and
  namespace URLs stay unlabelled, matching the benchmark gold. It also emits
  negatives: bare numbers, hex digests, namespace URLs, and relative and
  placeholder dates ("last month", "this ______ day of ________, 20__"),
  which must train as `O` because non-absolute dates are not PII (see
  [ADR-0020](../docs/adr/0020-non-absolute-dates-not-pii.md)).
* Identifiers with labels the contract does not map become `ignore` ranges.
  An optional record key `"ignore": [[start, end], ...]` holds codepoint
  offsets; tokens inside those ranges are excluded from training.
* Implausible gretel gold spans (found by `build_heldout.py`'s
  `drop_implausible`: punctuation-only spans, dates with no calendar word,
  and spans that cut a word in half) are removed from the gretel train rows
  and written as `ignore` ranges instead of training as `O`. The run prints
  the count under `implausible spans written as ignore ranges`. The dev split
  still trains them as `O`.
* The training split also takes gretel-en and gretel finance rows (flags
  `--gretel-en-train` and `--gretel-fin-train`, 30,000 and 23,000 by default;
  `--nemotron-train` caps the Nemotron rows at 50,000). 23,000 is the finance
  ceiling: once the rows near the benchmark's and the dev set's fetch windows
  are excluded, about 51% of the remaining rows are English with spans. They
  are read from offsets beyond the benchmark's and the dev set's fetch
  windows, and a hash check proves train, dev and held-out are pairwise
  disjoint.
* After the build, `prepare_data.py` prints label statistics under
  `--- DATE surface classes ---` and related sections: DATE surface classes,
  organization spans per document, location split rate, numeric LOCATION
  spans, and bare 2-5 digit numbers left as `O`.
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
`EXPORT_DIR`, `MODEL_SIZE` (`small` | `large`), `SAMPLE` (Nemotron rows, 0 =
all), `NEMOTRON_TRAIN` (50000), `GRETEL_EN_TRAIN` (30000),
`GRETEL_FIN_TRAIN` (23000), `SYNTHETIC` (default 4000),
`EPOCHS` (5), `BATCH_SIZE` (16), `LR` (3e-5, encoder), `HEAD_LR` (2e-4,
classifier head), `EVAL_STEPS` (500), `WARMUP_RATIO` (0.05), `MAX_LENGTH`
(512), `STRIDE` (64), `SEED` (42), `PUSH_TO_HUB` (HF repo id; leave unset).

## Kaggle

A full run is about 107,000 train records (50,000 Nemotron, 30,000
gretel-en, 23,000 gretel finance, 4,000 synthetic) and about 800 validation
records, which split into roughly 113k training windows. On a T4 that is
about 2.2 to 5.3 hours for 5 epochs (small) or 3 epochs (large), plus about
40 minutes of data fetch, inside the 12-hour limit. Kaggle cells:

```sh
# small (default): OpenMed-PII-ClinicalE5-Small-33M-v1, 5 epochs
!cd /kaggle/working/shh_ai/training && PYTHONUNBUFFERED=1 bash run_gpu.sh 2>&1 | tee /kaggle/working/train.log

# large: OpenMed-PII-ClinicalE5-Base-109M-v1, 3 epochs
!cd /kaggle/working/shh_ai/training && MODEL_SIZE=large PYTHONUNBUFFERED=1 bash run_gpu.sh 2>&1 | tee /kaggle/working/train-large.log
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

After training, `train.py` searches each type's confidence threshold
(0.30-0.95, step 0.05, plus 0.0 for argmax) on the dev set with the benchmark
span rule and writes the result to `pii_thresholds.json` in the training
output; `export.py` copies it into the export directory. The runtime loads
that file at boot and applies it per type (see
[Configuration](../docs/configuration.md#pii-detection)), so no hand tuning
of `PII_NER_CONFIDENCE_THRESHOLD` is needed.

## Licence / attribution

* Base model: Apache-2.0.
* Training corpus: Nemotron-PII is **CC BY 4.0**, which requires attribution.
  Attribution lives in the fine-tuned model's model card / HF README (state
  the base model, the Nemotron-PII corpus, and their licences); the repo name
  is TBD until the first GPU run lands.
