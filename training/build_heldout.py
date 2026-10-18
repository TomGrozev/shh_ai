#!/usr/bin/env python3
"""Build the held-out PII benchmark for issue #79.

Writes a deterministic span-annotated JSONL file consumed by the Elixir eval
harness (`test/eval/...`) to compare the fine-tuned NER model against the
shipped `gravitee-io/bert-small-pii-detection`. It is deliberately **not**
ai4privacy (that stays the honest in-distribution test) and **not** any source
used to train the model (`nvidia/Nemotron-PII` and the synthetic generator).

Output: ``$SHHAI_EVAL_CACHE_DIR`` (default ``~/.cache/shh_ai/eval``)
``/heldout_v1.jsonl`` — one JSON object per line::

    {"id": str, "text": str,
     "spans": [{"start": int, "end": int, "type": "<lowercase type>"}],
     "source": str}

Offsets are Unicode codepoint half-open ``[start, end)`` indices into ``text``
(Python ``str`` indices), matching how the ai4privacy scorer reads its offsets.

Determinism
-----------
Every network input is pinned to a dataset revision, and all sampling uses one
seeded ``random.Random(SEED)`` over a fixed fetch order, so two runs produce
byte-identical output.

Sources (all licences permit commercial use)
--------------------------------------------
* ``gretelai/gretel-pii-masking-en-v1``        apache-2.0  (synthetic English documents)
* ``gretelai/synthetic_pii_finance_multilingual`` apache-2.0  (synthetic English finance docs)
* ``ildpil/text-anonymization-benchmark``      mit         (real ECHR court cases, TAB)

The ECHR/TAB dataset is real, non-synthetic English legal prose; its ``train``
split is deliberately excluded so the held-out set never touches data another
project might train on.

The per-source label -> contract-type mappings and the licences/URLs live below
in ``SOURCES`` and the ``*_MAP`` tables; the script prints a full report
(sources, mapping, per-type counts, long/wrapped shares) to stdout.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
import zipfile
from collections import Counter

# The span-JSONL record shape and the trained type set are owned by
# ``training/pii_contract.py`` (shared with prepare_data/train/export). Import
# it so the held-out gold never drifts from the model's label space.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pii_contract  # noqa: E402  (after sys.path tweak)

# --------------------------------------------------------------------------- #
# Determinism and shaping knobs
# --------------------------------------------------------------------------- #

SEED = 79
N_DOCS = 1000

# Fraction of documents reshaped into a chat-style user message.
WRAP_FRACTION = 0.35

# A document counts as "long" when its whitespace word count exceeds this.
# WordPiece emits at least one token per whitespace word, so >512 words
# guarantees the text exceeds the model window (`lib/shh_ai/pii/ner.ex`,
# `@max_sequence_length 512`). It is a conservative lower bound on the true
# token count.
LONG_WORD_THRESHOLD = 512
CONCAT_WORD_TARGET = 600  # concatenated docs are grown until they clear this

# Per-bucket document counts (sum == N_DOCS).
TAB_SINGLE = 120  # single real ECHR docs (naturally long)
TAB_CONCAT = 15  # pairs of real ECHR docs joined (>1024 tokens)
GRETEL_EN_SINGLE = 400
GRETEL_FIN_SINGLE = 400
GRETEL_CONCAT = 65  # synthetic docs joined until they clear CONCAT_WORD_TARGET

CONCAT_SEP = "\n\n"

CHAT_PREFIXES = [
    "Can you check the following text for personal data?\n\n",
    "Please identify any personal information in this text:\n\n",
    "Here is a message I received. What personal data does it contain?\n\n",
    "Review the text below and tell me what should be redacted:\n\n",
]

# --------------------------------------------------------------------------- #
# Sources: licences, URLs, pinned revisions
# --------------------------------------------------------------------------- #

SOURCES = {
    "gretel_en": {
        "repo": "gretelai/gretel-pii-masking-en-v1",
        "license": "apache-2.0",
        "url": "https://huggingface.co/datasets/gretelai/gretel-pii-masking-en-v1",
        "revision": "e06eb1499ca8d54470f085021cd8e54f9efac7fd",
        "config": "default",
        "split": "train",
        "fetch_rows": 1500,
    },
    "gretel_fin": {
        "repo": "gretelai/synthetic_pii_finance_multilingual",
        "license": "apache-2.0",
        "url": "https://huggingface.co/datasets/gretelai/synthetic_pii_finance_multilingual",
        "revision": "7b844d16738527a04264f50214cb426a4cea0897",
        "config": "default",
        "split": "train",
        "fetch_rows": 2500,
    },
    "tab": {
        "repo": "ildpil/text-anonymization-benchmark",
        "license": "mit",
        "url": "https://huggingface.co/datasets/ildpil/text-anonymization-benchmark",
        "revision": "1f22ce098996054689b5b331fb20b3a74a78e1c5",
        # dev + test only; TAB train is excluded from the held-out set.
        "zips": ["echr_dev.zip", "echr_test.zip"],
    },
}

# --------------------------------------------------------------------------- #
# Label -> contract type maps (drop the rest and report them)
# --------------------------------------------------------------------------- #

GRETEL_EN_MAP = {
    # name
    "first_name": "name",
    "last_name": "name",
    "name": "name",
    # location
    "street_address": "location",
    "address": "location",
    "city": "location",
    "state": "location",
    "country": "location",
    "postcode": "location",
    "coordinate": "location",
    # date
    "date": "date",
    "date_time": "date",
    "time": "date",
    "date_of_birth": "date",
    # organization
    "company_name": "organization",
    # phone / email / url
    "phone_number": "phone",
    "email": "email",
    "url": "url",
    # network
    "ipv4": "ip_address",
    "ipv6": "ip_address",
    # government ids
    "ssn": "ssn",
    "national_id": "national_id",
    "tax_id": "national_id",
    "certificate_license_number": "national_id",
    # financial
    "credit_card_number": "financial",
    "account_number": "financial",
    "bank_routing_number": "financial",
    "swift_bic": "financial",
    # medical
    "medical_record_number": "medical_id",
    "health_plan_beneficiary_number": "medical_id",
    # device / vehicle
    "device_identifier": "device_id",
    "vehicle_identifier": "device_id",
    "license_plate": "device_id",
    # secrets (cvv/pin -> secret, mirroring pii_contract; api_key is dropped
    # because regex owns it in the runtime)
    "cvv": "secret",
    "password": "secret",
}

GRETEL_FIN_MAP = {
    "name": "name",
    "first_name": "name",
    "last_name": "name",
    "date": "date",
    "date_time": "date",
    "time": "date",
    "date_of_birth": "date",
    "company": "organization",
    "street_address": "location",
    "local_latlng": "location",
    "email": "email",
    "phone_number": "phone",
    "iban": "financial",
    "bban": "financial",
    "credit_card_number": "financial",
    "bank_routing_number": "financial",
    "swift_bic_code": "financial",
    "ipv4": "ip_address",
    "ipv6": "ip_address",
    "passport_number": "passport",
    "ssn": "ssn",
    "driver_license_number": "national_id",
    # credentials -> secret (cvv/pin), mirroring pii_contract
    "credit_card_security_code": "secret",
    "account_pin": "secret",
    "password": "secret",
}

# TAB: only DIRECT identifiers (unambiguous "must mask" PII). QUASI
# (context-dependent quasi-identifiers) is excluded because it is dominated by
# procedural case dates that would swamp the benchmark's `date` type.
TAB_MAP = {
    "PERSON": "name",
    "LOC": "location",
    "ORG": "organization",
    "DATETIME": "date",
}

CONTRACT_TYPES = [t.lower() for t in pii_contract.TRAINED_TYPES]


# --------------------------------------------------------------------------- #
# Fetching (stdlib only; cached under the eval cache dir)
# --------------------------------------------------------------------------- #


def cache_dir() -> str:
    return os.environ.get("SHHAI_EVAL_CACHE_DIR") or os.path.join(
        os.path.expanduser("~"), ".cache", "shh_ai", "eval"
    )


def _src_cache_dir() -> str:
    d = os.path.join(cache_dir(), "heldout_v1_src")
    os.makedirs(d, exist_ok=True)
    return d


def _http_get(url: str, timeout: int = 180) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "shh_ai-heldout/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _get_json(url: str, attempts: int = 6) -> dict:
    """GET + parse JSON, retrying the datasets-server's transient 429/5xx."""
    delay = 2.0
    for attempt in range(1, attempts + 1):
        try:
            return json.loads(_http_get(url))
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504) or attempt == attempts:
                raise
            sys.stderr.write(f"  retry {attempt}/{attempts} after HTTP {exc.code} (sleep {delay:.0f}s)\n")
            time.sleep(delay)
            delay *= 2
        except urllib.error.URLError:
            if attempt == attempts:
                raise
            time.sleep(delay)
            delay *= 2
    raise AssertionError("unreachable")


def fetch_rows(dataset: str, config: str, split: str, revision: str,
               limit: int, keep: tuple[str, ...]) -> list[dict]:
    """Page the HuggingFace datasets-server `/rows` API, trimmed to `keep`."""
    slug = dataset.replace("/", "__")
    path = os.path.join(_src_cache_dir(), f"rows_{slug}_{split}_{revision[:12]}.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)

    rows: list[dict] = []
    offset = 0
    while offset < limit:
        length = min(100, limit - offset)
        url = (
            "https://datasets-server.huggingface.co/rows"
            f"?dataset={dataset}&config={config}&split={split}"
            f"&offset={offset}&length={length}&revision={revision}"
        )
        try:
            payload = _get_json(url)
        except urllib.error.URLError as exc:  # pragma: no cover - network
            raise SystemExit(f"failed to fetch rows for {dataset}: {exc}")
        page = payload.get("rows") or []
        if not page:
            break
        for entry in page:
            row = entry["row"]
            rows.append({k: row.get(k) for k in keep})
        offset += len(page)
        time.sleep(0.5)  # be polite to the public datasets-server

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rows, fh)
    return rows


def fetch_zip(dataset: str, revision: str, name: str) -> zipfile.ZipFile:
    path = os.path.join(_src_cache_dir(), f"{revision[:12]}_{name}")
    if not os.path.exists(path):
        url = f"https://huggingface.co/datasets/{dataset}/resolve/{revision}/{name}"
        with open(path + ".part", "wb") as fh:
            fh.write(_http_get(url))
        os.replace(path + ".part", path)
    return zipfile.ZipFile(path)


# --------------------------------------------------------------------------- #
# Parsing sources into (text, spans, dropped_labels)
# --------------------------------------------------------------------------- #


def _overlaps(a: int, b: int, span: dict) -> bool:
    return a < span["end"] and span["start"] < b


def _locate(text: str, needle: str, spans: list[dict]) -> int:
    """First occurrence of `needle` that hits no kept span.

    `entities` are *not* listed in text order, so we must search the whole
    string rather than scan forward from a cursor.
    """
    i = text.find(needle)
    while i >= 0:
        if not any(_overlaps(i, i + len(needle), sp) for sp in spans):
            return i
        i = text.find(needle, i + 1)
    return -1


def parse_gretel_en(row: dict) -> tuple[str, list[dict], Counter] | None:
    """gretel-pii-masking-en-v1: entity surfaces are given, but no offsets."""
    ents = row.get("entities")
    if isinstance(ents, str):
        try:
            ents = ast.literal_eval(ents)
        except (ValueError, SyntaxError):
            return None
    if not isinstance(ents, list):
        return None

    text = row.get("text") or ""
    spans: list[dict] = []
    dropped: Counter = Counter()
    for ent in ents:
        if not isinstance(ent, dict):
            continue
        types = ent.get("types") or []
        mapped = next((GRETEL_EN_MAP[t] for t in types if t in GRETEL_EN_MAP), None)
        if mapped is None:
            for t in types:
                dropped[t] += 1
            continue
        surface = ent.get("entity")
        if not surface:
            continue
        i = _locate(text, surface, spans)
        if i < 0:
            dropped["<unlocated>"] += 1
            continue
        spans.append({"start": i, "end": i + len(surface), "type": mapped})
    return text, spans, dropped


def parse_gretel_fin(row: dict) -> tuple[str, list[dict], Counter] | None:
    """synthetic_pii_finance_multilingual: English rows with explicit offsets."""
    if row.get("language") != "English":
        return None
    text = row.get("generated_text") or ""
    raw = row.get("pii_spans")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return None
    if not isinstance(raw, list):
        return None

    spans: list[dict] = []
    dropped: Counter = Counter()
    for span in raw:
        if not isinstance(span, dict):
            continue
        label = span.get("label")
        mapped = GRETEL_FIN_MAP.get(label)
        start, end = span.get("start"), span.get("end")
        if mapped is None:
            dropped[label] += 1
            continue
        if not isinstance(start, int) or not isinstance(end, int) or not 0 <= start < end <= len(text):
            dropped["<bad-offset>"] += 1
            continue
        spans.append({"start": start, "end": end, "type": mapped})
    return text, spans, dropped


def parse_tab_doc(doc: dict) -> tuple[str, list[dict], Counter]:
    text = doc.get("text") or ""
    spans: list[dict] = []
    dropped: Counter = Counter()
    for mention in doc.get("entity_mentions") or []:
        if mention.get("identifier_type") != "DIRECT":
            continue
        etype = mention.get("entity_type")
        mapped = TAB_MAP.get(etype)
        if mapped is None:
            dropped[etype] += 1
            continue
        start, end = mention.get("start_offset"), mention.get("end_offset")
        if not isinstance(start, int) or not isinstance(end, int) or not 0 <= start < end <= len(text):
            dropped["<bad-offset>"] += 1
            continue
        if text[start:end] != mention.get("span_text"):
            dropped["<offset-mismatch>"] += 1
            continue
        spans.append({"start": start, "end": end, "type": mapped})
    return text, spans, dropped


def load_tab_pool(dropped_total: Counter) -> list[dict]:
    src = SOURCES["tab"]
    docs: dict[str, dict] = {}
    for name in src["zips"]:
        with fetch_zip(src["repo"], src["revision"], name) as zf:
            member = zf.namelist()[0]
            entries = json.loads(zf.read(member))
        for doc in entries:
            # Multiple annotators annotate the same case; keep the first seen.
            docs.setdefault(doc["doc_id"], doc)

    pool: list[dict] = []
    for doc in docs.values():
        text, spans, dropped = parse_tab_doc(doc)
        dropped_total.update({f"tab:{k}": v for k, v in dropped.items()})
        if spans:
            pool.append({"text": text, "spans": spans, "source": src["repo"]})
    return pool


def load_gretel_pool(key: str, dropped_total: Counter) -> list[dict]:
    src = SOURCES[key]
    parser = parse_gretel_en if key == "gretel_en" else parse_gretel_fin
    keep = ("text", "entities") if key == "gretel_en" else ("generated_text", "pii_spans", "language")
    rows = fetch_rows(src["repo"], src["config"], src["split"], src["revision"],
                      src["fetch_rows"], keep)
    pool: list[dict] = []
    for row in rows:
        parsed = parser(row)
        if parsed is None:
            continue
        text, spans, dropped = parsed
        dropped_total.update({f"{key}:{k}": v for k, v in dropped.items()})
        if spans:
            pool.append({"text": text, "spans": spans, "source": src["repo"]})
    return pool


# --------------------------------------------------------------------------- #
# Shaping
# --------------------------------------------------------------------------- #


def normalize_spans(spans: list[dict], text: str) -> list[dict]:
    """Drop invalid/blank/overlapping spans, keeping earliest-then-longest."""
    valid = [
        s for s in spans
        if 0 <= s["start"] < s["end"] <= len(text) and text[s["start"]:s["end"]].strip()
    ]
    valid.sort(key=lambda s: (s["start"], -s["end"]))
    kept: list[dict] = []
    for span in valid:
        if kept and span["start"] < kept[-1]["end"]:
            continue
        kept.append(span)
    return kept


def concat_docs(parts: list[dict]) -> dict:
    text = ""
    spans: list[dict] = []
    offset = 0
    for index, part in enumerate(parts):
        if index:
            text += CONCAT_SEP
            offset += len(CONCAT_SEP)
        for span in part["spans"]:
            spans.append({"start": span["start"] + offset,
                          "end": span["end"] + offset,
                          "type": span["type"]})
        text += part["text"]
        offset += len(part["text"])
    return {"text": text, "spans": spans, "source": parts[0]["source"]}


def wrap_chat(doc: dict, prefix: str) -> dict:
    shift = len(prefix)
    return {
        "text": prefix + doc["text"],
        "spans": [{"start": s["start"] + shift, "end": s["end"] + shift, "type": s["type"]}
                  for s in doc["spans"]],
        "source": doc["source"],
    }


def build_docs(rng: random.Random, dropped_total: Counter) -> list[dict]:
    tab_pool = load_tab_pool(dropped_total)
    en_pool = load_gretel_pool("gretel_en", dropped_total)
    fin_pool = load_gretel_pool("gretel_fin", dropped_total)

    for pool in (tab_pool, en_pool, fin_pool):
        rng.shuffle(pool)

    need = TAB_SINGLE + 2 * TAB_CONCAT
    if len(tab_pool) < need:
        raise SystemExit(f"tab pool too small: {len(tab_pool)} < {need}")
    if len(en_pool) < GRETEL_EN_SINGLE:
        raise SystemExit(f"gretel_en pool too small: {len(en_pool)}")
    if len(fin_pool) < GRETEL_FIN_SINGLE:
        raise SystemExit(f"gretel_fin pool too small: {len(fin_pool)}")

    docs: list[dict] = []
    docs += tab_pool[:TAB_SINGLE]
    tab_rest = tab_pool[TAB_SINGLE:need]
    docs += [concat_docs(tab_rest[2 * i:2 * i + 2]) for i in range(TAB_CONCAT)]

    docs += en_pool[:GRETEL_EN_SINGLE]
    docs += fin_pool[:GRETEL_FIN_SINGLE]

    concat_src = en_pool[GRETEL_EN_SINGLE:] + fin_pool[GRETEL_FIN_SINGLE:]
    rng.shuffle(concat_src)
    cursor = 0
    for _ in range(GRETEL_CONCAT):
        parts: list[dict] = []
        words = 0
        while words <= CONCAT_WORD_TARGET:
            if cursor >= len(concat_src):
                raise SystemExit("gretel concat pool exhausted")
            parts.append(concat_src[cursor])
            words += len(concat_src[cursor]["text"].split())
            cursor += 1
        docs.append(concat_docs(parts))

    # Reshape a deterministic subset into chat-style user messages.
    wrap_count = int(len(docs) * WRAP_FRACTION)
    for index in sorted(rng.sample(range(len(docs)), wrap_count)):
        docs[index] = wrap_chat(docs[index], rng.choice(CHAT_PREFIXES))

    return docs


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #


def write_jsonl(docs: list[dict], out_path: str) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    records = []
    for index, doc in enumerate(docs):
        spans = normalize_spans(doc["spans"], doc["text"])
        records.append(pii_contract.Record(
            id=f"heldout-v1-{index:04d}",
            text=doc["text"],
            spans=[pii_contract.Span(s["start"], s["end"], s["type"]) for s in spans],
            source=doc["source"],
        ))
    pii_contract.write_jsonl(out_path, records)


def report(docs: list[dict], dropped_total: Counter, out_path: str) -> None:
    sha = hashlib.sha256(open(out_path, "rb").read()).hexdigest()

    print(f"output: {out_path}")
    print(f"docs:   {len(docs)}   sha256: {sha}")
    print()

    print("sources:")
    for key, src in SOURCES.items():
        print(f"  {src['repo']}  license={src['license']}  {src['url']}")
    print()

    print("label -> contract type mapping:")
    for key, table in (("gretel_en", GRETEL_EN_MAP), ("gretel_fin", GRETEL_FIN_MAP),
                       ("tab", TAB_MAP)):
        for label, ctype in sorted(table.items()):
            print(f"  {key:10s} {label:34s} -> {ctype}")
    print()

    by_source: Counter = Counter()
    by_type: Counter = Counter()
    per_source_type: dict[str, Counter] = {}
    long_docs = 0
    wrapped = 0
    for doc in docs:
        by_source[doc["source"]] += 1
        if len(doc["text"].split()) > LONG_WORD_THRESHOLD:
            long_docs += 1
        if doc["text"].startswith(tuple(CHAT_PREFIXES)):
            wrapped += 1
        counter = per_source_type.setdefault(doc["source"], Counter())
        for span in normalize_spans(doc["spans"], doc["text"]):
            by_type[span["type"]] += 1
            counter[span["type"]] += 1

    print("docs per source:")
    for source, count in sorted(by_source.items()):
        print(f"  {count:5d}  {source}")
    print()

    print("spans per contract type:")
    for ctype in CONTRACT_TYPES:
        print(f"  {by_type.get(ctype, 0):6d}  {ctype}")
    unmapped = {k: v for k, v in by_type.items() if k not in CONTRACT_TYPES}
    if unmapped:
        print(f"  !! non-contract types present: {unmapped}")
    print()

    print("spans per source / type:")
    for source, counter in sorted(per_source_type.items()):
        parts = ", ".join(f"{t}={counter[t]}" for t in CONTRACT_TYPES if counter[t])
        print(f"  {source}: {parts or '(none)'}")
    print()

    total = len(docs) or 1
    print(f"long docs (> {LONG_WORD_THRESHOLD} whitespace words): "
          f"{long_docs} ({100 * long_docs / total:.1f}%)")
    print(f"chat-wrapped docs: {wrapped} ({100 * wrapped / total:.1f}%)")
    print()

    print("dropped labels (no contract counterpart):")
    for label, count in sorted(dropped_total.items()):
        print(f"  {count:6d}  {label}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=os.path.join(cache_dir(), "heldout_v1.jsonl"),
                        help="output JSONL path (default: <eval cache>/heldout_v1.jsonl)")
    args = parser.parse_args(argv)

    rng = random.Random(SEED)
    dropped_total: Counter = Counter()
    docs = build_docs(rng, dropped_total)
    if len(docs) != N_DOCS:
        raise SystemExit(f"expected {N_DOCS} docs, built {len(docs)}")
    write_jsonl(docs, args.out)
    problems = [(rec.id, p) for rec in pii_contract.read_jsonl(args.out)
                for p in pii_contract.validate_record(rec)]
    if problems:
        raise SystemExit(f"invalid records: {problems[:5]}")
    report(docs, dropped_total, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
