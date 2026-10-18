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
#   * ``customer_id`` / ``employee_id`` / ``unique_id`` are DROPPED: they are
#     opaque internal identifiers with no contract type, and mapping them
#     onto device_id would teach spurious device_id detections that cost
#     precision on the ai4privacy benchmark.
#   * ``user_name`` is dropped, mirroring the ai4privacy scorer.
#   * ``api_key`` is dropped: regex owns api_key in the runtime.
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
    # Organisation / role
    "company_name": "organization",
    "occupation": "title",
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
    "api_key": "regex owns api_key in the runtime",
    "http_cookie": "no contract type",
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
#    "source": str}
# ``start``/``end`` are Unicode codepoint (Python str index) half-open offsets.


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

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "text": self.text,
            "spans": [s.to_json() for s in self.spans],
            "source": self.source,
        }

    @staticmethod
    def from_json(obj: dict) -> "Record":
        return Record(
            id=str(obj["id"]),
            text=obj["text"],
            spans=[Span.from_json(s) for s in obj.get("spans", [])],
            source=obj.get("source", ""),
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
