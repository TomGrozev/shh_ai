"""Build the contract JSONL training/validation files.

Sources
-------
* ``nvidia/Nemotron-PII`` (train split), licence CC BY 4.0. Synthetic,
  persona-grounded PII spans; NOT derived from ai4privacy.
* The seeded synthetic generator in :mod:`synthetic`, which tops up the
  contract types Nemotron under-covers (organization, financial, location,
  title, date).

ai4privacy is deliberately never read here: it stays the honest benchmark.

Output
------
``<out-dir>/train.jsonl`` and ``<out-dir>/validation.jsonl`` in the contract
span-JSONL shape (see :mod:`pii_contract`). The validation split is held out
from training and used only for early stopping / threshold selection; it is
NOT the cross-project held-out benchmark (that is built by
``training/build_heldout.py``).

Usage
-----
    python prepare_data.py                       # full run
    python prepare_data.py --sample 300          # smoke-sized
    python prepare_data.py --val-frac 0.05 --seed 42
"""

from __future__ import annotations

import argparse
import ast
import collections
import os
import random
import sys

from pii_contract import (
    NEMOTRON_DROPPED,
    NEMOTRON_LABEL_MAP,
    Record,
    Span,
    validate_record,
    write_jsonl,
)

DATASET_ID = "nvidia/Nemotron-PII"
DATASET_URL = "https://huggingface.co/datasets/nvidia/Nemotron-PII"
DATASET_LICENSE = "CC BY 4.0"

# Cheap guard: if any of these substrings show up in a record's provenance we
# refuse to use it. ai4privacy strings should never appear because the dataset
# is unrelated, but the check documents the invariant and fails loudly if a
# future edit wires in the wrong source.
FORBIDDEN_SOURCES = ("ai4privacy", "pii-masking-200k")


def _parse_spans(raw) -> list[dict]:
    """Nemotron serialises ``spans`` as a Python-repr string; older/newer
    revisions may hand back a real list. Accept both."""
    if isinstance(raw, list):
        return raw
    if isinstance(raw, str):
        return ast.literal_eval(raw)
    raise TypeError(f"unexpected spans type: {type(raw)!r}")


def _nemotron_records(sample: int, seed: int):
    """Stream the Nemotron train split into contract records.

    ``sample`` > 0 limits how many source rows are read (smoke runs).
    """
    from datasets import load_dataset  # imported lazily: heavy, network-bound

    stream = load_dataset(DATASET_ID, split="train", streaming=True)
    records: list[Record] = []
    mapped = collections.Counter()
    dropped = collections.Counter()
    skipped = 0

    for i, row in enumerate(stream):
        if sample and i >= sample:
            break
        text = row["text"]
        if any(bad in text.lower() for bad in FORBIDDEN_SOURCES):
            skipped += 1
            continue

        spans: list[Span] = []
        for raw in _parse_spans(row["spans"]):
            label = raw.get("label")
            ctype = NEMOTRON_LABEL_MAP.get(label)
            if ctype is None:
                dropped[label] += 1
                continue
            start, end = int(raw["start"]), int(raw["end"])
            # Trust but verify: the annotated surface must equal the slice.
            if text[start:end] != raw.get("text"):
                skipped += 1
                continue
            spans.append(Span(start, end, ctype))
            mapped[label] += 1

        rec = Record(id=str(row.get("uid", f"nemotron-{i}")), text=text,
                     spans=spans, source=DATASET_ID)
        problems = validate_record(rec)
        if problems:
            skipped += 1
            continue
        records.append(rec)

    print(f"[prepare] Nemotron rows read: {len(records) + skipped} "
          f"(kept {len(records)}, skipped {skipped})")
    return records, mapped, dropped


def _split(records: list[Record], val_frac: float, seed: int):
    rng = random.Random(seed)
    shuffled = records[:]
    rng.shuffle(shuffled)
    n_val = max(1, int(len(shuffled) * val_frac))
    return shuffled[n_val:], shuffled[:n_val]


def _report_counts(records: list[Record]) -> collections.Counter:
    counts: collections.Counter = collections.Counter()
    for rec in records:
        for s in rec.spans:
            counts[s.type] += 1
    return counts


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--sample", type=int, default=0,
                    help="max Nemotron source rows to read (0 = all)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--val-frac", type=float, default=0.05)
    ap.add_argument("--synthetic", type=int, default=4000,
                    help="number of synthetic weak-type records to add (0 = none)")
    ap.add_argument("--synthetic-seed", type=int, default=1234)
    args = ap.parse_args(argv)

    from synthetic import generate as synth_generate

    nemotron, mapped, dropped = _nemotron_records(args.sample, args.seed)

    synthetic: list[Record] = []
    if args.synthetic:
        synthetic = synth_generate(args.synthetic, args.synthetic_seed)
        print(f"[prepare] synthetic records: {len(synthetic)}")

    combined = nemotron + synthetic
    if not combined:
        print("[prepare] ERROR: no records produced", file=sys.stderr)
        return 1

    train, val = _split(combined, args.val_frac, args.seed)

    os.makedirs(args.out_dir, exist_ok=True)
    train_path = os.path.join(args.out_dir, "train.jsonl")
    val_path = os.path.join(args.out_dir, "validation.jsonl")
    n_train = write_jsonl(train_path, train)
    n_val = write_jsonl(val_path, val)

    print("\n=== dataset report ===")
    print(f"source: {DATASET_ID}  licence: {DATASET_LICENSE}\n        {DATASET_URL}")
    print(f"train: {n_train} records -> {train_path}")
    print(f"validation: {n_val} records -> {val_path}")

    print("\n--- label mapping (Nemotron -> contract type) ---")
    for label in sorted(mapped):
        print(f"  {label:32s} -> {NEMOTRON_LABEL_MAP[label]:12s} ({mapped[label]} spans)")

    print("\n--- unmapped (dropped) Nemotron labels ---")
    for label, reason in sorted(NEMOTRON_DROPPED.items()):
        seen = dropped.get(label, 0)
        print(f"  {label:32s} x{seen:<6} {reason}")

    print("\n--- contract type span counts (train split) ---")
    train_counts = _report_counts(train)
    for t in sorted({s.type for r in train for s in r.spans}):
        print(f"  {t:12s} {train_counts[t]}")

    return 0


if __name__ == "__main__":
    rc = main()
    sys.stdout.flush()
    sys.stderr.flush()
    # ponytail: the process would otherwise hang forever *after* printing its
    # report. The stuck frame is inside libarrow: `exit()` runs C++ static
    # destructors, `~ThreadPool` calls `ThreadPool::Shutdown()`, which waits on a
    # condition variable for workers that are already gone (apache/arrow#48137,
    # apache/arrow#50482). We reach it through the threaded parquet read
    # `datasets` streaming does (datasets/packaged_modules/parquet/parquet.py
    # `_generate_tables` -> `fragment.to_batches(use_threads=True)`).
    # os._exit skips C++ static destructors; it is the only reliable exit
    # reachable from this file, since the deadlock is in a dependency.
    # Ceiling: no atexit handlers or __del__ run at exit (the JSONL is already
    # written and closed by write_jsonl, and both streams are flushed above).
    # Upgrade: replace with `raise SystemExit(main())` once the installed
    # pyarrow exits cleanly on its own.
    os._exit(rc)
