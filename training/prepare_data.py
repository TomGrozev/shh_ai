"""Build the contract JSONL training/validation files.

Sources
-------
* ``nvidia/Nemotron-PII`` (train split), licence CC BY 4.0. Synthetic,
  persona-grounded PII spans; NOT derived from ai4privacy.
* The seeded synthetic generator in :mod:`synthetic`, which tops up the
  contract types Nemotron under-covers (organization, financial, location,
  title, date, secret, device_id). Synthetic is capped at 10% of the training
  records so real text dominates.

ai4privacy is deliberately never read here: it stays the honest benchmark.

Output
------
``<out-dir>/train.jsonl`` and ``<out-dir>/validation.jsonl`` in the contract
span-JSONL shape (see :mod:`pii_contract`).

The validation split is a *benchmark-like* dev set, used only for early
stopping / threshold selection. It is built from sources disjoint from
``training/build_heldout.py``'s held-out benchmark:

* gretel ``pii-masking-en-v1`` and ``synthetic_pii_finance_multilingual`` rows
  **beyond** the row window the benchmark fetches (offsets 1500+ / 2500+).
* A small deterministic slice of Nemotron rows, excluded from ``train.jsonl``.

TAB (``ildpil/text-anonymization-benchmark``) is not a dev source: its gold
cannot be scored (see the comment above ``DEV_WRAP_FRACTION``).

Cleaning applied to Nemotron before writing
-------------------------------------------
* Adjacent same-person name spans (``first_name``/``middle_name``/
  ``last_name``) separated only by whitespace are merged into one NAME span,
  matching the benchmark gold and the runtime's single-name span.
* ``occupation`` spans naming a department/office/court are remapped to
  ORGANIZATION (see :func:`pii_contract.map_nemotron_label`).
* A span whose stored text differs from the text slice is dropped on its own
  (casefolded comparison), not the whole record.
* Entity-shaped labels the contract cannot express (``customer_id``,
  ``employee_id``, ``unique_id``, ``biometric_identifier``, ``user_name``)
  have their range moved to ``Record.ignore``: the span is removed, the record
  is kept, and the training step skips those positions instead of labelling
  them ``O``. Attribute labels (gender, education, ...) stay as plain ``O``,
  which is correct: the runtime has no type for them.

Usage
-----
    python prepare_data.py                       # full run
    python prepare_data.py --sample 300 --synthetic 30   # smoke-sized
    python prepare_data.py --seed 42 --dev-gretel 200
"""

from __future__ import annotations

import argparse
import ast
import collections
import hashlib
import json
import os
import random
import sys
import time

from pii_contract import (
    NEMOTRON_DROPPED,
    NEMOTRON_IGNORED_LABELS,
    Record,
    Span,
    map_nemotron_label,
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

# Synthetic records are capped at this share of the training records. Synthetic
# text is template-shaped, so it must not dominate the token distribution.
SYNTHETIC_SHARE = 0.10

# A name span merge only bridges this many whitespace characters, so two
# names on separate lines stay separate entities.
NAME_GAP_MAX = 3

# The dev set holds no TAB (``ildpil/text-anonymization-benchmark``) records.
# TAB annotates DIRECT mentions only, and its own gold marks the same entity
# type at two depths: in ECHR doc 001-76942 "Mr Mehmet Guenes" is DIRECT PERSON
# while "Mr E. Kanar" and "M.A.A" are QUASI PERSON, and its dates, orgs and
# locations are mostly QUASI too. A correct detection on one of those mentions
# then scores as a false positive, so TAB measures the annotator's masking
# policy, not the model (a 40-doc dev slice gave 2 true and 1299 false
# positives for the base model). The held-out benchmark still uses TAB: that is
# the product's own score.
#
# Benchmark-like chat wrapping, matching ``build_heldout.WRAP_FRACTION``.
DEV_WRAP_FRACTION = 0.35


def _parse_spans(raw) -> list[dict]:
    """Nemotron serialises ``spans`` as a Python-repr string; older/newer
    revisions may hand back a real list. Accept both."""
    if isinstance(raw, list):
        return raw
    if isinstance(raw, str):
        return ast.literal_eval(raw)
    raise TypeError(f"unexpected spans type: {type(raw)!r}")


def _text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class _Stats:
    """Counters printed by the report; one place so no counter goes missing."""

    def __init__(self) -> None:
        self.rows_read = 0
        self.records_kept = 0
        self.dev_rows = 0
        self.dev_by_source: collections.Counter = collections.Counter()
        self.merged_names = 0
        self.merged_records = 0
        self.mapped: collections.Counter = collections.Counter()
        self.occupation: collections.Counter = collections.Counter()
        self.span_drops: collections.Counter = collections.Counter()
        self.record_drops: collections.Counter = collections.Counter()
        # ``record_drops`` counts per offending label, so a row with two
        # unsafe labels appears twice. ``records_dropped`` counts rows once.
        self.records_dropped = 0
        self.ignore_by_label: collections.Counter = collections.Counter()
        self.ignore_ranges = 0
        self.records_with_ignore = 0
        self.ignore_conflicts = 0
        self.text_case_kept = 0


# --------------------------------------------------------------------------
# Nemotron cleaning
# --------------------------------------------------------------------------


def _merge_name_spans(spans: list[Span], text: str) -> tuple[list[Span], int]:
    """Merge adjacent name spans separated only by same-line whitespace.

    Nemotron annotates ``first_name`` and ``last_name`` as two spans sharing
    one person (2340 of 3118 adjacent name pairs in a 6000-row sample, almost
    all split by a single space); the benchmark gold and the runtime expect one
    NAME span. Only names are merged: street/city/postcode stay separate,
    because the held-out gold keeps them separate and span scoring is
    one-to-one.

    The gap must not contain a newline. Two names in separate paragraphs are
    separate people; a handful of rows do exactly that.

    Returns the merged spans and how many merges happened.
    """
    ordered = sorted(spans, key=lambda s: (s.start, -s.end))
    out: list[Span] = []
    merged = 0
    for span in ordered:
        prev = out[-1] if out else None
        gap = text[prev.end:span.start] if prev is not None else ""
        if (
            prev is not None
            and prev.type == "name"
            and span.type == "name"
            and 0 <= span.start - prev.end <= NAME_GAP_MAX
            and "\n" not in gap
            and gap.strip() == ""
        ):
            out[-1] = Span(prev.start, span.end, "name")
            merged += 1
        else:
            out.append(span)
    return out, merged


def _normalize_spans(spans: list[Span]) -> list[Span]:
    """Drop spans that overlap a kept span, keeping earliest then longest."""
    ordered = sorted(spans, key=lambda s: (s.start, -s.end))
    kept: list[Span] = []
    for span in ordered:
        if kept and span.start < kept[-1].end:
            continue
        kept.append(span)
    return kept


def _merge_ranges(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Coalesce overlapping or touching ``(start, end)`` ranges."""
    out: list[tuple[int, int]] = []
    for start, end in sorted(ranges):
        if out and start <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], end))
        else:
            out.append((start, end))
    return out


def _nemotron_record(row: dict, row_index: int, stats: _Stats) -> Record | None:
    """Turn one Nemotron row into a contract record, or None if it is unusable.

    Labels the contract cannot express are not dropped with the record: their
    ranges go to ``Record.ignore`` so the training step skips them instead of
    labelling identifier-shaped text as ``O``.
    """
    text = row["text"]
    spans: list[Span] = []
    ignored: list[tuple[int, int]] = []
    for raw in _parse_spans(row["spans"]):
        try:
            label = raw.get("label")
            start, end = int(raw["start"]), int(raw["end"])
        except (AttributeError, KeyError, TypeError, ValueError):
            stats.span_drops["bad_span"] += 1
            continue
        if not (0 <= start < end <= len(text)):
            stats.span_drops["bad_offset"] += 1
            continue

        surface = text[start:end]
        declared = raw.get("text")
        # Some stored spans differ only in case ("puerto rican" vs "Puerto
        # Rican") or carry an int instead of str ("593"); those are fine. A
        # real mismatch means the offsets point at other text, so that span
        # alone is dropped and the rest of the record is kept.
        if declared is not None and str(surface) != str(declared):
            if surface.casefold() == str(declared).casefold():
                # Only the casing drifted ("puerto rican" vs "Puerto Rican");
                # the offsets are right, so the span is kept as it is.
                stats.text_case_kept += 1
            else:
                stats.span_drops["text_mismatch"] += 1
                continue

        ctype = map_nemotron_label(label, surface)
        if ctype is None:
            if label in NEMOTRON_IGNORED_LABELS:
                stats.ignore_by_label[str(label)] += 1
                ignored.append((start, end))
            else:
                stats.span_drops[f"label:{label}"] += 1
            continue
        if label == "occupation":
            stats.occupation[ctype] += 1
        stats.mapped[label] += 1
        spans.append(Span(start, end, ctype))

    spans, merged = _merge_name_spans(spans, text)
    if merged:
        stats.merged_names += merged
        stats.merged_records += 1
    kept = _normalize_spans(spans)
    stats.span_drops["overlap"] += len(spans) - len(kept)

    # An ignored region must never sit under a kept span (the training step
    # cannot both label and skip the same position). Raw annotations are
    # occasionally nested, so such a range loses to the kept span.
    ignore = _merge_ranges(ignored)
    conflicts = [r for r in ignore
                 if any(r[0] < s.end and s.start < r[1] for s in kept)]
    if conflicts:
        stats.ignore_conflicts += len(conflicts)
        ignore = [r for r in ignore if r not in conflicts]
    stats.ignore_ranges += len(ignore)
    if ignore:
        stats.records_with_ignore += 1

    rec = Record(id=str(row.get("uid", f"nemotron-{row_index}")), text=text,
                 spans=kept, source=DATASET_ID, ignore=ignore)
    problems = validate_record(rec)
    if problems:
        stats.record_drops[f"invalid:{problems[0]}"] += 1
        stats.records_dropped += 1
        return None
    return rec


def _nemotron_records(sample: int, dev_every: int, stats: _Stats):
    """Stream the Nemotron train split into train records and dev records.

    ``sample`` > 0 limits how many source rows are read (smoke runs).
    Every ``dev_every``-th row goes to the dev set instead of training, so the
    dev set stays in-distribution without touching training rows.
    """
    from datasets import load_dataset  # imported lazily: heavy, network-bound

    stream = load_dataset(DATASET_ID, split="train", streaming=True)
    train: list[Record] = []
    dev: list[Record] = []

    for i, row in enumerate(stream):
        if sample and i >= sample:
            break
        stats.rows_read += 1
        text = row["text"]
        if any(bad in text.lower() for bad in FORBIDDEN_SOURCES):
            stats.record_drops["forbidden_source"] += 1
            continue

        rec = _nemotron_record(row, i, stats)
        if rec is None:
            continue
        if dev_every and i % dev_every == 0:
            dev.append(rec)
            stats.dev_rows += 1
        else:
            train.append(rec)
            stats.records_kept += 1

    return train, dev


# --------------------------------------------------------------------------
# Dev set from benchmark-like, disjoint sources
# --------------------------------------------------------------------------


def _build_heldout_module():
    import build_heldout  # local module; owns the benchmark label conventions

    return build_heldout


def _benchmark_fingerprints(bh) -> tuple[set[str], list[str]]:
    """Text hashes the held-out benchmark may draw on.

    Returns ``(text_hashes, notes)``. The hashes cover the built benchmark file
    and every source row it fetched. Any dev record matching one of them would
    leak.
    """
    hashes: set[str] = set()
    notes: list[str] = []

    out_path = os.path.join(bh.cache_dir(), "heldout_v1.jsonl")
    if os.path.exists(out_path):
        with open(out_path, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    hashes.add(_text_hash(json.loads(line)["text"]))
        notes.append(f"heldout_v1.jsonl: {len(hashes)} texts")
    else:
        notes.append("heldout_v1.jsonl: absent (source windows still checked)")

    src_dir = bh._src_cache_dir()
    for key, src in bh.SOURCES.items():
        if key == "tab":
            # TAB is not a dev source, so its doc ids need no leak check; the
            # benchmark's own file and the gretel rows are hashed below.
            continue
        cache = os.path.join(
            src_dir,
            f"rows_{src['repo'].replace('/', '__')}_{src['split']}_{src['revision'][:12]}.json",
        )
        if not os.path.exists(cache):
            notes.append(f"{key}: source-row cache absent, offset window used")
            continue
        with open(cache, encoding="utf-8") as fh:
            rows = json.load(fh)
        for row in rows:
            text = row.get("text") or row.get("generated_text")
            if text:
                hashes.add(_text_hash(text))
        notes.append(f"{key}: {len(rows)} source rows hashed")

    return hashes, notes


def _fetch_rows_from_offset(dataset: str, config: str, split: str, revision: str,
                            offset: int, limit: int, keep: tuple[str, ...]) -> list[dict]:
    """Page the datasets-server ``/rows`` API from ``offset``.

    ``build_heldout.fetch_rows`` always starts at 0; the benchmark owns the
    first ``fetch_rows`` rows of each gretel source, so dev borrows rows from
    beyond that window and can never overlap it.
    """
    bh = _build_heldout_module()
    slug = dataset.replace("/", "__")
    path = os.path.join(
        bh._src_cache_dir(),
        f"rows_{slug}_{split}_{revision[:12]}_off{offset}.json",
    )
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)

    rows: list[dict] = []
    cursor = offset
    while cursor < offset + limit:
        length = min(100, offset + limit - cursor)
        url = (
            "https://datasets-server.huggingface.co/rows"
            f"?dataset={dataset}&config={config}&split={split}"
            f"&offset={cursor}&length={length}&revision={revision}"
        )
        payload = bh._get_json(url)
        page = payload.get("rows") or []
        if not page:
            break
        for entry in page:
            row = entry["row"]
            rows.append({k: row.get(k) for k in keep})
        cursor += len(page)
        time.sleep(0.5)

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rows, fh)
    return rows


def _dev_from_gretel(bh, key: str, limit: int, rng: random.Random,
                     stats: _Stats) -> list[Record]:
    """Dev docs from gretel rows beyond the benchmark's fetch window."""
    src = bh.SOURCES[key]
    parser = bh.parse_gretel_en if key == "gretel_en" else bh.parse_gretel_fin
    keep = (("text", "entities") if key == "gretel_en"
            else ("generated_text", "pii_spans", "language"))
    offset = int(src["fetch_rows"])  # benchmark owns rows [0, offset)
    # The finance source interleaves six languages and every English row has
    # spans, so fetch three times the wanted rows there; the masking source is
    # English-only with entities on every row.
    fetch = limit if key == "gretel_en" else limit * 3
    rows = _fetch_rows_from_offset(src["repo"], src["config"], src["split"],
                                   src["revision"], offset, fetch, keep)

    pool: list[dict] = []
    for row in rows:
        parsed = parser(row)
        if parsed is None:
            continue
        text, spans, _dropped = parsed
        spans = bh.normalize_spans(spans, text)
        if spans:
            pool.append({"text": text, "spans": spans, "source": src["repo"]})

    picked = rng.sample(pool, min(limit, len(pool)))
    picked.sort(key=lambda d: d["text"])
    records = [
        Record(
            id=f"dev-{key}-{i:04d}",
            text=doc["text"],
            spans=[Span(s["start"], s["end"], s["type"]) for s in doc["spans"]],
            source=doc["source"],
        )
        for i, doc in enumerate(picked)
    ]
    stats.dev_by_source[src["repo"]] += len(records)
    return records


def _wrap_some_chat(bh, records: list[Record], rng: random.Random) -> list[Record]:
    """Reshape a deterministic share of dev docs into chat-shaped messages."""
    n_wrap = int(len(records) * DEV_WRAP_FRACTION)
    if not n_wrap:
        return records
    wrapped = records[:]
    for index in sorted(rng.sample(range(len(records)), n_wrap)):
        rec = wrapped[index]
        prefix = rng.choice(bh.CHAT_PREFIXES)
        shift = len(prefix)
        wrapped[index] = Record(
            id=rec.id,
            text=prefix + rec.text,
            spans=[Span(s.start + shift, s.end + shift, s.type) for s in rec.spans],
            source=rec.source,
        )
    return wrapped


def _dev_records(seed: int, dev_gretel: int,
                 stats: _Stats) -> tuple[list[Record], list[str]]:
    """Build the benchmark-like dev set and prove it is disjoint from held-out.

    A source that cannot be reached is reported and skipped; the caller fails
    when no dev source produced records, so a broken network never turns into
    a silent degenerate validation file. A dev set that overlaps the benchmark
    texts raises, because such a record never gets skipped.
    """
    bh = _build_heldout_module()
    rng = random.Random(seed ^ 0x0DE5)
    notes: list[str] = []
    records: list[Record] = []

    for key in ("gretel_en", "gretel_fin"):
        if dev_gretel <= 0:
            continue
        try:
            records += _dev_from_gretel(bh, key, dev_gretel, rng, stats)
            src = bh.SOURCES[key]
            notes.append(
                f"{key} dev rows fetched from offset {src['fetch_rows']}+ "
                f"(benchmark window 0-{int(src['fetch_rows']) - 1})"
            )
        except Exception as exc:  # noqa: BLE001
            notes.append(f"{key} dev source FAILED: {exc}")

    records = _wrap_some_chat(bh, records, rng)

    held_hashes, fp_notes = _benchmark_fingerprints(bh)
    notes.extend(fp_notes)
    leaked = [rec.id for rec in records if _text_hash(rec.text) in held_hashes]
    if leaked:
        raise RuntimeError(
            f"dev records overlap the held-out benchmark: {leaked[:5]}"
        )
    notes.append(f"dev texts hashed: {len(records)}, "
                 f"held-out texts hashed: {len(held_hashes)}, "
                 f"intersection: 0")
    return records, notes


# --------------------------------------------------------------------------
# Reporting helpers
# --------------------------------------------------------------------------


def _report_counts(records: list[Record]) -> collections.Counter:
    counts: collections.Counter = collections.Counter()
    for rec in records:
        for s in rec.spans:
            counts[s.type] += 1
    return counts


def _print_span_counts(title: str, records: list[Record]) -> None:
    counts = _report_counts(records)
    print(f"\n--- contract type span counts ({title}) ---")
    for ctype in sorted(counts):
        print(f"  {ctype:12s} {counts[ctype]}")


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--sample", type=int, default=0,
                    help="max Nemotron source rows to read (0 = all)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--synthetic", type=int, default=4000,
                    help="max synthetic records to add (0 = none); capped at "
                         f"{int(SYNTHETIC_SHARE * 100)}%% of the training records")
    ap.add_argument("--synthetic-seed", type=int, default=1234)
    ap.add_argument("--dev-gretel", type=int, default=300,
                    help="max docs per gretel source in the dev set (0 = none)")
    ap.add_argument("--dev-nemotron-every", type=int, default=250,
                    help="every N-th Nemotron row goes to dev instead of train "
                         "(0 = none)")
    args = ap.parse_args(argv)

    from synthetic import generate as synth_generate

    stats = _Stats()

    # Smoke runs read few rows; shrink the dev stride with the sample so a
    # small run still has an in-distribution dev slice (never below 1).
    dev_every = args.dev_nemotron_every
    if dev_every and args.sample:
        dev_every = max(1, min(dev_every, args.sample // 50))
    nemotron_train, nemotron_dev = _nemotron_records(
        args.sample, dev_every, stats)

    print(f"[prepare] Nemotron rows read: {stats.rows_read} "
          f"(train {len(nemotron_train)}, dev {len(nemotron_dev)}, "
          f"records dropped {stats.records_dropped})")

    max_synth = int(len(nemotron_train) * SYNTHETIC_SHARE / (1 - SYNTHETIC_SHARE))
    synthetic: list[Record] = []
    if args.synthetic:
        n_synth = min(args.synthetic, max_synth)
        if n_synth < args.synthetic:
            print(f"[prepare] synthetic capped at {n_synth} "
                  f"({SYNTHETIC_SHARE:.0%} of training records)")
        synthetic = synth_generate(n_synth, args.synthetic_seed)
        print(f"[prepare] synthetic records: {len(synthetic)}")

    train = nemotron_train + synthetic
    if not train:
        print("[prepare] ERROR: no training records produced", file=sys.stderr)
        return 1

    dev_records, dev_notes = _dev_records(args.seed, args.dev_gretel, stats)
    validation = nemotron_dev + dev_records
    if nemotron_dev:
        stats.dev_by_source[DATASET_ID] += len(nemotron_dev)
    if not validation:
        print("[prepare] ERROR: no validation records produced "
              "(every dev source failed)", file=sys.stderr)
        return 1

    os.makedirs(args.out_dir, exist_ok=True)
    train_path = os.path.join(args.out_dir, "train.jsonl")
    val_path = os.path.join(args.out_dir, "validation.jsonl")
    n_train = write_jsonl(train_path, train)
    n_val = write_jsonl(val_path, validation)

    print("\n=== dataset report ===")
    print(f"source: {DATASET_ID}  licence: {DATASET_LICENSE}\n        {DATASET_URL}")
    print(f"train: {n_train} records -> {train_path}")
    print(f"validation: {n_val} records -> {val_path}")
    if train:
        print(f"synthetic share of train: {len(synthetic) / len(train):.1%}")

    print("\n--- name span merges ---")
    print(f"  merged name spans: {stats.merged_names} "
          f"(across {stats.merged_records} records)")

    print("\n--- occupation remap ---")
    print(f"  occupation -> organization: {stats.occupation.get('organization', 0)}")
    print(f"  occupation -> title:        {stats.occupation.get('title', 0)}")

    print("\n--- mapped Nemotron labels ---")
    for label in sorted(stats.mapped):
        print(f"  {label:32s} {stats.mapped[label]:7d} spans")

    print("\n--- dropped spans by reason ---")
    for reason in sorted(stats.span_drops):
        print(f"  {reason:32s} {stats.span_drops[reason]:7d}")
    if not stats.span_drops:
        print("  (none)")
    print(f"  {'text differed only by case':32s} {stats.text_case_kept:7d}  (kept, not dropped)")

    print(f"\n--- ignore ranges (span removed, region not trained as O) ---")
    print(f"  ranges: {stats.ignore_ranges} in {stats.records_with_ignore} records")
    for label in sorted(stats.ignore_by_label):
        print(f"  {label:32s} {stats.ignore_by_label[label]:7d} spans")
    if not stats.ignore_by_label:
        print("  (none)")
    if stats.ignore_conflicts:
        print(f"  dropped under a kept span: {stats.ignore_conflicts}")

    print(f"\n--- dropped records: {stats.records_dropped} rows ---")
    for reason in sorted(stats.record_drops):
        print(f"  {reason:44s} {stats.record_drops[reason]:7d}")
    if not stats.record_drops:
        print("  (none)")

    print("\n--- dropped labels (no contract counterpart) ---")
    for label, reason in sorted(NEMOTRON_DROPPED.items()):
        seen = stats.span_drops.get(f"label:{label}", 0)
        if label in NEMOTRON_IGNORED_LABELS:
            detail = f"{stats.ignore_by_label.get(label, 0)} ignore ranges"
        else:
            detail = f"x{seen} spans dropped"
        print(f"  {label:32s} {detail:20s} {reason}")

    print("\n--- dev records by source ---")
    for source, count in sorted(stats.dev_by_source.items()):
        if count:
            print(f"  {count:5d}  {source}")

    _print_span_counts("train split", train)
    _print_span_counts("validation split", validation)

    print("\n--- dev/held-out disjointness ---")
    for note in dev_notes:
        print(f"  {note}")

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
