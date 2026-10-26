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
#   * ``http_cookie`` -> secret: a credential the runtime reports as :secret.
#   * ``api_key`` is DROPPED, matching both gretel maps in ``build_heldout``
#     (``api_key`` is in neither ``GRETEL_EN_MAP`` nor ``GRETEL_FIN_MAP``).
#     The asymmetric mapping cost precision: 21 Nemotron api_key spans taught
#     SECRET on key-shaped strings that the held-out gold leaves unlabelled,
#     so every detection there scored as a false positive. Regex owns api_key
#     at runtime (``lib/shh_ai/pii/detector.ex``), so nothing is lost.
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
    "http_cookie": "secret",
    # Device / vehicle identifiers
    "mac_address": "device_id",
    "device_identifier": "device_id",
    "vehicle_identifier": "device_id",
    "license_plate": "device_id",
}

# Nemotron labels that annotate one *part* of a postal address.
#
# The held-out benchmark's gretel gold marks a whole address as ONE location
# span: "531 Novak Bridge, 30688, Lake Michaelshire", "426 Parker Turnpike,
# Suite 956, Jacksonville, FL, USA", "123 Acacia Avenue\nLondon, NW1 3CD".
# Nemotron instead tags each part (street_address, city, state, county,
# postcode, country), so training on those parts teaches the model to fire on
# the parts of an address and the benchmark scores each as a false positive.
# ``prepare_data._merge_address_spans`` joins consecutive parts that are
# separated only by commas and spaces, and that either hold an anchor part or
# carry two different part labels ("California, USA" is an address, a list of
# two cities is not); :mod:`synthetic` renders one span for the same reason.
NEMOTRON_ADDRESS_PARTS: frozenset[str] = frozenset({
    "street_address", "city", "state", "county", "postcode", "country",
})

# A part that only ever belongs to an address, so a run of parts holding one
# of these is an address even when two neighbours share a label kind.
NEMOTRON_ADDRESS_ANCHORS: frozenset[str] = frozenset({
    "street_address", "postcode",
})

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
    # Dropped from NEMOTRON_LABEL_MAP to match the gretel maps; the bare key
    # value must not train as O either, because the runtime's regex still
    # reports it and the held-out gold does not score it.
    "api_key",
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
# DATE surface classes (product decision: non-absolute dates are not PII)
# --------------------------------------------------------------------------
# The product decision: a DATE span counts as PII only when it names a
# calendar instant (a date, a year, a clock time). Relative, durational,
# frequency and placeholder surfaces say nothing about the person on their
# own, so the proxy leaves them in the text and nothing is scored on them.
# One classifier, imported by ``build_heldout`` (benchmark gold),
# ``prepare_data`` (training and dev gold) and ``synthetic`` so the three
# cannot disagree.
#
# ``absolute`` covers every calendar-shaped surface: "1994", "12/03/2024",
# "March 2023", "on 5 March", "Q3 2024", "3pm", "09:30". The non-absolute
# classes follow the surface shape, not the meaning:
#   relative    "the past two days", "end of day tomorrow", "last year"
#   duration    "five (5) years", "5 years", "30-day"
#   frequency   "monthly", "Annual", "each month", "per annum"
#   placeholder "this ______ day of ________, 20__", "[Date]", "DD/MM/YYYY"
# When a surface could be read either way it is ``absolute``: losing a real
# date costs a leak, leaving a relative phrase unlabelled costs nothing.
DATE_CLASSES: tuple[str, ...] = (
    "absolute", "relative", "duration", "frequency", "placeholder",
)

NON_ABSOLUTE_DATE_CLASSES = frozenset({
    "relative", "duration", "frequency", "placeholder",
})

_MONTH_WORD_RE = re.compile(
    r"\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec|january|february"
    r"|march|april|june|july|august|september|october|november|december)\b",
    re.IGNORECASE,
)
# "12/03/2024", "2024-03-12", "12.03.2024".
_CALENDAR_DATE_RE = re.compile(r"\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}")
# "3pm", "09:30", "14:05:12", and military "1914 hours" (19:14), which the
# gretel gold writes as a clock time.
_CLOCK_RE = re.compile(
    r"\d{1,2}:\d{2}|\b\d{1,2}\s*(?:am|pm)\b|^\d{3,4}\s*(?:hours?|hrs?)$",
    re.IGNORECASE,
)
# "20__", "______", "[Date]", "[Start Date]". The text is stripped of its
# backslash escapes first: the finance source writes "this \\_\\_ day of".
_PLACEHOLDER_DATE_RE = re.compile(r"_{2,}|\b20__\b|\[[^\]]{0,24}\]")
# A calendar year on its own: "1994", "March 2023", "Q3 2024". A number that
# is instead a quantity of a unit ("1800 days") is not a year, so the match
# must not be followed by one.
_YEAR_RE = re.compile(
    r"\b(?:1[89]\d\d|20[0-4]\d)\b(?!\s*\)?\s*(?:business |working |calendar )?"
    r"(?:year|month|week|day|hour|minute|second|quarter)s?\b)"
)
# Format templates that hold no date at all: "DD/MM/YYYY", "MM-DD-YY".
_DATE_FORMAT_RE = re.compile(
    r"^(?:yy|yyyy|mm|m|dd|d|mon)[/. -]"
    r"(?:yy|yyyy|mm|m|dd|d|mon)[/. -]"
    r"(?:yy|yyyy|mm|m|dd|d|mon)$",
    re.IGNORECASE,
)
# "the past two days", "last 12 months", "this year", "today", "within".
_RELATIVE_MARKER_RE = re.compile(
    r"\b(today|tonight|tomorrow|yesterday|ago|past|last|next|this|previous"
    r"|prior|following|coming|upcoming|current|recent|present|to date"
    r"|year to date|end of|beginning of|start of|within)\b",
    re.IGNORECASE,
)
# "monthly", "Annual", "bi-weekly", "each month", "per annum".
_FREQUENCY_WORD_RE = re.compile(
    r"\b(?:monthly|annual|annually|quarterly|weekly|daily|hourly|yearly"
    r"|biweekly|bi-weekly|semi-annually|semi-annual|semi-monthly"
    r"|fortnightly|per annum|per month|per year|per quarter|per week"
    r"|each|every|per|recurring|instalments?|installments?)\b",
    re.IGNORECASE,
)
# "5 years", "5 (five) years", "30-day", "5 business days", "five years".
_DURATION_RE = re.compile(
    r"(?:\b\d[\d,]*\s*\)?\s*(?:[- ]\s*)?(?:business |working |calendar )?"
    r"(?:year|month|week|day|hour|minute|second|quarter)s?\b"
    r"|\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
    r"|fifteen|twenty|thirty|forty|fifty|sixty|ninety|a|an)"
    r"\s*(?:\(\s*\d+\s*\))?\s*(?:business |working |calendar )?"
    r"(?:year|month|week|day|hour|minute|second|quarter)s?\b)",
    re.IGNORECASE,
)
# A bare unit or calendar noun still marks a date expression, even with no
# number beside it: "the tax year", "Effective Date", "the fall season".
_CALENDAR_NOUN_RE = re.compile(
    r"\b(?:year|yr|month|week|fortnight|day|date|time|hour|minute|second"
    r"|quarter|anniversary|season|spring|summer|autumn|fall|winter)s?\b",
    re.IGNORECASE,
)
# A bare part of the day names a clock time, not a relative instant.
_TIME_WORD_RE = re.compile(r"^(?:noon|midnight|midday|mid-day)$", re.IGNORECASE)


def date_class(surface: str) -> str:
    """Classify a gold DATE surface into one of :data:`DATE_CLASSES`.

    Shape-driven and deliberately simple; see the section comment for the
    product rule. A surface with no digits and no other marker is relative
    ("the reporting period"), because every calendar-shaped surface carries a
    digit or a month name.
    """
    s = surface.strip()
    if _PLACEHOLDER_DATE_RE.search(s.replace("\\", "")) or _DATE_FORMAT_RE.match(s):
        return "placeholder"
    if _CLOCK_RE.search(s):
        return "absolute"
    if _CALENDAR_DATE_RE.search(s) or _YEAR_RE.search(s):
        return "absolute"
    # A month name beside a number is a written-out calendar date ("this 1st
    # day of January, 2022"), so it outranks a relative marker.
    if _MONTH_WORD_RE.search(s) and any(ch.isdigit() for ch in s):
        return "absolute"
    if _RELATIVE_MARKER_RE.search(s):
        return "relative"
    if _FREQUENCY_WORD_RE.search(s):
        return "frequency"
    if _MONTH_WORD_RE.search(s):
        return "absolute"
    if _DURATION_RE.search(s):
        return "duration"
    if not any(ch.isdigit() for ch in s):
        return "absolute" if _TIME_WORD_RE.match(s) else "relative"
    return "absolute"


def is_nonabsolute_date(surface: str) -> bool:
    """True when the DATE surface names no calendar instant."""
    return date_class(surface) in NON_ABSOLUTE_DATE_CLASSES


def has_temporal_word(surface: str) -> bool:
    """True when the surface holds any word a date can be written with.

    Relative dates ("previous year"), frequencies ("monthly"), durations
    ("a few months ago"), a bare unit or calendar noun ("the tax year",
    "Effective Date"), seasons and times of day all pass. A surface without a
    digit and without such a word ("TBD") is not a date expression,
    which is how the benchmark tells mislabelled gold from a relative date it
    neutralises instead.
    """
    s = surface.strip()
    return bool(
        _MONTH_WORD_RE.search(s) or _TIME_WORD_RE.match(s)
        or _RELATIVE_MARKER_RE.search(s) or _FREQUENCY_WORD_RE.search(s)
        or _DURATION_RE.search(s) or _CALENDAR_NOUN_RE.search(s)
        or _PLACEHOLDER_DATE_RE.search(s.replace("\\", ""))
    )


# --------------------------------------------------------------------------
# Span-JSONL record shape (contract item 2)
# --------------------------------------------------------------------------
# One JSON object per line:
#   {"id": str, "text": str,
#    "spans": [{"start": int, "end": int, "type": "<lowercase type>"}],
#   "source": str,
#    "ignore": [[start, end], ...],
#    "neutral": [[start, end], ...]}
# ``start``/``end`` are Unicode codepoint (Python str index) half-open offsets.
#
# ``ignore`` is optional: absent and ``[]`` both mean "no ignored regions". A
# range marks text whose gold label exists in the source but not in this
# contract (internal ids, usernames, tokens). The training step must not
# label those positions ``O``; it sets them to the ignore index (-100)
# instead. Ignored ranges never overlap a kept span.
#
# ``neutral`` is optional the same way and is an evaluation annotation, not a
# training one: a range the source marks as context-dependent (TAB's QUASI
# mentions) so a detector hit there is neither right nor wrong. The held-out
# scorer ignores unmatched predictions inside such a range. Neutral ranges
# never overlap a kept span.

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
    neutral: list[IgnoreRange] = field(default_factory=list)

    def to_json(self) -> dict:
        obj = {
            "id": self.id,
            "text": self.text,
            "spans": [s.to_json() for s in self.spans],
            "source": self.source,
        }
        if self.ignore:
            obj["ignore"] = [[int(start), int(end)] for start, end in self.ignore]
        if self.neutral:
            obj["neutral"] = [[int(start), int(end)] for start, end in self.neutral]
        return obj

    @staticmethod
    def from_json(obj: dict) -> "Record":
        return Record(
            id=str(obj["id"]),
            text=obj["text"],
            spans=[Span.from_json(s) for s in obj.get("spans", [])],
            source=obj.get("source", ""),
            ignore=[(int(start), int(end)) for start, end in (obj.get("ignore") or [])],
            neutral=[(int(start), int(end)) for start, end in (obj.get("neutral") or [])],
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
    previous_end = -1
    for start, end in sorted(rec.neutral):
        if not (0 <= start < end <= n):
            problems.append(f"neutral range out of range: ({start}, {end})")
            continue
        if start < previous_end:
            problems.append(f"neutral ranges overlap or touch: ({start}, {end})")
        previous_end = end
        hit = next((s for s in rec.spans if start < s.end and s.start < end), None)
        if hit is not None:
            problems.append(f"neutral range ({start}, {end}) overlaps span {hit}")
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
