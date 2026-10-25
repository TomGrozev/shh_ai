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
#   EPOCHS        training epochs          (default: 5)
#   BATCH_SIZE    per-device batch size    (default: 16)
#   LR            encoder learning rate    (default: 3e-5)
#   HEAD_LR       classifier head LR       (default: 2e-4)
#   EVAL_STEPS    eval/save interval       (default: 500 steps)
#   WARMUP_RATIO  fraction of warmup steps (default: 0.05)
#   MAX_LENGTH    window length            (default: 512)
#   STRIDE        window overlap tokens    (default: 64, matches the runtime)
#   SEED          random seed              (default: 42)
#   PUSH_TO_HUB   HF repo id (leave unset) (default: unset)
#
# Kaggle T4 budget (measured on the full train split, 2026-10-25):
#   122,989 train records (94,989 Nemotron, 12,000 gretel-en, 12,000 gretel
#   finance, 4,000 synthetic) -> ~137k windows at 512/64 -> ~8.6k steps per
#   epoch at batch 16, ~43k steps for the 5-epoch default. A shuffled batch of
#   16 carries ~7.8k padded tokens, so one step is ~6 * 21.3M body params *
#   7.8k = 1.0 TFLOP. At an assumed 8-15 TFLOP/s effective fp16 on a T4 that
#   is 0.07-0.13 s of math per step; with dataloader and optimizer overhead
#   the real range is ~0.2-0.5 s, i.e. 2.6-6.4 h for 5 epochs. Eval every 500
#   steps adds ~86 evaluations of ~5.6k windows (~10 min), prepare_data
#   ~35 min (mostly the dataset download). Worst case ~7 h, inside Kaggle's
#   12 h cap; early stopping usually cuts it. The assumption to recheck is
#   the token count: doubling the corpus doubles the estimate.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

VENV="${VENV:-.venv}"
DATA_DIR="${DATA_DIR:-data}"
OUTPUT_DIR="${OUTPUT_DIR:-outputs/run}"
EXPORT_DIR="${EXPORT_DIR:-export/pii-ner}"
SAMPLE="${SAMPLE:-0}"
SYNTHETIC="${SYNTHETIC:-4000}"
EPOCHS="${EPOCHS:-5}"
BATCH_SIZE="${BATCH_SIZE:-16}"
LR="${LR:-3e-5}"
HEAD_LR="${HEAD_LR:-2e-4}"
EVAL_STEPS="${EVAL_STEPS:-500}"
WARMUP_RATIO="${WARMUP_RATIO:-0.05}"
MAX_LENGTH="${MAX_LENGTH:-512}"
STRIDE="${STRIDE:-64}"
SEED="${SEED:-42}"

echo "==> setting up venv at ${VENV}"
if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.11 "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    # --python pins the target: UV_SYSTEM_PYTHON (set on Kaggle) otherwise
    # sends installs to the system interpreter instead of the active venv.
    uv pip install --python "$VENV/bin/python" .
else
    python3 -m venv "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    python -m pip install --upgrade pip
    python -m pip install .
fi

# torch.cuda.is_available() only proves the driver loads: a torch build with no
# kernels for this GPU's architecture still reports True, then fails on the
# first op (cudaErrorNoKernelImageForDevice). Running one op checks both.
cuda_works() {
    python -c "import torch;(torch.ones(1, device='cuda') + 1).item()" 2>/dev/null
}

# The default PyPI torch is CPU-only or built for recent GPUs only (CUDA 13
# wheels need compute capability 7.5+). If it cannot run on this GPU, switch to
# the CUDA 12.6 build, which still ships kernels for Maxwell, Pascal and Volta.
if command -v nvidia-smi >/dev/null 2>&1 && ! cuda_works; then
    echo "==> CUDA GPU detected but torch cannot run on it; reinstalling torch built for CUDA 12.6"
    # A uv-made venv has no pip, so reinstall through the same installer.
    if command -v uv >/dev/null 2>&1; then
        uv pip install --python "$VENV/bin/python" --reinstall --index-url https://download.pytorch.org/whl/cu126 torch
    else
        python -m pip install --force-reinstall --index-url https://download.pytorch.org/whl/cu126 torch
    fi
fi

# Report the accelerator, and on Apple Silicon make MPS ops that torch has not
# implemented fall back to CPU rather than aborting a multi-hour run.
if cuda_works; then
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

echo "==> training (epochs=${EPOCHS}, batch=${BATCH_SIZE}, lr=${LR}, head_lr=${HEAD_LR}, eval_steps=${EVAL_STEPS}, max_length=${MAX_LENGTH}, stride=${STRIDE})"
python train.py \
    --train "$DATA_DIR/train.jsonl" \
    --validation "$DATA_DIR/validation.jsonl" \
    --output "$OUTPUT_DIR" \
    --epochs "$EPOCHS" \
    --batch-size "$BATCH_SIZE" \
    --learning-rate "$LR" \
    --head-learning-rate "$HEAD_LR" \
    --eval-steps "$EVAL_STEPS" \
    --warmup-ratio "$WARMUP_RATIO" \
    --max-length "$MAX_LENGTH" \
    --stride "$STRIDE" \
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
