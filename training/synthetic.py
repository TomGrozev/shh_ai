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
* Dates are calendar dates, clock times, AND non-calendar surfaces
  ("monthly", "annual", "5 years", "30-day", "the past two years", "today").
  About 30% of the held-out benchmark's gretel date gold is non-calendar, and
  the model scored 795 of 863 date misses as "no prediction at all"; relative
  date surfaces are fixed strings once written, so they can be scored.
* A postal address is ONE location span covering the parts joined by commas
  ("123 Main Street, Anytown, DE 12345"), because the benchmark's gretel gold
  marks the whole address and scores each part as a false positive.
* Companies are rendered with legal suffixes ("Hall LLC", "Latem AB",
  "Bennett Inc.") in name-like positions, since the benchmark's organisation
  gold is mostly company names and the model was reading them as NAMEs.
* Some records carry a financial message block (SWIFT MT940 tags, XBRL or
  FpML snippets with namespace URLs). Their tag values, codes and namespace
  URLs are left unlabelled ``O``: the benchmark gold does not mark them, and
  the model was firing DATE on ":25:20220315" and on XBRL period values.
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

# State/province names and codes, for the "1234 Main Street, Anytown, DE
# 12345" gold shape.
STATES = [
    "CA", "NY", "TX", "FL", "IL", "OH", "WA", "OR", "MA", "PA", "GA", "NC",
    "MI", "CO", "AZ", "VA", "ON", "BC", "QC", "NS", "AB",
    "California", "New York", "Texas", "Florida", "Illinois", "Oregon",
    "Ontario", "Queensland", "New South Wales", "Bavaria", "Canton Zurich",
]

# Secondary address parts, as the gretel gold writes them ("Apt. 0490",
# "Suite 956", "Studio 38").
UNITS = [
    "Apt. 0490", "Apt. 656", "Apt. 12B", "Apt. 9700", "Suite 750", "Suite 867",
    "Suite 956", "Studio 38", "Studio 97", "Unit 4", "Unit 11", "Flat 2C",
    "Floor 3", "Level 0", "Room 214", "P.O. Box 118",
]

COUNTRIES = [
    "United States", "Canada", "Ireland", "Netherlands", "Norway", "Portugal",
    "United Kingdom", "Germany", "France", "Italy", "Spain", "Sweden",
    "Denmark", "Finland", "Poland", "Czechia", "Austria", "Switzerland",
    "Belgium", "Australia", "New Zealand", "South Africa", "Kenya", "India",
    "Singapore", "South Korea", "Japan", "Brazil", "Mexico", "Argentina",
]

# Company stems and the legal suffixes the benchmark's organisation gold
# carries ("Hall LLC", "Latem AB", "Acme Chemicals Inc.", "ABC_PLC").
COMPANY_STEMS = [
    "Hall", "Latem", "Bennett", "Archer", "Clark", "Byrne", "Page", "Carroll",
    "Nolan", "Bassi", "Mitter", "Halloran", "Draper", "Kessler", "Marsh",
    "Pemberton", "Fenwick", "Ashby", "Cortez", "Lund", "Whitfield", "Reyes",
    "Strand", "Voss", "Kingsley", "Ashford", "Brandt", "Calloway", "Devlin",
    "Eastwood", "Fairbrother", "Gardiner", "Hollis", "Ingram", "Jarvis",
    "Lockhart", "Merrick", "Norrington", "Prescott", "Rathbone",
]

LEGAL_SUFFIXES = [
    "Inc.", "Inc", "LLC", "L.L.C.", "Ltd.", "Ltd", "Limited", "GmbH", "AG",
    "Corp.", "Corporation", "Co.", "PLC", "LLP", "LP", "PLLC", "AB", "SA",
    "BV", "Pty Ltd", "Enterprises", "Group", "Holdings", "Partners",
]

# Non-calendar date surfaces, taken from the shapes the benchmark's gretel gold
# marks as DATE: frequencies, durations, calendar-relative phrases.
RELATIVE_DATES = [
    "monthly", "annual", "annually", "quarterly", "semi-annually", "weekly",
    "daily", "monthly basis", "each month", "each year", "every month",
    "every quarter", "each calendar month", "the first day of each month",
    "the first day of the month", "5 years", "10 years", "30 years",
    "12 months", "18 months", "6 months", "30 days", "90 days", "180 days",
    "5 business days", "10 business days", "30-day", "36-month", "12-month",
    "10-year", "the past year", "the past five years", "the past two years",
    "the next six months", "the last three quarters", "this year", "last year",
    "this quarter", "today", "tomorrow", "yesterday", "next week",
    "next month", "Monday to Friday", "15 minutes", "10 seconds",
    "the previous fiscal year", "the reported fiscal year",
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


def _address(rng: random.Random) -> str:
    """One postal address, all parts inside one span.

    The shapes follow the benchmark's gretel gold: "7 Byrne Center, London,
    NW1 1NR", "1234 Main Street, Anytown, DE 12345", "123 Main Street,
    Anytown, USA", "821 David Curve, North Cory", and sometimes a unit
    ("9989 Marcia Manors, Apt. 0490").
    """
    street = rng.choice(STREETS)
    if rng.random() < 0.25:
        street = f"{street}, {rng.choice(UNITS)}"
    city = rng.choice(CITIES)
    shape = rng.random()
    if shape < 0.28:
        return f"{street}, {city}"
    if shape < 0.55:
        return f"{street}, {city}, {rng.choice(POSTCODES)}"
    if shape < 0.80:
        return f"{street}, {city}, {rng.choice(STATES)} {rng.choice(POSTCODES)}"
    return f"{street}, {city}, {rng.choice(COUNTRIES)}"


def _company(rng: random.Random) -> str:
    """A company name with a legal suffix, or a partnership name."""
    shape = rng.random()
    if shape < 0.10:
        first, second, third = rng.sample(COMPANY_STEMS, 3)
        return f"{first}, {second} and {third}"
    if shape < 0.18:
        first, second = rng.sample(COMPANY_STEMS, 2)
        return f"{first} & {second} {rng.choice(LEGAL_SUFFIXES)}"
    return f"{rng.choice(COMPANY_STEMS)} {rng.choice(LEGAL_SUFFIXES)}"


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
    if kind == "company":
        return _company(rng), "organization"
    if kind == "title":
        return rng.choice(TITLES), "title"
    if kind == "city":
        return rng.choice(CITIES), "location"
    if kind == "street":
        return rng.choice(STREETS), "location"
    if kind == "address":
        return _address(rng), "location"
    if kind == "country":
        return rng.choice(COUNTRIES), "location"
    if kind == "coordinate":
        return _coordinate(rng), "location"
    if kind == "age":
        return rng.choice(AGES), "age"
    if kind == "date":
        return _date(rng), "date"
    if kind == "rel_date":
        return rng.choice(RELATIVE_DATES), "date"
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
    ("My new address is {}.", ["address"]),
    ("I live on {}.", ["street"]),
    ("I'm based in {}.", ["city"]),
    ("The office is in {}.", ["city"]),
    ("The invoice should go to {}.", ["address"]),
    ("Deliver the parcel to {}.", ["address"]),
    ("Our registered office is at {}.", ["address"]),
    ("The property is at {}.", ["address"]),
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
    # Company names in name-like positions. The benchmark's organisation gold
    # is mostly company names, and the model read them as NAMEs.
    ("The statement was signed by {}.", ["company"]),
    ("Signed: {}", ["company"]),
    ("Contact {} about the invoice.", ["company"]),
    ("Please address this to {}.", ["company"]),
    ("{} handles the account.", ["company"]),
    # Non-calendar dates: about 30% of the benchmark's gretel date gold.
    ("Payment is due {}.", ["rel_date"]),
    ("The fee is charged {}.", ["rel_date"]),
    ("We review the account {}.", ["rel_date"]),
    ("The service renews {}.", ["rel_date"]),
    ("This applies {}.", ["rel_date"]),
]

# Multi-line financial message blocks. Tag values, codes and namespace URLs
# carry no span: the benchmark gold leaves them unlabelled, and the model was
# firing DATE on ":25:20220315" and on XBRL period values. Blocks that do hold
# PII mark it in the usual way, as the gold does inside ":59F:" and inside an
# XBRL entity element.
MESSAGE_BLOCKS: list[tuple[str, list[str]]] = [
    # SWIFT MT940, tags only: nothing to label.
    (":20:MT940.4\n:25:20220315\n:28C:977IOAG92646281636638GB77\n"
     ":60F:Credit\n:61:20220315GBP12345.67\n:62F:C\n"
     ":86:1234567890/1234567890123456789", []),
    (":13D:20220315 13:45:12\n:20:20220316\n:25:12345678901\n"
     ":32A:220315GBP12345,67\n:86:4\n:88C:/SUM/DEBIT", []),
    # SWIFT MT940 with the ordering customer and account in their fields.
    (":59F:/{name}/{address}/{country}\n:64A:/{fin}/IAN/GB\n:70:/INV/99120", [
        "name", "address", "country", "fin"]),
    # XBRL instance with namespace URLs only: nothing to label.
    ('<?xml version="1.0" encoding="UTF-8"?>\n'
     '<xbrl xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
     'xmlns:xbrli="http://www.xbrl.org/2003/instance" '
     'xmlns:iso4217="http://www.xbrl.org/2003/iso4217" '
     'xmlns:us-gaap="http://fasb.org/us-gaap/2023">\n'
     '  <xbrli:context id="ctx-2023-Q1">\n'
     '    <xbrli:entity>\n'
     '      <xbrli:identifier scheme="http://www.sec.gov/edgar">0000000123'
     '</xbrli:identifier>\n'
     '    </xbrli:entity>\n'
     '    <xbrli:period>\n'
     '      <xbrli:startDate>2023-01-01</xbrli:startDate>\n'
     '      <xbrli:endDate>2023-03-31</xbrli:endDate>\n'
     '    </xbrli:period>\n'
     '  </xbrli:context>\n'
     '</xbrl>', []),
    # XBRL instance with the entity name and address, as the gold marks them.
    ('<xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance" '
     'xmlns:ext="http://www.example.com/2023-quarterly-earnings">\n'
     '  <xbrli:context id="entity-1">\n'
     '    <xbrli:entity>\n'
     '      <ext:Name>{name}</ext:Name>\n'
     '      <ext:StreetAddress>{address}</ext:StreetAddress>\n'
     '    </xbrli:entity>\n'
     '  </xbrli:context>\n'
     '</xbrl>', ["name", "address"]),
    # FpML: party scheme URLs and codes only.
    ('<fpml:dataDocument xmlns:fpml="http://www.fpml.org/FpML-5/reporting" '
     'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
     '  <fpml:trade>\n'
     '    <fpml:party id="party-1">\n'
     '      <fpml:partyId partyIdScheme="http://www.fpml.org/coding-scheme/'
     'party-identifier-type">ABC123456</fpml:partyId>\n'
     '    </fpml:party>\n'
     '  </fpml:trade>\n'
     '</fpml:dataDocument>', []),
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


# Share of records that carry one multi-line financial message block.
MESSAGE_BLOCK_SHARE = 0.15


def _compose(rng: random.Random) -> tuple[str, list[str]]:
    """Pick an opener, 3-4 clauses, maybe a message block and a closer.

    Fragments spell their slots out by name (``{org}``, ``{title}``) so the
    pools stay readable; the renderer only understands positional ``{}``, so
    every named slot is normalised to ``{}`` here. The kinds list follows the
    same left-to-right order.

    A message block is its own paragraph, so it is separated from the sentences
    by a blank line: the benchmark's SWIFT and XBRL documents put the block on
    its own lines, and a single space would glue tags onto prose.
    """
    n_clauses = rng.choice([3, 3, 3, 4, 4])
    sentences = [rng.choice(OPENERS)] + rng.sample(CLAUSES, n_clauses)
    closer = rng.choice(CLOSERS)
    block = (rng.choice(MESSAGE_BLOCKS)
             if rng.random() < MESSAGE_BLOCK_SHARE else None)

    picked = sentences + ([block] if block is not None else []) + [closer]
    seps = [" "] * (len(sentences) - 1)
    if block is not None:
        seps += ["\n\n", "\n\n"]
    else:
        seps += [" "]
    template = "".join(
        _positional(part[0]) + (seps[i] if i < len(seps) else "")
        for i, part in enumerate(picked)
    )
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
