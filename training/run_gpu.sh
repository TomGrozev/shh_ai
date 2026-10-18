#!/usr/bin/env bash
# End-to-end GPU training entrypoint for the ShhAi PII NER model (issue #79).
#
# Runs: venv setup -> prepare_data -> train -> export, then prints the model
# directory that can be pointed at with PII_NER_MODEL (a local path is loaded
# via Bumblebee {:local, dir}).
#
# Requirements: an NVIDIA GPU with CUDA and a CUDA-enabled torch build, or an
# Apple Silicon Mac (Metal/MPS - the PyPI macOS arm64 torch wheel is already
# MPS-enabled). With neither, training runs on CPU, slowly; the script reports
# which accelerator it picked.
#
# Overridable environment variables:
#   VENV          venv directory           (default: .venv)
#   DATA_DIR      prepared JSONL dir       (default: data)
#   OUTPUT_DIR    trainer output dir       (default: outputs/run)
#   EXPORT_DIR    final Bumblebee model    (default: export/pii-ner)
#   SAMPLE        Nemotron rows to read    (default: 0 = all)
#   SYNTHETIC     synthetic record count   (default: 4000)
#   EPOCHS        training epochs          (default: 3)
#   BATCH_SIZE    per-device batch size    (default: 16)
#   LR            learning rate            (default: 5e-5)
#   MAX_LENGTH    max sequence length      (default: 512)
#   SEED          random seed              (default: 42)
#   PUSH_TO_HUB   HF repo id (leave unset) (default: unset)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

VENV="${VENV:-.venv}"
DATA_DIR="${DATA_DIR:-data}"
OUTPUT_DIR="${OUTPUT_DIR:-outputs/run}"
EXPORT_DIR="${EXPORT_DIR:-export/pii-ner}"
SAMPLE="${SAMPLE:-0}"
SYNTHETIC="${SYNTHETIC:-4000}"
EPOCHS="${EPOCHS:-3}"
BATCH_SIZE="${BATCH_SIZE:-16}"
LR="${LR:-5e-5}"
MAX_LENGTH="${MAX_LENGTH:-512}"
SEED="${SEED:-42}"

echo "==> setting up venv at ${VENV}"
if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.11 "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    uv pip install .
else
    python3 -m venv "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    python -m pip install --upgrade pip
    python -m pip install .
fi

# Prefer a CUDA-enabled torch if the CPU wheel was installed and a GPU exists.
if command -v nvidia-smi >/dev/null 2>&1 && ! python -c "import torch;assert torch.cuda.is_available()" 2>/dev/null; then
    echo "==> CUDA GPU detected; reinstalling torch with CUDA support"
    python -m pip install --force-reinstall --index-url https://download.pytorch.org/whl/cu124 torch
fi

# Report the accelerator, and on Apple Silicon make MPS ops that torch has not
# implemented fall back to CPU rather than aborting a multi-hour run.
if python -c "import torch;assert torch.cuda.is_available()" 2>/dev/null; then
    echo "==> accelerator: CUDA"
elif python -c "import torch;assert torch.backends.mps.is_available()" 2>/dev/null; then
    echo "==> accelerator: Apple GPU (MPS)"
    export PYTORCH_ENABLE_MPS_FALLBACK=1
else
    echo "!!! no CUDA and no MPS on this machine: training will run on CPU (slow)" >&2
fi

echo "==> preparing data (sample=${SAMPLE}, synthetic=${SYNTHETIC}, seed=${SEED})"
python prepare_data.py \
    --out-dir "$DATA_DIR" \
    --sample "$SAMPLE" \
    --synthetic "$SYNTHETIC" \
    --seed "$SEED"

echo "==> training (epochs=${EPOCHS}, batch=${BATCH_SIZE}, lr=${LR}, max_length=${MAX_LENGTH})"
python train.py \
    --train "$DATA_DIR/train.jsonl" \
    --validation "$DATA_DIR/validation.jsonl" \
    --output "$OUTPUT_DIR" \
    --epochs "$EPOCHS" \
    --batch-size "$BATCH_SIZE" \
    --learning-rate "$LR" \
    --max-length "$MAX_LENGTH" \
    --seed "$SEED"

echo "==> exporting to ${EXPORT_DIR}"
PUSH_ARG=()
if [[ -n "${PUSH_TO_HUB:-}" ]]; then
    PUSH_ARG=(--push-to-hub "$PUSH_TO_HUB")
fi
python export.py \
    --model "$OUTPUT_DIR/final" \
    --out "$EXPORT_DIR" \
    "${PUSH_ARG[@]}"

echo
echo "==> done. Bumblebee model directory:"
echo "    $(cd "$EXPORT_DIR" && pwd)"
echo "Point the runtime at it with:"
echo "    PII_NER_MODEL=$(cd "$EXPORT_DIR" && pwd) mix ..."
