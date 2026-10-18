"""Fine-tune a BERT token classifier for PII detection.

Base model: ``OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1`` (Apache-2.0,
``BertForTokenClassification``, hidden 384, ~33M params, fast tokenizer).
The classifier head is re-initialised to the contract label set
(:mod:`pii_contract`), so the trained model emits exactly the BIO tags the
ShhAi runtime understands.

Runs on CPU (for smoke runs) and on a single CUDA GPU. fp16 is enabled
automatically when CUDA is available; disable with ``--no-fp16``.

Examples
--------
    # GPU, full run
    python train.py --train data/train.jsonl --validation data/validation.jsonl \
        --output outputs/run1

    # CPU smoke
    python train.py --train data/train.jsonl --validation data/validation.jsonl \
        --output /tmp/smoke --max-steps 20 --batch-size 4 --max-length 128
"""

from __future__ import annotations

import argparse
import inspect
import os

import numpy as np
import torch
from torch.utils.data import Dataset

from pii_contract import ID2LABEL, LABEL2ID, LABELS, Record, read_jsonl

BASE_MODEL = "OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1"
O_ID = LABEL2ID["O"]


# --------------------------------------------------------------------------
# Offset handling
# --------------------------------------------------------------------------
def _detect_byte_offsets(text: str, offsets: list[tuple[int, int]]) -> bool:
    """Fast tokenizers may report offsets in bytes; detect which unit we got.

    If the text is pure ASCII the two coincide, so the answer only matters
    for multibyte text, where a byte end offset can exceed the codepoint
    length of the text.
    """
    max_end = max((e for _s, e in offsets if e is not None), default=0)
    return max_end > len(text)


def _byte_index(text: str) -> list[int]:
    """Cumulative UTF-8 byte length per codepoint boundary."""
    out = [0] * (len(text) + 1)
    for i, ch in enumerate(text):
        out[i + 1] = out[i] + len(ch.encode("utf-8"))
    return out


def _best_span(spans, s: int, e: int):
    """Index of the span with the greatest overlap with token [s, e)."""
    best, best_ov = None, 0
    for i, (ss, se, _t) in enumerate(spans):
        ov = min(e, se) - max(s, ss)
        if ov > best_ov:
            best_ov, best = ov, i
    return best


def _spans_in_unit(rec: Record, byte_offsets: bool):
    if not byte_offsets:
        return [(s.start, s.end, s.type) for s in rec.spans]
    bi = _byte_index(rec.text)
    return [(bi[s.start], bi[s.end], s.type) for s in rec.spans]


def align(rec: Record, tokenizer, max_length: int, label_all_subtokens: bool):
    """Tokenize ``rec`` and build token labels via offset mapping.

    ``label_all_subtokens=False`` (default): only the first subtoken of each
    word is labelled; continuations get ``-100`` (ignored by the loss).
    ``label_all_subtokens=True``: every subtoken overlapping a span is
    labelled ``B-``/``I-``.

    Returns ``(encoding, labels, uncovered_spans)`` where ``uncovered_spans``
    counts annotated spans no token overlapped (dropped silently by the loss,
    so the caller can warn).
    """
    enc = tokenizer(
        rec.text,
        truncation=True,
        max_length=max_length,
        return_offsets_mapping=True,
        add_special_tokens=True,
    )
    offsets = enc["offset_mapping"]
    word_ids = enc.word_ids()
    spans = _spans_in_unit(rec, _detect_byte_offsets(rec.text, offsets))

    labels: list[int] = []
    covered: set[int] = set()
    prev_span = None
    prev_word = None
    for i, (s, e) in enumerate(offsets):
        wid = word_ids[i]
        if wid is None or s == e:  # special token or empty
            labels.append(-100)
            prev_span = None
            prev_word = None
            continue
        if not label_all_subtokens and wid == prev_word:
            labels.append(-100)
            prev_word = wid
            continue
        idx = _best_span(spans, s, e)
        if idx is None:
            labels.append(O_ID)
            prev_span = None
        else:
            covered.add(idx)
            prefix = "B" if idx != prev_span else "I"
            labels.append(LABEL2ID[f"{prefix}-{spans[idx][2].upper()}"])
            prev_span = idx
        prev_word = wid

    enc.pop("offset_mapping", None)
    return enc, labels, len(spans) - len(covered)


class SpanDataset(Dataset):
    """Lazily tokenizes contract records into token-classification features."""

    def __init__(self, records, tokenizer, max_length: int, label_all_subtokens: bool):
        self.records = records
        self.tokenizer = tokenizer
        self.max_length = max_length
        self.label_all_subtokens = label_all_subtokens
        self.uncovered = 0

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, idx: int):
        enc, labels, uncovered = align(
            self.records[idx], self.tokenizer, self.max_length, self.label_all_subtokens
        )
        self.uncovered += uncovered
        enc["labels"] = labels
        return enc


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------
def _make_compute_metrics():
    from seqeval.metrics import f1_score, precision_score, recall_score

    def compute_metrics(eval_pred):
        logits, labels = eval_pred[0], eval_pred[1]
        preds = np.argmax(logits, axis=-1)
        true_labels, true_preds = [], []
        for pred_row, lab_row in zip(preds, labels):
            tl, tp = [], []
            for p, l in zip(pred_row, lab_row):
                if l == -100:
                    continue
                tl.append(LABELS[l])
                tp.append(LABELS[p])
            true_labels.append(tl)
            true_preds.append(tp)
        return {
            "precision": precision_score(true_labels, true_preds),
            "recall": recall_score(true_labels, true_preds),
            "f1": f1_score(true_labels, true_preds),
        }

    return compute_metrics


# --------------------------------------------------------------------------
# Device selection
# --------------------------------------------------------------------------
def _select_device(preference: str = "auto") -> torch.device:
    """Resolve the training device: CUDA, else Apple MPS, else CPU.

    ``transformers`` picks MPS by itself, but this pipeline never said so: on an
    Apple Silicon Mac the run logged ``device=cpu`` while actually training on
    the GPU. Resolve it in one place and pin it below so the log and the
    compute cannot disagree.
    """
    if preference != "auto":
        return torch.device(preference)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available() \
            and torch.backends.mps.is_built():
        return torch.device("mps")
    return torch.device("cpu")


# --------------------------------------------------------------------------
# TrainingArguments compatibility across transformers versions
# --------------------------------------------------------------------------
def _training_arguments(**kwargs):
    from transformers import TrainingArguments

    params = inspect.signature(TrainingArguments.__init__).parameters
    if "eval_strategy" not in params and "evaluation_strategy" in params:
        kwargs["evaluation_strategy"] = kwargs.pop("eval_strategy")
    return TrainingArguments(**kwargs)


def _build_trainer(model, args, train_ds, eval_ds, tokenizer):
    from transformers import DataCollatorForTokenClassification, Trainer

    collator = DataCollatorForTokenClassification(tokenizer)
    trainer_kwargs = dict(
        model=model,
        args=args,
        train_dataset=train_ds,
        eval_dataset=eval_ds,
        data_collator=collator,
        compute_metrics=_make_compute_metrics(),
    )
    # ``tokenizer=`` was renamed to ``processing_class=`` in transformers 4.46+.
    if "processing_class" in inspect.signature(Trainer.__init__).parameters:
        trainer_kwargs["processing_class"] = tokenizer
    else:
        trainer_kwargs["tokenizer"] = tokenizer
    return Trainer(**trainer_kwargs)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--train", default=os.path.join(os.path.dirname(__file__), "data/train.jsonl"))
    ap.add_argument("--validation", default=os.path.join(os.path.dirname(__file__), "data/validation.jsonl"))
    ap.add_argument("--output", required=True, help="output dir (checkpoints + final model)")
    ap.add_argument("--base-model", default=BASE_MODEL)
    ap.add_argument("--max-length", type=int, default=512)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--eval-batch-size", type=int, default=32)
    ap.add_argument("--learning-rate", type=float, default=5e-5)
    ap.add_argument("--epochs", type=float, default=3.0)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--warmup-ratio", type=float, default=0.1)
    ap.add_argument("--max-steps", type=int, default=-1, help="smoke runs; -1 = full")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--label-all-subtokens", action="store_true",
                    help="label every subtoken (default: first subtoken only)")
    ap.add_argument("--no-fp16", action="store_true")
    ap.add_argument("--device", default="auto", choices=("auto", "cuda", "mps", "cpu"),
                    help="training device (auto = cuda, else mps, else cpu)")
    ap.add_argument("--threads", type=int, default=0,
                    help="torch/OMP thread cap (0 = leave as-is)")
    args = ap.parse_args(argv)

    if args.threads:
        torch.set_num_threads(args.threads)
        os.environ.setdefault("OMP_NUM_THREADS", str(args.threads))

    from transformers import AutoModelForTokenClassification, AutoTokenizer

    train_records = read_jsonl(args.train)
    eval_records = read_jsonl(args.validation)
    print(f"[train] {len(train_records)} train / {len(eval_records)} validation records")

    tokenizer = AutoTokenizer.from_pretrained(args.base_model, use_fast=True)
    if not tokenizer.is_fast:
        raise SystemExit(f"{args.base_model} has no fast tokenizer; Bumblebee needs tokenizer.json")

    model = AutoModelForTokenClassification.from_pretrained(
        args.base_model,
        num_labels=len(LABELS),
        id2label=ID2LABEL,
        label2id=LABEL2ID,
        ignore_mismatched_sizes=True,
    )

    train_ds = SpanDataset(train_records, tokenizer, args.max_length, args.label_all_subtokens)
    eval_ds = SpanDataset(eval_records, tokenizer, args.max_length, args.label_all_subtokens)

    device = _select_device(args.device)
    # fp16 is a CUDA-only path here: Trainer has no MPS fp16 autocast, and CPU
    # fp16 is slower than fp32.
    use_fp16 = device.type == "cuda" and not args.no_fp16

    training_args = _training_arguments(
        use_cpu=device.type == "cpu",
        output_dir=args.output,
        overwrite_output_dir=True,
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.eval_batch_size,
        learning_rate=args.learning_rate,
        num_train_epochs=args.epochs,
        weight_decay=args.weight_decay,
        warmup_ratio=args.warmup_ratio,
        max_steps=args.max_steps,
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=2,
        load_best_model_at_end=True,
        metric_for_best_model="f1",
        greater_is_better=True,
        logging_steps=50,
        fp16=use_fp16,
        seed=args.seed,
        dataloader_num_workers=0,
        report_to=[],
    )

    trainer = _build_trainer(model, training_args, train_ds, eval_ds, tokenizer)
    actual = trainer.accelerator.device
    if actual.type != device.type:
        raise SystemExit(
            f"requested device {device} but the Trainer resolved {actual}; "
            "check ACCELERATE_USE_CPU / CUDA_VISIBLE_DEVICES"
        )
    print(f"[train] device={actual} fp16={use_fp16}")
    trainer.train()

    metrics = trainer.evaluate()
    print(f"[train] best-checkpoint validation metrics: {metrics}")

    final_dir = os.path.join(args.output, "final")
    trainer.save_model(final_dir)
    tokenizer.save_pretrained(final_dir)
    print(f"[train] saved final model to {final_dir}")
    if train_ds.uncovered:
        print(f"[train] WARNING: {train_ds.uncovered} train spans had no covering token "
              f"(truncation / boundary alignment)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
