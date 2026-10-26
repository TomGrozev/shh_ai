"""Build the contract JSONL training/validation files.

Sources
-------
* ``nvidia/Nemotron-PII`` (train split), licence CC BY 4.0. Synthetic,
  persona-grounded PII spans; NOT derived from ai4privacy.
* gretel ``pii-masking-en-v1`` and ``synthetic_pii_finance_multilingual``,
  the two sources the held-out benchmark is built from. Nemotron's span
  conventions differ from the benchmark gold (it tags address parts and
  calendar dates only), so a share of each gretel source goes into the
  training rows, labelled with ``build_heldout``'s own maps and parsers.
  They are read from offsets beyond both the benchmark's fetch window and the
  dev set's window, and every training text is hash-checked against the
  held-out benchmark and the dev set.
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
* Adjacent address parts (``street_address``/``city``/``state``/``county``/
  ``postcode``/``country``) separated only by commas and whitespace are merged
  into one LOCATION span, because the benchmark's gretel gold marks a whole
  address as one span and scores each separate part as a false positive
  ("Apt. 0490", "Anytown", "80002").
* ``occupation`` spans naming a department/office/court are remapped to
  ORGANIZATION (see :func:`pii_contract.map_nemotron_label`).
* DATE spans that name no calendar instant (relative, durational, frequency
  or placeholder; see :func:`pii_contract.date_class`) are dropped from the
  gold and train as ``O``. Product decision: those surfaces are not PII.
  The same rule runs on the gretel rows and on the dev set, and the held-out
  benchmark writes them as neutral ranges.
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
    python prepare_data.py                       # full run (50k/30k/23k mix)
    python prepare_data.py --nemotron-train 60000 --gretel-en-train 20000
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
import re
import sys
import time

from pii_contract import (
    DATE_CLASSES,
    NEMOTRON_ADDRESS_ANCHORS,
    NEMOTRON_ADDRESS_PARTS,
    NEMOTRON_DROPPED,
    NEMOTRON_IGNORED_LABELS,
    NON_ABSOLUTE_DATE_CLASSES,
    Record,
    Span,
    date_class,
    is_nonabsolute_date,
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

# Training rows per source. The gretel share is much larger than the Nemotron
# share because the held-out benchmark is built from gretel: its gold, its
# label maps and its document shape are what the model is scored on.
#
# Windows, not rows, set the T4 budget (``run_gpu.sh``). Measured on the
# prepared data: a Nemotron row averages 134.5 words and splits into 1.13
# windows at 512/64; a gretel-pii-masking-en-v1 row averages 28 words and a
# synthetic_pii_finance_multilingual row 196.5 words, so each is one window.
#
#   Nemotron     50,000 rows -> ~56,300 windows
#   gretel-en    30,000 rows -> ~30,000 windows
#   gretel-fin   23,000 rows -> ~23,000 windows
#   synthetic     4,000 rows -> ~4,000 windows (10% cap of the train split)
#                 total      ~113,000 windows, i.e. about 2.2-5.3 h for the
#                 5-epoch default, inside Kaggle's 12 h cap.
#
# GRETEL_FIN_TRAIN is near the ceiling of the source, not a free choice: the
# train split holds 50,346 rows, the benchmark owns rows 0-2499, the dev set
# takes 900 more plus GRETEL_TRAIN_GAP, and only ~51% of the rows that remain
# are English with spans. That leaves ~23,400 usable rows after offset 3,500.
NEMOTRON_TRAIN = 50_000
GRETEL_EN_TRAIN = 30_000
GRETEL_FIN_TRAIN = 23_000

# Rows skipped between the dev window and the training window, so a change to
# ``--dev-gretel`` cannot make the two windows touch. The text-hash check is
# the hard guarantee; this keeps the offsets readable.
GRETEL_TRAIN_GAP = 100

# A name span merge only bridges this many whitespace characters, so two
# names on separate lines stay separate entities.
NAME_GAP_MAX = 3

# An address merge bridges only commas and whitespace. 26081 of the 27794
# adjacent location pairs in a full Nemotron sample are separated by exactly
# ", ", and the rest are a single space or a newline inside a multi-line
# address ("16 Northeast Knott Street\nCanby, Oregon 97013"); 6 characters
# covers ",  ", ",\n" and " , " without reaching across a field label.
ADDRESS_GAP_MAX = 6
ADDRESS_GAP_NEWLINES_MAX = 2

# A bare 2-5 digit number: a postcode, a suite number, a case number. The
# gretel gold marks these as LOCATION only inside an address span, so a lone
# numeric part is dropped from the Nemotron gold and left as ``O``.
_BARE_NUMBER_RE = re.compile(r"\d{2,5}")

# Share of each gretel training pool drawn from rows whose gold is dense in
# the surface class the held-out benchmark is dense in.
#
#   * ORG_PRIORITY_SHARE: finance rows with >= ORG_PRIORITY_MIN organization
#     spans. Organization recall on long descriptive names is the third gap;
#     the finance pool carries 1.44 organization spans per doc, the English
#     pool 0.03, so the finance pool is the only place to raise exposure.
#
# There is no DATE quota: a non-absolute date is not PII for this proxy
# (see ``pii_contract.date_class``), so those spans leave the gold and a
# quota over them would only raise the count of ordinary background text.
ORG_PRIORITY_SHARE = 0.40
ORG_PRIORITY_MIN = 2

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
        self.train_by_source: collections.Counter = collections.Counter()
        self.gretel_dropped: collections.Counter = collections.Counter()
        # Gretel training spans dropped as implausible that became ignore
        # ranges (their text is not trained as O), per source.
        self.gretel_ignored_spans: collections.Counter = collections.Counter()
        self.merged_names = 0
        self.merged_records = 0
        self.merged_addresses = 0
        self.merged_address_records = 0
        self.numeric_address_parts = 0
        self.gretel_composition: list[str] = []
        # Non-absolute DATE spans removed from the gold, per source and split.
        self.nonabsolute_dates: collections.Counter = collections.Counter()
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


def _merge_address_spans(spans: list[Span], part_of: dict[tuple[int, int], str],
                         text: str, stats: _Stats) -> list[Span]:
    """Merge adjacent address parts into one LOCATION span.

    Nemotron tags each address part separately ("108 Saint John St", "West
    Chester", "PA", "19382", "USA"); the benchmark's gretel gold marks the
    whole address as one location span and scores a span on each part as a
    false positive. ``part_of`` maps a span's ``(start, end)`` to the raw
    Nemotron label, so only address parts merge: a coordinate or an
    organisation between two parts breaks the run.

    A run merges when it holds a street or a postcode
    (:data:`NEMOTRON_ADDRESS_ANCHORS`), or when the two parts carry different
    part labels ("California, USA", "Edwardsburg, MI"). The second rule is
    what stops the model splitting a gold address: 26081 of the 27794
    adjacent location pairs in a full Nemotron sample were separated by
    exactly ", ", and a city/state/country run holds no anchor, so each of
    those pairs taught two LOCATION spans where the gretel gold marks one.
    Two parts with the same label stay separate ("Portland, Seattle" is a
    list).

    The gap must be commas and whitespace only, which keeps field labels
    ("City: Springfield") from joining.

    A lone numeric part ("Postcode: 97205") is dropped instead of kept: it
    teaches the model that a bare 2-5 digit number is a location, which is
    what the benchmark's finance FPs are made of ("256", "50151").

    Returns the spans in text order, merged runs included.
    """
    ordered = sorted(spans, key=lambda s: (s.start, -s.end))
    # (span, raw labels of the parts merged into it; empty for other spans)
    out: list[tuple[Span, list[str]]] = []
    merged = 0
    for span in ordered:
        label = part_of.get((span.start, span.end))
        if label is not None and out:
            prev_span, prev_labels = out[-1]
            gap = text[prev_span.end:span.start]
            bridge = (
                prev_labels
                and len(gap) <= ADDRESS_GAP_MAX
                and gap.count("\n") <= ADDRESS_GAP_NEWLINES_MAX
                and all(ch in ", \t\n\r" for ch in gap)
                and (
                    any(part in NEMOTRON_ADDRESS_ANCHORS for part in prev_labels)
                    or label in NEMOTRON_ADDRESS_ANCHORS
                    or label != prev_labels[-1]
                )
            )
            if bridge:
                out[-1] = (Span(prev_span.start, span.end, "location"),
                           prev_labels + [label])
                merged += 1
                continue
        out.append((span, [label] if label is not None else []))
    if merged:
        stats.merged_addresses += merged
        stats.merged_address_records += 1

    kept: list[Span] = []
    for span, labels in out:
        if (len(labels) == 1 and labels[0] in NEMOTRON_ADDRESS_PARTS
                and _BARE_NUMBER_RE.fullmatch(text[span.start:span.end].strip())):
            stats.numeric_address_parts += 1
            continue
        kept.append(span)
    return kept


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
    part_of: dict[tuple[int, int], str] = {}
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
        if ctype == "date" and is_nonabsolute_date(surface):
            # Product decision: a date that names no calendar instant is not
            # PII, so the text stays and trains as O.
            stats.nonabsolute_dates["nemotron"] += 1
            continue
        if label == "occupation":
            stats.occupation[ctype] += 1
        stats.mapped[label] += 1
        if label in NEMOTRON_ADDRESS_PARTS:
            part_of[(start, end)] = str(label)
        spans.append(Span(start, end, ctype))

    spans, merged = _merge_name_spans(spans, text)
    if merged:
        stats.merged_names += merged
        stats.merged_records += 1
    spans = _merge_address_spans(spans, part_of, text, stats)
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


def _nemotron_records(sample: int, limit: int, dev_every: int, stats: _Stats):
    """Stream the Nemotron train split into train records and dev records.

    ``limit`` > 0 caps the training records; the stream stops once it has that
    many, so a limited run reads no further rows. ``sample`` > 0 caps the
    source rows read (smoke runs); the two caps are independent and the
    earlier one wins. Every ``dev_every``-th row goes to the dev set instead of
    training, so the dev set stays in-distribution without touching training
    rows.
    """
    from datasets import load_dataset  # imported lazily: heavy, network-bound

    stream = load_dataset(DATASET_ID, split="train", streaming=True)
    train: list[Record] = []
    dev: list[Record] = []

    for i, row in enumerate(stream):
        if sample and i >= sample:
            break
        if limit and len(train) >= limit:
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

    The cache file carries the limit as well as the offset: a smoke run that
    fetched 40 rows must not stand in for a full run that needs 36,000 from
    the same offset.

    Returns fewer than ``limit`` rows when the split ends first, so a request
    past the last row reads the whole rest of the split instead of stopping
    early.
    """
    bh = _build_heldout_module()
    slug = dataset.replace("/", "__")
    path = os.path.join(
        bh._src_cache_dir(),
        f"rows_{slug}_{split}_{revision[:12]}_off{offset}_n{limit}.json",
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
        if len(page) < length:
            break  # short page: the split ends here
        time.sleep(0.5)

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rows, fh)
    return rows


# --------------------------------------------------------------------------
# Gretel pool composition: organization density, date gold cleanup
# --------------------------------------------------------------------------
# The held-out benchmark's finance gold marks a whole address as one location
# span and is dense in long descriptive organization names; a plain random
# draw over the gretel windows reproduces neither, so the sampler below fills
# an organization quota.
#
# DATE gold is filtered instead: a DATE span that names no calendar instant
# (relative, durational, frequency or placeholder) is not PII for this proxy,
# so it leaves the gold and trains as ``O``. The same filter runs on the
# training rows and on the dev rows, so checkpoint selection sees the rule the
# benchmark scores, and ``build_heldout`` writes those spans as neutral.
def _drop_nonabsolute_date_spans(text: str, spans: list[dict], key: str,
                                 stats: _Stats) -> list[dict]:
    """Remove DATE spans that name no calendar instant.

    ``key`` names the counter the report prints ("gretel_fin:train",
    "nemotron", ...).
    """
    kept: list[dict] = []
    for span in spans:
        if span["type"] == "date" and is_nonabsolute_date(
                text[span["start"]:span["end"]]):
            stats.nonabsolute_dates[key] += 1
            continue
        kept.append(span)
    return kept


def _pool_org_count(doc: dict) -> int:
    return sum(1 for s in doc["spans"] if s["type"] == "organization")


def _quota_sample(pool: list[dict], limit: int, rng: random.Random,
                  quotas: list[tuple]) -> tuple[list[dict], list[str]]:
    """Draw up to ``limit`` pool docs, filling each priority group first.

    ``quotas`` holds ``(predicate, share, label)``. A group takes up to
    ``share * limit`` docs, or as many as the pool holds; the remainder comes
    from the docs no group took, so the draw never exceeds ``limit`` and every
    pool doc can still be picked. Deterministic for a seed.

    Returns the chosen docs and one report line per group, so the run prints
    what the quota actually achieved instead of what it asked for.
    """
    taken: set[int] = set()
    picked: list[int] = []
    notes: list[str] = []
    for predicate, share, label in quotas:
        available = [i for i in range(len(pool))
                     if i not in taken and predicate(pool[i])]
        want = min(int(round(limit * share)), limit - len(picked))
        take = rng.sample(available, min(want, len(available)))
        taken.update(take)
        picked.extend(take)
        notes.append(f"{label}: kept {len(take)} of {len(available)} available "
                     f"(quota {want})")
    rest = [i for i in range(len(pool)) if i not in taken]
    need = limit - len(picked)
    if need > 0:
        picked.extend(rng.sample(rest, min(need, len(rest))))
    return [pool[i] for i in picked], notes


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
        text, spans, _drops, _dropped = parsed
        spans = bh.normalize_spans(spans, text)
        # The dev set uses the training rule, so checkpoint selection sees the
        # gold shape the benchmark scores (non-absolute dates are not PII).
        spans = _drop_nonabsolute_date_spans(text, spans, f"{key}:dev", stats)
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


def _gretel_train_records(bh, key: str, limit: int, dev_gretel: int,
                          rng: random.Random, stats: _Stats
                          ) -> tuple[list[Record], int, int, int]:
    """Training docs from gretel rows beyond both the benchmark and dev windows.

    The benchmark owns rows ``[0, fetch_rows)`` and the dev set borrows the next
    ``dev_gretel`` (three times that for the six-language finance source), so
    training starts after both windows. The parsers, the label maps and
    :func:`build_heldout.normalize_spans` come from ``build_heldout`` so the
    training gold uses exactly the benchmark's conventions.

    A deterministic share of the records is reshaped into chat messages,
    matching ``build_heldout.WRAP_FRACTION``: the benchmark wraps 35% of its
    docs that way, and the model must see that shape in training.

    Returns ``(records, offset, rows_fetched, pool_size)`` so the caller can
    report what the source could supply.
    """
    src = bh.SOURCES[key]
    parser = bh.parse_gretel_en if key == "gretel_en" else bh.parse_gretel_fin
    keep = (("text", "entities") if key == "gretel_en"
            else ("generated_text", "pii_spans", "language"))
    dev_fetch = dev_gretel if key == "gretel_en" else dev_gretel * 3
    offset = int(src["fetch_rows"]) + max(0, dev_fetch) + GRETEL_TRAIN_GAP
    # Only about half the finance rows are English with spans (51% over
    # 500-row samples at offsets 3,500 to 45,000), so fetch three rows per
    # wanted record there. The masking source is English-only with entities on
    # every row, so a 10% margin covers the rare row its spans drop from. Near
    # the end of a split the fetch returns fewer rows and the caller reports
    # the shortfall.
    fetch = limit + limit // 10 if key == "gretel_en" else limit * 3
    rows = _fetch_rows_from_offset(src["repo"], src["config"], src["split"],
                                   src["revision"], offset, fetch, keep)

    pool: list[dict] = []
    seen: set[str] = set()
    for row in rows:
        parsed = parser(row)
        if parsed is None:
            continue
        text, spans, drops, dropped = parsed
        if dropped:
            stats.gretel_dropped.update({f"{key}:{k}": v for k, v in dropped.items()})
        digest = _text_hash(text)
        if digest in seen:
            stats.gretel_dropped[f"{key}:<duplicate text>"] += 1
            continue
        seen.add(digest)
        spans = bh.normalize_spans(spans, text)
        spans = _drop_nonabsolute_date_spans(text, spans, f"{key}:train", stats)
        # A span ``drop_implausible`` removed is gold noise, but its text is
        # often a real value glued to a neighbouring field ("Aaron
        # Stokes-Hayes204 Dawn Plaza"), so it must not train as O. Its range
        # becomes an ignore range. A range that would sit under a kept span
        # loses to the span, as in the Nemotron builder: one position cannot be
        # both labelled and skipped.
        drops = [r for r in drops
                 if not any(r[0] < s["end"] and s["start"] < r[1] for s in spans)]
        if spans:
            pool.append({"text": text, "spans": spans,
                         "ignore": _merge_ranges(drops) if drops else [],
                         "ignored_spans": len(drops)})

    if len(pool) > limit:
        # Only the finance source has an organization quota; the English pool
        # falls back to a plain random draw.
        quotas = []
        if key == "gretel_fin":
            quotas = [
                (lambda doc: _pool_org_count(doc) >= ORG_PRIORITY_MIN,
                 ORG_PRIORITY_SHARE,
                 f"{key} rows with {ORG_PRIORITY_MIN}+ organizations"),
            ]
        if quotas:
            pool, quota_notes = _quota_sample(pool, limit, rng, quotas)
            stats.gretel_composition.extend(quota_notes)
        else:
            pool = rng.sample(pool, limit)
    records = [
        Record(
            id=f"train-{key}-{i:05d}",
            text=doc["text"],
            spans=[Span(s["start"], s["end"], s["type"]) for s in doc["spans"]],
            source=src["repo"],
            ignore=doc["ignore"],
        )
        for i, doc in enumerate(pool)
    ]
    stats.gretel_ignored_spans[f"{key}:train"] += sum(
        doc["ignored_spans"] for doc in pool)
    records = _wrap_some_chat(bh, records, rng)
    stats.train_by_source[src["repo"]] += len(records)
    return records, offset, len(rows), len(pool)


def _wrap_some_chat(bh, records: list[Record], rng: random.Random) -> list[Record]:
    """Reshape a deterministic share of benchmark-like docs into chat messages.

    Used for the dev set and for the gretel training rows, so both see the
    shape the benchmark gives ``WRAP_FRACTION`` of its documents.
    """
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
            ignore=[(start + shift, end + shift) for start, end in rec.ignore],
        )
    return wrapped


def _gretel_train(en_limit: int, fin_limit: int, dev_gretel: int, seed: int,
                  stats: _Stats) -> tuple[list[Record], list[str]]:
    """Build the gretel share of the training rows.

    A source that cannot be reached is reported and skipped rather than failing
    the run, so a network blip costs the gretel share and not the whole dataset.
    """
    bh = _build_heldout_module()
    rng = random.Random(seed ^ 0x6EA7)
    records: list[Record] = []
    notes: list[str] = []
    for key, limit in (("gretel_en", en_limit), ("gretel_fin", fin_limit)):
        if limit <= 0:
            continue
        try:
            got, offset, fetched, pool = _gretel_train_records(
                bh, key, limit, dev_gretel, rng, stats)
        except Exception as exc:  # noqa: BLE001
            notes.append(f"{key} train source FAILED: {exc}")
            continue
        note = (
            f"{key} train rows: {len(got)}/{limit} from offset {offset}+, "
            f"{fetched} rows fetched, {pool} usable "
            f"(benchmark window 0-{int(bh.SOURCES[key]['fetch_rows']) - 1}, "
            f"dev window after it)"
        )
        if len(got) < limit:
            note += " -- SHORTFALL: the split has no more usable rows"
        notes.append(note)
        records += got
    return records, notes


def _dev_records(seed: int, dev_gretel: int,
                 stats: _Stats) -> tuple[list[Record], list[str], set[str]]:
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
    return records, notes, held_hashes


def _check_disjoint(name: str, hashes: set[str], other: set[str],
                    other_name: str) -> int:
    """Fail when any text in ``hashes`` also appears in ``other``.

    Returns the intersection size (always 0 when it returns at all), so the
    caller prints one number from one place.
    """
    leaked = hashes & other
    if leaked:
        raise RuntimeError(
            f"{name} and {other_name} share {len(leaked)} record texts; "
            f"first hashes: {sorted(leaked)[:3]}"
        )
    return len(leaked)


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


_BARE_NUMBER_TEXT_RE = re.compile(r"(?<![\d.])\d{2,5}(?![\d.])")


def _print_label_statistics(title: str, records: list[Record]) -> None:
    """Surface-level statistics the gap fixes are judged on.

    Prints, per source and pooled: the DATE surface classes, organization
    spans per doc, the location split rate (share of LOCATION spans with a
    same-type neighbour across a comma, which is what the benchmark scores as
    a false positive), and the bare 2-5 digit numbers left as non-PII
    background. Every DATE span left in the gold is ``absolute``: the
    non-absolute classes are dropped during preparation.
    """
    date_cls: collections.Counter = collections.Counter()
    per_src: dict[str, collections.Counter] = collections.defaultdict(
        collections.Counter)
    for rec in records:
        text = rec.text
        spans = sorted(rec.spans, key=lambda s: s.start)
        src = per_src[rec.source]
        src["docs"] += 1
        covered = [(s.start, s.end) for s in spans]
        for span in spans:
            surface = text[span.start:span.end]
            if span.type == "date":
                klass = date_class(surface)
                date_cls[klass] += 1
                src[f"date:{klass}"] += 1
                src["dates"] += 1
            elif span.type == "organization":
                src["orgs"] += 1
            elif span.type == "location":
                src["locs"] += 1
                if _BARE_NUMBER_RE.fullmatch(surface.strip()):
                    src["numeric_locs"] += 1
        locs = [s for s in spans if s.type == "location"]
        for a, b in zip(locs, locs[1:]):
            gap = text[a.end:b.start].strip(" \t\n\r")
            if gap in ("", ","):
                src["loc_splits"] += 1
        for match in _BARE_NUMBER_TEXT_RE.finditer(text):
            if any(match.start() < end and start < match.end()
                   for start, end in covered):
                continue
            src["bare_numbers_o"] += 1

    total_dates = sum(date_cls.values())
    print(f"\n--- DATE surface classes ({title}) ---")
    for klass in DATE_CLASSES:
        count = date_cls.get(klass, 0)
        share = count / total_dates if total_dates else 0.0
        print(f"  {klass:12s} {count:8d}  {share:6.1%}")
    nonabs = sum(date_cls.get(k, 0) for k in NON_ABSOLUTE_DATE_CLASSES)
    print(f"  {'non-absolute':12s} {nonabs:8d}  "
          f"{nonabs / total_dates if total_dates else 0.0:6.1%}  "
          f"(should be 0: these leave the gold)")

    print(f"\n--- surface statistics per source ({title}) ---")
    print(f"  {'source':46s} {'org/doc':>8s} {'date/doc':>9s} "
          f"{'loc/doc':>8s} {'split':>7s} {'num-loc':>7s} {'bare#-O':>8s}")
    for src, row in sorted(per_src.items()):
        docs = row["docs"] or 1
        print(f"  {src[:46]:46s} {row['orgs'] / docs:8.3f} "
              f"{row['dates'] / docs:9.3f} {row['locs'] / docs:8.3f} "
              f"{row['loc_splits'] / max(1, row['locs']):7.3f} "
              f"{row['numeric_locs']:7d} {row['bare_numbers_o']:8d}")


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--sample", type=int, default=0,
                    help="max Nemotron source rows to read (0 = all); smoke only")
    ap.add_argument("--nemotron-train", type=int, default=NEMOTRON_TRAIN,
                    help="Nemotron rows in the training split (0 = no cap)")
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
    ap.add_argument("--gretel-en-train", type=int, default=GRETEL_EN_TRAIN,
                    help="gretel-pii-masking-en-v1 rows in the training split "
                         "(0 = none)")
    ap.add_argument("--gretel-fin-train", type=int, default=GRETEL_FIN_TRAIN,
                    help="synthetic_pii_finance_multilingual English rows in the "
                         "training split (0 = none)")
    args = ap.parse_args(argv)

    from synthetic import generate as synth_generate

    stats = _Stats()

    # Smoke runs read few rows; shrink the dev stride with the sample so a
    # small run still has an in-distribution dev slice (never below 1).
    dev_every = args.dev_nemotron_every
    if dev_every and args.sample:
        dev_every = max(1, min(dev_every, args.sample // 50))
    nemotron_train, nemotron_dev = _nemotron_records(
        args.sample, args.nemotron_train, dev_every, stats)

    print(f"[prepare] Nemotron rows read: {stats.rows_read} "
          f"(train {len(nemotron_train)} of cap {args.nemotron_train or 'none'}, "
          f"dev {len(nemotron_dev)}, records dropped {stats.records_dropped})")
    stats.train_by_source[DATASET_ID] += len(nemotron_train)

    gretel_train: list[Record] = []
    gretel_notes: list[str] = []
    if args.gretel_en_train or args.gretel_fin_train:
        gretel_train, gretel_notes = _gretel_train(
            args.gretel_en_train, args.gretel_fin_train,
            args.dev_gretel, args.seed, stats)
        for note in gretel_notes:
            print(f"[prepare] {note}")

    real_train = nemotron_train + gretel_train
    max_synth = int(len(real_train) * SYNTHETIC_SHARE / (1 - SYNTHETIC_SHARE))
    synthetic: list[Record] = []
    if args.synthetic:
        n_synth = min(args.synthetic, max_synth)
        if n_synth < args.synthetic:
            print(f"[prepare] synthetic capped at {n_synth} "
                  f"({SYNTHETIC_SHARE:.0%} of training records)")
        synthetic = synth_generate(n_synth, args.synthetic_seed)
        stats.train_by_source["synthetic"] += len(synthetic)
        print(f"[prepare] synthetic records: {len(synthetic)}")

    train = real_train + synthetic
    if not train:
        print("[prepare] ERROR: no training records produced", file=sys.stderr)
        return 1

    dev_records, dev_notes, held_hashes = _dev_records(
        args.seed, args.dev_gretel, stats)
    validation = nemotron_dev + dev_records
    if nemotron_dev:
        stats.dev_by_source[DATASET_ID] += len(nemotron_dev)
    if not validation:
        print("[prepare] ERROR: no validation records produced "
              "(every dev source failed)", file=sys.stderr)
        return 1

    # Hard guard: no training row may reuse a held-out or dev text. The offset
    # windows already exclude both, so a hit here means an offset drifted.
    train_hashes = {_text_hash(rec.text) for rec in train}
    dev_hashes = {_text_hash(rec.text) for rec in validation}
    disjoint = [
        ("train vs held-out", _check_disjoint("train", train_hashes,
                                              held_hashes, "held-out"),
         len(train_hashes), len(held_hashes)),
        ("train vs dev", _check_disjoint("train", train_hashes,
                                         dev_hashes, "dev"),
         len(train_hashes), len(dev_hashes)),
        ("dev vs held-out", _check_disjoint("dev", dev_hashes,
                                            held_hashes, "held-out"),
         len(dev_hashes), len(held_hashes)),
    ]

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

    print("\n--- training records by source ---")
    for source, count in sorted(stats.train_by_source.items()):
        if count:
            print(f"  {count:7d}  {source}")

    print("\n--- gretel training rows ---")
    for note in gretel_notes:
        print(f"  {note}")
    if not gretel_notes:
        print("  (none)")
    for key in sorted(stats.gretel_dropped):
        print(f"  dropped {key:40s} {stats.gretel_dropped[key]:6d}")
    ignored_total = sum(stats.gretel_ignored_spans.values())
    print(f"  implausible spans written as ignore ranges (not trained as O): "
          f"{ignored_total}")
    for key in sorted(stats.gretel_ignored_spans):
        print(f"  ignored {key:40s} {stats.gretel_ignored_spans[key]:6d} spans")

    print("\n--- name span merges ---")
    print(f"  merged name spans: {stats.merged_names} "
          f"(across {stats.merged_records} records)")

    print("\n--- address span merges ---")
    print(f"  merged address parts: {stats.merged_addresses} "
          f"(across {stats.merged_address_records} records)")
    print(f"  lone numeric address parts dropped to O: "
          f"{stats.numeric_address_parts}")

    print("\n--- non-absolute DATE spans dropped from gold (trained as O) ---")
    if stats.nonabsolute_dates:
        for key in sorted(stats.nonabsolute_dates):
            print(f"  {key:24s} {stats.nonabsolute_dates[key]:7d} spans")
    else:
        print("  (none)")

    if stats.gretel_composition:
        print("\n--- gretel pool composition (priority quotas) ---")
        for note in stats.gretel_composition:
            print(f"  {note}")

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
    _print_label_statistics("train split", train)

    print("\n--- text-hash disjointness (all intersections must be 0) ---")
    for label, intersection, left, right in disjoint:
        print(f"  {label:20s} {left:7d} vs {right:7d} texts, "
              f"intersection {intersection}")

    print("\n--- dev/held-out notes ---")
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
