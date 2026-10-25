"""Seeded synthetic PII generator for the contract types Nemotron covers weakly.

``nvidia/Nemotron-PII`` under-covers several contract types that the ai4privacy
benchmark scores live (organization, title, financial, location, secret,
device_id), and it never mixes them densely in one chat message. This module
adds chat-shaped examples (the runtime's dominant input shape) built from
composable fragments: an opener, three or four body clauses, and a closer.
Openers (:data:`OPENERS`), clauses (:data:`CLAUSES`) and closers
(:data:`CLOSERS`) do not repeat each other, so the number of distinct
templates is ``len(OPENERS) * len(CLOSERS) * P(len(CLAUSES), 3)``: several
hundred thousand at the fragment counts below, far above the 200-template bar.

Design rules, all of them consequences of how the runtime and the held-out
benchmark read spans:

* A span covers the identifier only, never a cue word. The old generator
  emitted ``"account number 000123456789"`` as one financial span, which
  teaches the model to include the cue words; the benchmark gold contains the
  bare value.
* Names are whole names (given + family), like the benchmark gold and the
  runtime's single NAME span.
* Dates are real calendar dates and clock times rendered in several formats.
  No relative dates: "next Friday" has no fixed surface and cannot be scored.
* Street, city, postcode and country stay separate location spans. The
  held-out gold keeps them apart, and one-to-one span scoring punishes a
  merged address.
* Values are drawn from hand-written pools plus a seeded
  :class:`random.Random`, so output is byte-for-byte reproducible per seed.
  Span offsets are recorded while the sentence is built, never by searching
  the value in the text (which breaks on repeated values).
"""

from __future__ import annotations

import random

from pii_contract import Record, Span

# --------------------------------------------------------------------------
# Value pools
# --------------------------------------------------------------------------

GIVEN_NAMES = [
    "Alice", "Marcus", "Priya", "Diego", "Hannah", "Omar", "Yuki", "Grace",
    "Tomás", "Sofia", "Liam", "Noor", "Elena", "Kwame", "Ingrid", "Rahul",
    "Mei", "Alejandro", "Fatima", "Jonas", "Aisha", "Mateo", "Freya", "Kenji",
    "Zara", "Emil", "Camila", "Ibrahim", "Nadia", "Ravi", "Ingrid", "Sean",
    "Anika", "Cormac", "Valeria", "Tobias", "Leila", "Peter", "Sara", "Hugo",
    "Nia", "Anders", "Rosa", "Dmitri", "Amara", "Joaquín", "Sinead", "Bilal",
    "Marta", "Wesley", "Chloé", "Arjun", "Maeve", "Lars", "Daniela", "Tariq",
    "Bridget", "Nikolai", "Esme", "Felipe",
]

FAMILY_NAMES = [
    "Nguyen", "Webb", "Sharma", "Alvarez", "Fischer", "Haddad", "Tanaka",
    "Okafor", "Ferreira", "Rossi", "Kowalski", "Mbeki", "Lindqvist", "Iyer",
    "Chen", "Morales", "El-Sayed", "Berg", "Adeyemi", "Castillo", "Haugen",
    "Watanabe", "Duarte", "Petrov", "Kaur", "Moreau", "Silva", "Novak",
    "Andersson", "O'Connor", "Delacroix", "Yilmaz", "Nakamura", "Bianchi",
    "Oduya", "Klein", "Serrano", "Fitzgerald", "Van Dijk", "Marchetti",
    "Oyelaran", "Suárez", "Larsen", "Rahman", "Vargas", "Keller", "Achebe",
    "Thibault", "Sokolov", "Quinn",
]

ORGS = [
    # Companies
    "Acme Corporation", "Globex Industries", "Initech LLC", "Umbrella Health",
    "Stark Industries", "Wayne Enterprises", "Northwind Traders",
    "Pied Piper Inc", "Hooli", "Vandelay Industries", "Soylent Corp",
    "Cyberdyne Systems", "Massive Dynamic", "Wonka Industries",
    "Dunder Mifflin", "Bluth Company", "Sterling Cooper", "Aperture Science",
    "Tyrell Corporation", "Oscorp", "Gringotts Bank", "Monarch Solutions",
    "Blue Ridge Logistics Ltd", "Cobalt Analytics GmbH", "Harbor Freight Union",
    "Silverline Insurance Group", "Pinnacle Foods Inc", "Redwood Capital Partners",
    "Sable & Finch LLP", "Vertex Biosciences", "Cascade Utilities",
    "Ironwood Manufacturing", "Meridian Shipping Co", "Larkspur Media",
    "Northgate Retail Group", "Fairmont Textiles", "Orion Semiconductors",
    "Thornbury Consulting", "Wexford Pharmaceuticals", "Solstice Energy",
    # Courts, ministries, agencies, departments
    "Superior Court of California", "District Court of Amsterdam",
    "Crown Court of Manchester", "Federal Court of Australia",
    "European Court of Human Rights", "Ministry of Finance",
    "Ministry of Health", "Ministry of Justice", "Department of Transportation",
    "Department of Homeland Security", "Department of Labor",
    "Revenue Agency", "Environmental Protection Agency",
    "National Health Service", "Federal Bureau of Investigation",
    "Securities and Exchange Commission", "Port Authority",
    "City Housing Authority", "Central Statistics Office",
    # Education and health
    "University of Edinburgh", "Trinity College Dublin", "Boston Public Schools",
    "St. Mary's Hospital", "Riverside Medical Center", "Cedar Clinic",
    "Max Planck Institute", "Kepler Research Laboratory",
    # Banks
    "First National Bank", "Cooperative Bank of Norway", "Banco Santander",
    "Toronto Dominion Bank", "Kingsway Building Society",
]

TITLES = [
    "Senior Software Engineer", "Product Manager", "Chief Financial Officer",
    "Data Scientist", "Registered Nurse", "Account Executive",
    "Director of Operations", "Legal Counsel", "Systems Administrator",
    "Head of Marketing", "Principal Architect", "Compliance Analyst",
    "Staff Accountant", "VP of Engineering", "Customer Success Lead",
    "Security Researcher", "Clinical Coordinator", "Payroll Specialist",
    "Court Clerk", "Court Reporter", "Police Officer", "Paralegal",
    "Tax Inspector", "Claims Adjuster", "Warehouse Supervisor",
    "Logistics Coordinator", "Financial Controller", "Research Fellow",
    "Teaching Assistant", "Site Foreman", "HR Business Partner",
    "Network Engineer", "Quality Assurance Lead", "Lab Technician",
    "Branch Manager", "Loan Officer", "Underwriter", "Auditor",
    "Mechanical Engineer", "Purchasing Agent", "Dispatcher",
    "Office Manager", "Records Clerk", "Social Worker", "Pharmacist",
]

CITIES = [
    "Portland", "Austin", "Denver", "Seattle", "Boston", "Chicago",
    "Atlanta", "Phoenix", "Toronto", "Dublin", "Manchester", "Rotterdam",
    "Bristol", "Oslo", "Lisbon", "Melbourne", "Vancouver", "Cork",
    "Glasgow", "Leeds", "Hamburg", "Lyon", "Milan", "Barcelona", "Utrecht",
    "Bergen", "Auckland", "Cape Town", "Nairobi", "Mumbai", "Singapore",
    "Seoul", "Osaka", "Bogotá", "Lima", "Montevideo", "Warsaw", "Prague",
    "Vienna", "Zurich", "Brussels", "Copenhagen", "Helsinki", "Tallinn",
    "Bratislava", "Ljubljana", "Athens", "Valencia", "Porto", "Belfast",
]

STREETS = [
    "42 Maple Street", "1187 Elm Avenue", "9 Birch Lane", "230 Oak Drive",
    "77 Cedar Court", "15 Harbor Road", "560 Sunset Boulevard",
    "3 Kingsway", "204 High Street", "88 Riverside Walk",
    "31 Chestnut Close", "908 Franklin Street", "12 Princes Street",
    "455 Lakeshore Drive", "6 Vicarage Road", "271 Union Avenue",
    "19 Mill Lane", "1442 Peachtree Road", "58 Quay Parade",
    "305 Willow Bend", "7 Station Approach", "820 Canyon Vista",
    "63 Orchard Way", "90 Beacon Hill", "410 Industrial Parkway",
    "24 Rosewood Terrace", "1166 Madison Avenue", "5 Kirkgate",
    "72 Sandpiper Circle", "333 Grand Canal Street", "18 Fisherman's Row",
    "611 Aspen Trail", "44 Wellington Square", "205 Dockside Road",
    "9 Heathfield Gardens", "1340 Sunset Strip", "27 Chapel Street",
    "86 Marigold Crescent", "740 Lakeside Court", "52 Beacon Street",
]

POSTCODES = [
    "97205", "78701", "80202", "98101", "02108", "60601", "30303", "85004",
    "M5V 2T6", "K1A 0B1", "D02 X285", "M1 4BT", "1012 AB", "0150 Oslo",
    "1000-001", "2000", "SW1A 1AA", "EH1 1YZ", "HX1 2QT", "BS1 5TR",
    "3000", "8001", "10115", "75001", "20121", "08001", "3512 JE",
]

COUNTRIES = [
    "United States", "Canada", "Ireland", "Netherlands", "Norway", "Portugal",
    "United Kingdom", "Germany", "France", "Italy", "Spain", "Sweden",
    "Denmark", "Finland", "Poland", "Czechia", "Austria", "Switzerland",
    "Belgium", "Australia", "New Zealand", "South Africa", "Kenya", "India",
    "Singapore", "South Korea", "Japan", "Brazil", "Mexico", "Argentina",
]

AGES = [str(a) for a in range(19, 84, 3)]

MONTHS = [
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
]

EMAIL_DOMAINS = [
    "example.com", "mail.example.org", "corpmail.net", "fastmail.example",
    "proton.example", "webmail.example.co.uk",
]

URL_PATHS = [
    "https://example.com/invoices/1842",
    "https://portal.example.org/account/settings?tab=billing",
    "http://intranet.example.net/hr/policies/leave",
    "https://www.example.co.uk/support/tickets/99120",
    "https://files.example.com/share/9f2c1a",
    "https://shop.example.net/orders/58421/status",
    "https://status.example.org/incidents/2024-11",
]

CARD_PREFIXES = ["4111", "4242", "5500", "5200", "3782", "6011", "3530"]

IBAN_COUNTRIES = ["GB", "DE", "FR", "NL", "IE", "NO", "PT", "ES", "BE", "AT"]

SWIFT_BANKS = ["NWBK", "CHAS", "DEUT", "ABNA", "BNPA", "DNBA", "SRGT", "RABO"]


# --------------------------------------------------------------------------
# Seeded value builders
# --------------------------------------------------------------------------


def _digits(rng: random.Random, n: int, first_nonzero: bool = False) -> str:
    out = "".join(str(rng.randrange(10)) for _ in range(n))
    if first_nonzero and out[0] == "0":
        out = str(rng.randrange(1, 10)) + out[1:]
    return out


def _letters(rng: random.Random, n: int) -> str:
    return "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(n))


def _person_name(rng: random.Random) -> str:
    given = rng.choice(GIVEN_NAMES)
    family = rng.choice(FAMILY_NAMES)
    shape = rng.random()
    if shape < 0.15:
        return f"{given} {rng.choice('ABCDEFGHJKLMNPRSTW')}. {family}"
    if shape < 0.30:
        return f"{given} {rng.choice(FAMILY_NAMES)} {family}"
    return f"{given} {family}"


def _date(rng: random.Random) -> str:
    """A real calendar date (1970-2030) in one of several formats."""
    import datetime

    day = datetime.date(1970, 1, 1) + datetime.timedelta(days=rng.randrange(0, 22_000))
    shape = rng.random()
    if shape < 0.35:
        return day.isoformat()
    if shape < 0.6:
        return f"{day.day} {MONTHS[day.month - 1]} {day.year}"
    if shape < 0.85:
        return f"{MONTHS[day.month - 1]} {day.day}, {day.year}"
    return f"{day.month:02d}/{day.day:02d}/{day.year}"


def _time(rng: random.Random) -> str:
    hour, minute = rng.randrange(0, 24), rng.randrange(0, 60)
    if rng.random() < 0.5:
        return f"{hour:02d}:{minute:02d}"
    suffix = "AM" if hour < 12 else "PM"
    return f"{hour % 12 or 12}:{minute:02d} {suffix}"


def _financial(rng: random.Random) -> str:
    """An identifier value only: card, IBAN, account, routing or SWIFT."""
    shape = rng.random()
    if shape < 0.30:
        groups = [_digits(rng, 4) for _ in range(3)]
        return f"{rng.choice(CARD_PREFIXES)} {' '.join(groups)}"
    if shape < 0.50:
        country = rng.choice(IBAN_COUNTRIES)
        tail = " ".join(_digits(rng, 4) for _ in range(4))
        return f"{country}{_digits(rng, 2, first_nonzero=True)} {rng.choice(SWIFT_BANKS)} {tail}"
    if shape < 0.70:
        return " ".join([_digits(rng, 4, first_nonzero=True)] + [_digits(rng, 4) for _ in range(2)])
    if shape < 0.85:
        return _digits(rng, 9, first_nonzero=True)
    return f"{rng.choice(SWIFT_BANKS)}{_letters(rng, 2)}{_digits(rng, 3)}XXX"


def _phone(rng: random.Random) -> str:
    shape = rng.random()
    if shape < 0.4:
        return f"+1 {rng.randrange(201, 989)} {rng.randrange(200, 999)} {_digits(rng, 4)}"
    if shape < 0.65:
        return f"({rng.randrange(201, 989)}) {rng.randrange(200, 999)}-{_digits(rng, 4)}"
    if shape < 0.8:
        return f"+44 20 {rng.randrange(3000, 8999)} {_digits(rng, 4)}"
    return f"+{rng.randrange(31, 99)} {rng.randrange(10, 99)} {rng.randrange(1000, 9999)} {_digits(rng, 4)}"


def _email(rng: random.Random) -> str:
    local = rng.choice(GIVEN_NAMES).lower().replace("á", "a").replace("é", "e")
    local += rng.choice([".", "_", ""]) + rng.choice(FAMILY_NAMES).lower().replace("'", "")
    return f"{local}{_digits(rng, 2)}@{rng.choice(EMAIL_DOMAINS)}"


def _ssn(rng: random.Random) -> str:
    area = rng.choice([n for n in range(101, 899) if n != 666])
    return f"{area:03d}-{rng.randrange(10, 99):02d}-{rng.randrange(1000, 9999)}"


def _national_id(rng: random.Random) -> str:
    shape = rng.random()
    if shape < 0.5:
        return f"{_letters(rng, 1)}{_digits(rng, 7, first_nonzero=True)}"
    return f"{_digits(rng, 2, first_nonzero=True)}-{_digits(rng, 7)}"


def _passport(rng: random.Random) -> str:
    return f"{_letters(rng, 1)}{_digits(rng, 8, first_nonzero=True)}"


def _medical_id(rng: random.Random) -> str:
    shape = rng.random()
    if shape < 0.5:
        return f"MRN-{_digits(rng, 6, first_nonzero=True)}"
    return f"{_letters(rng, 2)}{_digits(rng, 8, first_nonzero=True)}"


def _hex(rng: random.Random, n: int) -> str:
    return "".join(rng.choice("0123456789ABCDEF") for _ in range(n))


def _device_id(rng: random.Random) -> str:
    shape = rng.random()
    if shape < 0.3:
        return _digits(rng, 15, first_nonzero=True)  # IMEI
    if shape < 0.6:
        return ":".join(_hex(rng, 2) for _ in range(6))  # MAC
    if shape < 0.85:
        # VIN: 17 characters, I/O/Q are not used in VINs.
        alphabet = "0123456789ABCDEFGHJKLMNPRSTUVWXYZ"
        return "".join(rng.choice(alphabet) for _ in range(17))
    return f"{_letters(rng, 3)}-{_digits(rng, 4)}"  # plate


def _secret(rng: random.Random) -> str:
    shape = rng.random()
    if shape < 0.35:
        return "".join(rng.choice("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%") for _ in range(12))
    if shape < 0.55:
        return _digits(rng, 4, first_nonzero=True)
    if shape < 0.75:
        return _digits(rng, 3, first_nonzero=True)
    if shape < 0.9:
        return f"AKIA{rng.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}{_letters(rng, 4)}{_digits(rng, 8)}"
    return f"sk_live_{_letters(rng, 6).lower()}{_digits(rng, 10)}"


def _ip(rng: random.Random) -> str:
    if rng.random() < 0.75:
        return ".".join(str(rng.randrange(1, 255)) for _ in range(4))
    return ":".join(_digits(rng, 4) for _ in range(4)) + "::" + _digits(rng, 4)


def _coordinate(rng: random.Random) -> str:
    lat = rng.uniform(-60, 70)
    lon = rng.uniform(-170, 170)
    return f"{lat:.4f}, {lon:.4f}"


def _value_for(kind: str, rng: random.Random) -> tuple[str, str | None]:
    """Return ``(surface_text, contract_type_or_None)`` for a slot kind."""
    if kind == "name":
        return _person_name(rng), "name"
    if kind == "org":
        return rng.choice(ORGS), "organization"
    if kind == "title":
        return rng.choice(TITLES), "title"
    if kind == "city":
        return rng.choice(CITIES), "location"
    if kind == "street":
        return rng.choice(STREETS), "location"
    if kind == "postcode":
        return rng.choice(POSTCODES), "location"
    if kind == "country":
        return rng.choice(COUNTRIES), "location"
    if kind == "coordinate":
        return _coordinate(rng), "location"
    if kind == "age":
        return rng.choice(AGES), "age"
    if kind == "date":
        return _date(rng), "date"
    if kind == "time":
        return _time(rng), "date"
    if kind == "fin":
        return _financial(rng), "financial"
    if kind == "phone":
        return _phone(rng), "phone"
    if kind == "email":
        return _email(rng), "email"
    if kind == "url":
        return rng.choice(URL_PATHS), "url"
    if kind == "ip":
        return _ip(rng), "ip_address"
    if kind == "ssn":
        return _ssn(rng), "ssn"
    if kind == "national_id":
        return _national_id(rng), "national_id"
    if kind == "passport":
        return _passport(rng), "passport"
    if kind == "medical_id":
        return _medical_id(rng), "medical_id"
    if kind == "device_id":
        return _device_id(rng), "device_id"
    if kind == "secret":
        return _secret(rng), "secret"
    raise ValueError(f"unknown slot kind {kind!r}")


# --------------------------------------------------------------------------
# Composable fragments: (text with {} slots, slot kinds in order)
# --------------------------------------------------------------------------

OPENERS: list[tuple[str, list[str]]] = [
    ("Quick one:", []),
    ("Hi team,", []),
    ("Hey,", []),
    ("Hello,", []),
    ("Good morning,", []),
    ("Morning all,", []),
    ("Thanks for the call earlier.", []),
    ("Following up on our conversation.", []),
    ("Sorry for the slow reply.", []),
    ("This is {} from the payments desk.", ["name"]),
    ("I'm {}, writing about my account.", ["name"]),
    ("My name is {} and I need some help.", ["name"]),
    ("Please update the record for {}.", ["name"]),
    ("Forwarding a note from {}.", ["name"]),
    ("Case notes from the intake desk:", []),
    ("Per your request, here are the details:", []),
    ("Re: your recent ticket.", []),
    ("One more thing before I forget.", []),
]

CLAUSES: list[tuple[str, list[str]]] = [
    ("I work at {org}.", ["org"]),
    ("I joined {org} in {} and I'm still there.", ["org", "date"]),
    ("My employer is {org} and my manager is {}.", ["org", "name"]),
    ("I'm the {title} at {org}.", ["title", "org"]),
    ("They made me {title} last {}.", ["title", "date"]),
    ("My role is {title}.", ["title"]),
    ("I'm {age} years old.", ["age"]),
    ("My date of birth is {}.", ["date"]),
    ("The appointment is on {} at {}.", ["date", "time"]),
    ("I moved here on {}.", ["date"]),
    ("We can meet at {} on {}.", ["time", "date"]),
    ("The contract was signed on {}.", ["date"]),
    ("My new address is {}, {}.", ["street", "city"]),
    ("I live on {}.", ["street"]),
    ("I'm based in {}.", ["city"]),
    ("The office is in {}.", ["city"]),
    ("The invoice should go to {} {}.", ["street", "postcode"]),
    ("I'm relocating to {} in {}.", ["country", "date"]),
    ("The shipment went to {}.", ["country"]),
    ("The site coordinates are {}.", ["coordinate"]),
    ("My mobile is {} if you need to call.", ["phone"]),
    ("Reach me on {} any weekday.", ["phone"]),
    ("You can email me at {}.", ["email"]),
    ("Send the confirmation to {}.", ["email"]),
    ("The portal is at {}.", ["url"]),
    ("The document is uploaded to {}.", ["url"]),
    ("The account is {}.", ["fin"]),
    ("Please use card {} instead.", ["fin"]),
    ("The wire went out from {}.", ["fin"]),
    ("The payment reference is {}.", ["fin"]),
    ("My social security number is {}.", ["ssn"]),
    ("They asked for my licence, {}.", ["national_id"]),
    ("My tax reference is {}.", ["national_id"]),
    ("My passport number is {}.", ["passport"]),
    ("The hospital records are under {}.", ["medical_id"]),
    ("My patient reference is {}.", ["medical_id"]),
    ("The phone's IMEI is {}.", ["device_id"]),
    ("The MAC address is {}.", ["device_id"]),
    ("The van's plate is {}.", ["device_id"]),
    ("The login is {} and the password is {}.", ["email", "secret"]),
    ("The PIN is {} and should not be shared.", ["secret"]),
    ("I had to reset my password to {}.", ["secret"]),
    ("The key on the server is {}.", ["secret"]),
    ("Our subnet is {} and the gateway is on the same range.", ["ip"]),
    ("The server address is {}.", ["ip"]),
    ("The director is {} and the deputy is {}.", ["name", "name"]),
    ("My colleague {} can sign off.", ["name"]),
    ("Ask for {} at reception.", ["name"]),
]

CLOSERS: list[tuple[str, list[str]]] = [
    ("Thanks.", []),
    ("Thanks in advance.", []),
    ("Let me know if you need anything else.", []),
    ("Please confirm when it's done.", []),
    ("I appreciate the help.", []),
    ("Sorry for the hassle.", []),
    ("Cheers, {}", ["name"]),
    ("Best regards, {}", ["name"]),
    ("Please treat this as confidential.", []),
    ("Call me if the details don't match.", []),
    ("I can send documents if needed.", []),
    ("Keep me posted.", []),
    ("No rush, but please reply today.", []),
]


def _positional(fragment: str) -> str:
    """Turn named slots (``{org}``) into positional ones (``{}``)."""
    import re

    return re.sub(r"\{[a-z_]+\}", "{}", fragment)


def _compose(rng: random.Random) -> tuple[str, list[str]]:
    """Pick an opener, 3-4 clauses and a closer; return the template + kinds.

    Fragments spell their slots out by name (``{org}``, ``{title}``) so the
    pools stay readable; the renderer only understands positional ``{}``, so
    every named slot is normalised to ``{}`` here. The kinds list follows the
    same left-to-right order.
    """
    n_clauses = rng.choice([3, 3, 3, 4, 4])
    picked = [rng.choice(OPENERS)]
    picked += rng.sample(CLAUSES, n_clauses)
    picked.append(rng.choice(CLOSERS))
    template = " ".join(_positional(part[0]) for part in picked)
    kinds = [kind for part in picked for kind in part[1]]
    return template, kinds


def template_variants() -> int:
    """Number of distinct opener/clause-set/closer combinations available."""
    n = len(CLAUSES)
    per_size = n * (n - 1) * (n - 2)
    return len(OPENERS) * len(CLOSERS) * per_size


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


def _render(template: str, kinds: list[str], rng: random.Random) -> tuple[str, list[Span]]:
    """Fill a template, recording codepoint span offsets as we append."""
    text = ""
    spans: list[Span] = []
    pieces = template.split("{}")
    if len(pieces) != len(kinds) + 1:
        raise ValueError(f"template/kinds mismatch: {template!r} {kinds!r}")
    for index, piece in enumerate(pieces):
        text += piece
        if index == len(kinds):
            break
        surface, ctype = _value_for(kinds[index], rng)
        start = len(text)
        text += surface
        if ctype is not None:
            spans.append(Span(start, len(text), ctype))
    return text, spans


def generate(count: int, seed: int, id_prefix: str = "synth") -> list[Record]:
    """Generate ``count`` seeded synthetic records."""
    rng = random.Random(seed)
    records: list[Record] = []
    for i in range(count):
        template, kinds = _compose(rng)
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
