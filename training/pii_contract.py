"""Shared contract between the training pipeline and the ShhAi Elixir runtime.

Single source of truth for:

* the trained PII type set (contract item 1),
* the BIO label vocabulary and its fixed integer order,
* the mapping from ``nvidia/Nemotron-PII`` span labels onto those types,
* the span-JSONL record shape (contract item 2).

Anything that reads or writes a contract JSONL imports from here so the
label space can never drift between ``prepare_data.py``, ``train.py`` and
``export.py``.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Iterable

# --------------------------------------------------------------------------
# Trained type set (contract item 1)
# --------------------------------------------------------------------------
# Uppercase type names, exactly as they appear in the model's BIO tags.
# ``ShhAi.Config`` maps ``B-<TYPE>``/``I-<TYPE>`` -> the lowercase atom via
# ``String.to_existing_atom(String.downcase(type))`` restricted to the
# supported types. Regex still owns api_key / auth_token / private_key, so
# those are deliberately absent here.
TRAINED_TYPES: tuple[str, ...] = (
    "NAME",
    "LOCATION",
    "DATE",
    "ORGANIZATION",
    "TITLE",
    "AGE",
    "FINANCIAL",
    "PHONE",
    "EMAIL",
    "URL",
    "IP_ADDRESS",
    "NATIONAL_ID",
    "PASSPORT",
    "SSN",
    "DEVICE_ID",
    "MEDICAL_ID",
    "SECRET",
)

# ``O`` first, then B-/I- for every type in a fixed order. The order is part
# of the model artifact: ``export.py`` bakes it into ``config.json`` as
# ``id2label`` and the Elixir loader reads the tag strings, not the indices,
# but keeping the order stable makes checkpoints comparable across runs.
LABELS: tuple[str, ...] = ("O",) + tuple(
    f"{prefix}-{t}" for t in TRAINED_TYPES for prefix in ("B", "I")
)

LABEL2ID: dict[str, int] = {label: i for i, label in enumerate(LABELS)}
ID2LABEL: dict[int, str] = {i: label for i, label in enumerate(LABELS)}

# Lowercase contract type name -> uppercase BIO type name.
_LOWER_TO_UPPER: dict[str, str] = {t.lower(): t for t in TRAINED_TYPES}

# --------------------------------------------------------------------------
# Nemotron-PII label mapping
# --------------------------------------------------------------------------
# The 54 labels observed in ``nvidia/Nemotron-PII`` (train split). Every
# mapped label projects onto a contract type; every label absent from this
# table is dropped (reported by ``prepare_data.py``) so the model is never
# taught a type the runtime cannot emit.
#
# Judgment calls, spelled out so they can be reviewed:
#   * ``certificate_license_number`` / ``tax_id`` -> national_id: government
#     issued identifiers (driver's licence, tax id) with no more specific
#     contract type.
#   * ``medical_record_number`` / ``health_plan_beneficiary_number`` ->
#     medical_id.
#   * ``mac_address`` / ``device_identifier`` / ``vehicle_identifier`` /
#     ``license_plate`` -> device_id (matches the shipped NER module, which
#     folds IMEI / MAC / VIN / plate into :device_id).
#   * ``api_key`` / ``http_cookie`` -> secret: both are credentials the
#     runtime reports as :secret. Regex also owns api_key, but a NER span on
#     the bare key value does not hurt that path and teaches SECRET on
#     key-shaped strings, which the benchmark scores.
#   * ``occupation`` is resolved per span by :func:`map_nemotron_label`, not by
#     a fixed entry: Nemotron tags departments and offices ("Finance
#     Department", "Ministry of Justice") as occupation too, and those are
#     organizations, not titles.
#   * ``customer_id`` / ``employee_id`` / ``unique_id`` are DROPPED: they are
#     opaque internal identifiers. No contract type covers them (FINANCIAL is
#     payment instruments, DEVICE_ID is device/vehicle hardware), and
#     inventing one teaches spurious detections that cost precision on the
#     ai4privacy benchmark.
#   * ``user_name`` is dropped, mirroring the ai4privacy scorer.
#   * Biometric identifiers are dropped: no contract type.
#   * Demographic/attribute labels (gender, race_ethnicity, ...) are dropped:
#     no contract type.
NEMOTRON_LABEL_MAP: dict[str, str] = {
    # Names
    "first_name": "name",
    "last_name": "name",
    # Dates / times
    "date": "date",
    "date_of_birth": "date",
    "date_time": "date",
    "time": "date",
    # Age
    "age": "age",
    # Contact
    "email": "email",
    "phone_number": "phone",
    "fax_number": "phone",
    # Network
    "url": "url",
    "ipv4": "ip_address",
    "ipv6": "ip_address",
    # Government identifiers
    "ssn": "ssn",
    "certificate_license_number": "national_id",
    "tax_id": "national_id",
    # Organisation / role (``occupation`` is resolved by
    # map_nemotron_label: title or organization, decided from the surface)
    "company_name": "organization",
    # Location
    "city": "location",
    "state": "location",
    "country": "location",
    "county": "location",
    "street_address": "location",
    "postcode": "location",
    "coordinate": "location",
    # Financial
    "account_number": "financial",
    "bank_routing_number": "financial",
    "credit_debit_card": "financial",
    "swift_bic": "financial",
    # Medical
    "medical_record_number": "medical_id",
    "health_plan_beneficiary_number": "medical_id",
    # Credentials
    "password": "secret",
    "pin": "secret",
    "cvv": "secret",
    "api_key": "secret",
    "http_cookie": "secret",
    # Device / vehicle identifiers
    "mac_address": "device_id",
    "device_identifier": "device_id",
    "vehicle_identifier": "device_id",
    "license_plate": "device_id",
}

# Dropped Nemotron labels, with the reason, for the prepare_data report.
NEMOTRON_DROPPED: dict[str, str] = {
    "customer_id": "opaque internal id, no contract type",
    "employee_id": "opaque internal id, no contract type",
    "unique_id": "opaque internal id, no contract type",
    "biometric_identifier": "no contract type (not a device id)",
    "user_name": "no contract type (ai4privacy scorer drops USERNAME)",
    "education_level": "attribute, not PII identifier",
    "employment_status": "attribute, not PII identifier",
    "gender": "attribute, not PII identifier",
    "race_ethnicity": "attribute, not PII identifier",
    "religious_belief": "attribute, not PII identifier",
    "political_view": "attribute, not PII identifier",
    "sexuality": "attribute, not PII identifier",
    "language": "attribute, not PII identifier",
    "blood_type": "attribute, not PII identifier",
}

# Dropped labels whose *surface* must never be taught as ``O``.
#
# The attributes above are ordinary English words ("female", "full-time"), so
# labelling them O is correct for this contract: the runtime has no type for
# them and must not fire on them. The labels below are entity-shaped
# identifiers instead ("EMP-4471", "jdoe88"); leaving them in a record as
# ordinary text would teach the model that identifier-shaped strings are O,
# which directly costs recall on the benchmark's FINANCIAL / DEVICE_ID /
# SECRET spans.
#
# The record keeps its other spans: the range of one of these labels moves to
# ``Record.ignore`` so the training step skips it instead of labelling it O.
NEMOTRON_IGNORED_LABELS: frozenset[str] = frozenset({
    "customer_id",
    "employee_id",
    "unique_id",
    "biometric_identifier",
    "user_name",
})

# Words that make a Nemotron ``occupation`` surface an organisation rather
# than a job title. Matching is anchored on the last word ("Finance
# Department", "Ministry of Justice" ends in "Justice", so an "of" phrase is
# allowed to carry the organisation noun earlier) so real titles such as
# "Court Clerk", "Police Officer" or "Director of Operations" stay titles.
_ORG_TAIL_WORDS: frozenset[str] = frozenset({
    "department", "division", "office", "bureau", "agency", "ministry",
    "court", "commission", "committee", "council", "authority", "institute",
    "university", "college", "school", "hospital", "clinic", "center",
    "centre", "bank", "company", "corporation", "corp", "inc", "ltd", "llc",
    "plc", "group", "solutions", "systems", "team", "unit", "directorate",
    "secretariat", "foundation", "association", "laboratory", "labs",
    "board", "police", "district", "municipality", "parish", "army", "navy",
    "forces", "commission", "administration", "registry", "treasury",
})

_WORD_RE = re.compile(r"[A-Za-z]+")


def looks_like_organization(surface: str) -> bool:
    """True when an ``occupation`` surface names an organisation, not a role.

    Heuristic, kept deliberately small: the organisation noun must be the last
    word, or sit before an "of"/"for" phrase ("Ministry of Justice").
    """
    words = [w.lower() for w in _WORD_RE.findall(surface)]
    if not words:
        return False
    if words[-1] in _ORG_TAIL_WORDS:
        return True
    if any(w in ("of", "for") for w in words[1:]):
        return any(w in _ORG_TAIL_WORDS for w in words[:-1])
    return False


def map_nemotron_label(label: str | None, surface: str) -> str | None:
    """Nemotron span label -> contract type, or None when the span is dropped.

    ``occupation`` needs the surface text: Nemotron tags both roles ("Staff
    Accountant") and departments/offices ("Finance Department") with it.
    """
    if label is None:
        return None
    if label == "occupation":
        return "organization" if looks_like_organization(surface) else "title"
    return NEMOTRON_LABEL_MAP.get(label)


def upper_type(lower: str) -> str:
    """Lowercase contract type name -> uppercase BIO type name."""
    return _LOWER_TO_UPPER[lower]


def bio_label(prefix: str, lower_type: str) -> str:
    return f"{prefix}-{upper_type(lower_type)}"


# --------------------------------------------------------------------------
# Span-JSONL record shape (contract item 2)
# --------------------------------------------------------------------------
# One JSON object per line:
#   {"id": str, "text": str,
#    "spans": [{"start": int, "end": int, "type": "<lowercase type>"}],
#    "source": str,
#    "ignore": [[start, end], ...]}
# ``start``/``end`` are Unicode codepoint (Python str index) half-open offsets.
#
# ``ignore`` is optional: absent and ``[]`` both mean "no ignored regions". A
# range marks text whose gold label exists in the source but not in this
# contract (internal ids, usernames, tokens). The training step must not
# label those positions ``O``; it sets them to the ignore index (-100)
# instead. Ignored ranges never overlap a kept span.

IgnoreRange = tuple[int, int]  # (start, end), half-open


@dataclass
class Span:
    start: int
    end: int
    type: str  # lowercase contract type name

    def to_json(self) -> dict:
        return {"start": self.start, "end": self.end, "type": self.type}

    @staticmethod
    def from_json(obj: dict) -> "Span":
        return Span(int(obj["start"]), int(obj["end"]), str(obj["type"]))


@dataclass
class Record:
    id: str
    text: str
    spans: list[Span] = field(default_factory=list)
    source: str = ""
    ignore: list[IgnoreRange] = field(default_factory=list)

    def to_json(self) -> dict:
        obj = {
            "id": self.id,
            "text": self.text,
            "spans": [s.to_json() for s in self.spans],
            "source": self.source,
        }
        if self.ignore:
            obj["ignore"] = [[int(start), int(end)] for start, end in self.ignore]
        return obj

    @staticmethod
    def from_json(obj: dict) -> "Record":
        return Record(
            id=str(obj["id"]),
            text=obj["text"],
            spans=[Span.from_json(s) for s in obj.get("spans", [])],
            source=obj.get("source", ""),
            ignore=[(int(start), int(end)) for start, end in (obj.get("ignore") or [])],
        )


def validate_record(rec: Record) -> list[str]:
    """Return a list of human-readable problems (empty means valid)."""
    problems: list[str] = []
    n = len(rec.text)
    for s in rec.spans:
        if s.type not in _LOWER_TO_UPPER:
            problems.append(f"unknown type {s.type!r}")
        if not (0 <= s.start < s.end <= n):
            problems.append(f"span out of range: {s}")
    ordered = sorted(rec.ignore)
    for start, end in ordered:
        if not (0 <= start < end <= n):
            problems.append(f"ignore out of range: ({start}, {end})")
    for (a_start, a_end), (b_start, b_end) in zip(ordered, ordered[1:]):
        if b_start < a_end:
            problems.append(f"ignore ranges overlap: ({a_start}, {a_end}) and "
                            f"({b_start}, {b_end})")
    for start, end in ordered:
        if 0 <= start < end <= n:
            hit = next((s for s in rec.spans if start < s.end and s.start < end), None)
            if hit is not None:
                problems.append(f"ignore range ({start}, {end}) overlaps span {hit}")
    return problems


def write_jsonl(path: str, records: Iterable[Record]) -> int:
    count = 0
    with open(path, "w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec.to_json(), ensure_ascii=False) + "\n")
            count += 1
    return count


def read_jsonl(path: str) -> list[Record]:
    out: list[Record] = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(Record.from_json(json.loads(line)))
    return out
