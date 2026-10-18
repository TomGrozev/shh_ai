"""Seeded synthetic PII generator for the *weak* contract types.

``nvidia/Nemotron-PII`` under-covers a handful of contract types, and the
ai4privacy benchmark scores them live. This generator adds chat-shaped
examples (the runtime's dominant input shape) rich in:

    organization, financial, location, title, date

plus a little ``name``/``age`` context so the sentences read naturally. Every
value is drawn from a hand-written pool with :class:`random.Random` seeded by
the caller, so the output is byte-for-byte reproducible for a given seed.

The generator returns :class:`pii_contract.Record` objects with real
codepoint span offsets, computed by building each sentence piece by piece
(never by searching for the value in the text, which would break on repeated
values).
"""

from __future__ import annotations

import random

from pii_contract import Record, Span

# --------------------------------------------------------------------------
# Value pools
# --------------------------------------------------------------------------

ORGS = [
    "Acme Corporation", "Globex Industries", "Initech LLC", "Umbrella Health",
    "Stark Industries", "Wayne Enterprises", "Northwind Traders",
    "Pied Piper Inc", "Hooli", "Vandelay Industries", "Soylent Corp",
    "Cyberdyne Systems", "Massive Dynamic", "Wonka Industries",
    "Dunder Mifflin", "Bluth Company", "Sterling Cooper", "Aperture Science",
    "Tyrell Corporation", "Oscorp", "Gringotts Bank", "Monarch Solutions",
]

TITLES = [
    "Senior Software Engineer", "Product Manager", "Chief Financial Officer",
    "Data Scientist", "Registered Nurse", "Account Executive",
    "Director of Operations", "Legal Counsel", "Systems Administrator",
    "Head of Marketing", "Principal Architect", "Compliance Analyst",
    "Staff Accountant", "VP of Engineering", "Customer Success Lead",
    "Security Researcher", "Clinical Coordinator", "Payroll Specialist",
]

CITIES = [
    "Portland", "Austin", "Denver", "Seattle", "Boston", "Chicago",
    "Atlanta", "Phoenix", "Toronto", "Dublin", "Manchester", "Rotterdam",
    "Bristol", "Oslo", "Lisbon", "Melbourne",
]

STREETS = [
    "42 Maple Street", "1187 Elm Avenue", "9 Birch Lane", "230 Oak Drive",
    "77 Cedar Court", "15 Harbor Road", "560 Sunset Boulevard",
    "3 Kingsway", "204 High Street", "88 Riverside Walk",
]

COUNTRIES = ["United States", "Canada", "Ireland", "Netherlands", "Norway", "Portugal"]

# (template, contract type). Financial identifiers get several shapes so the
# model does not overfit a single format.
FINANCIAL = [
    ("IBAN {v}", "GB29 NWBK 6016 1331 9268 19"),
    ("IBAN {v}", "DE89 3704 0044 0532 0130 00"),
    ("account number {v}", "000123456789"),
    ("account number {v}", "4097 2210 8834"),
    ("routing number {v}", "021000021"),
    ("SWIFT/BIC {v}", "CHASUS33XXX"),
    ("card ending {v}", "4242"),
    ("credit card {v}", "4111 1111 1111 1111"),
]

DATES = [
    "2023-04-17", "January 5, 2022", "next Friday", "12/03/2024",
    "March 2021", "Q3 2023", "the 15th of June", "2024-11-02",
]

NAMES = [
    "Alice Nguyen", "Marcus Webb", "Priya Sharma", "Diego Alvarez",
    "Hannah Fischer", "Omar Haddad", "Yuki Tanaka", "Grace Okafor",
    "Tomás Ferreira", "Sofia Rossi",
]

AGES = ["34", "28", "45", "61", "23", "52", "39"]

# Chat-shaped templates. ``{n}`` placeholders are filled positionally by the
# renderer, which records the span offsets as it goes.
TEMPLATES: list[tuple[str, list[str]]] = [
    (
        "hey can you update my file? i just moved to {loc}, my new employer is {org}, "
        "and my role there is {title}. thanks!",
        ["loc", "org", "title"],
    ),
    (
        "Hi, this is {name} from {org}. My title is {title} and I'm based in {loc}. "
        "Can you send the invoice to my account {fin}?",
        ["name", "org", "title", "loc", "fin"],
    ),
    (
        "quick one - my {fin} needs updating and the billing address is {loc}. "
        "i work at {org} now.",
        ["fin", "loc", "org"],
    ),
    (
        "Following up on my application: I'm {name}, {age} years old, currently at {org} "
        "as a {title}, living at {loc}.",
        ["name", "age", "org", "title", "loc"],
    ),
    (
        "please note the payment for {org} is due {date} and should come from {fin}.",
        ["org", "date", "fin"],
    ),
    (
        "I joined {org} last {date}. I'm the {title} for the {loc} region.",
        ["org", "date", "title", "loc"],
    ),
    (
        "my card {fin} expired and my address changed to {loc} on {date}.",
        ["fin", "loc", "date"],
    ),
    (
        "is {org} still hiring for the {title} role in {loc}? asking for {name}.",
        ["org", "title", "loc", "name"],
    ),
    (
        "Update my profile: name {name}, age {age}, employer {org}, title {title}, "
        "city {loc}.",
        ["name", "age", "org", "title", "loc"],
    ),
    (
        "The {title} at {org} in {loc} sent the wire to {fin} on {date}.",
        ["title", "org", "loc", "fin", "date"],
    ),
]


def _value_for(kind: str, rng: random.Random) -> tuple[str, str | None]:
    """Return ``(surface_text, contract_type_or_None)`` for a slot kind."""
    if kind == "org":
        return rng.choice(ORGS), "organization"
    if kind == "title":
        return rng.choice(TITLES), "title"
    if kind == "name":
        return rng.choice(NAMES), "name"
    if kind == "age":
        return rng.choice(AGES), "age"
    if kind == "date":
        return rng.choice(DATES), "date"
    if kind == "fin":
        template, value = rng.choice(FINANCIAL)
        return template.format(v=value), "financial"
    if kind == "loc":
        # Mix of city / street / country so location is not one shape.
        choice = rng.random()
        if choice < 0.5:
            return rng.choice(CITIES), "location"
        if choice < 0.8:
            return rng.choice(STREETS), "location"
        return rng.choice(COUNTRIES), "location"
    raise ValueError(f"unknown slot kind {kind!r}")


def _render(template: str, kinds: list[str], rng: random.Random) -> tuple[str, list[Span]]:
    """Fill a template, recording codepoint span offsets as we append."""
    text = ""
    spans: list[Span] = []
    remaining = template
    kinds_iter = iter(kinds)
    while "{" in remaining:
        head, rest = remaining.split("{", 1)
        slot, remaining = rest.split("}", 1)
        text += head
        kind = next(kinds_iter)
        surface, ctype = _value_for(kind, rng)
        start = len(text)
        text += surface
        if ctype is not None:
            spans.append(Span(start, len(text), ctype))
    text += remaining
    return text, spans


def generate(count: int, seed: int, id_prefix: str = "synth") -> list[Record]:
    """Generate ``count`` seeded synthetic records."""
    rng = random.Random(seed)
    records: list[Record] = []
    for i in range(count):
        template, kinds = rng.choice(TEMPLATES)
        text, spans = _render(template, kinds, rng)
        records.append(
            Record(
                id=f"{id_prefix}-{seed}-{i}",
                text=text,
                spans=spans,
                source="synthetic",
            )
        )
    return records
