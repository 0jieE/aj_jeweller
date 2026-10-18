"""The app's demo data (seed_data.dart + StaffDirectory.seed), rebuilt here.

Like the app, everything is dated relative to now so "today" lines up with the
dashboard. It is produced as a phone snapshot and loaded through the same
importer as real phone data, so the seed command and /sync/import cannot
drift apart. `shop/tests/test_f_import_sync.py` checks it field by field
against a snapshot the app itself wrote.
"""

from datetime import datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal

from django.utils import timezone

from accounts.models import name_key

from .snapshot import dt
from .text import fixed3, peso

STAFF = [
    {"id": "USR-AJ01", "name": "Arnel Javier", "role": "admin", "homeBranch": None},
    {"id": "USR-K-APR", "name": "Liza Mendoza", "role": "assistantAppraiser", "homeBranch": "kidapawan"},
    {"id": "USR-K-REP", "name": "Rhea Castillo", "role": "salesRep", "homeBranch": "kidapawan"},
    {"id": "USR-K-CSH", "name": "Grace Ramos", "role": "cashier", "homeBranch": "kidapawan"},
    {"id": "USR-D-APR", "name": "Joel Bautista", "role": "assistantAppraiser", "homeBranch": "davao"},
    {"id": "USR-D-REP", "name": "Paolo Delos Reyes", "role": "salesRep", "homeBranch": "davao"},
    {"id": "USR-D-CSH", "name": "Ben Soriano", "role": "cashier", "homeBranch": "davao"},
]
ADMIN = "USR-AJ01"


def for_role(role: str, branch: str | None = None) -> dict:
    """StaffDirectory.forRole: the branch's own person, else anyone in the role, else the Admin."""
    for person in STAFF:
        if person["role"] == role and person["homeBranch"] == branch:
            return person
    for person in STAFF:
        if person["role"] == role:
            return person
    return STAFF[0]


def by_id(user_id):
    return next((p for p in STAFF if p["id"] == user_id), None)


def _whole_pesos(centavos: float) -> int:
    """Dart's `(centavos / 100).round() * 100` — halves round away from zero."""
    return int(Decimal(str(centavos / 100)).quantize(Decimal("1"), rounding=ROUND_HALF_UP)) * 100


# (id, batch, description, weight, gross, karat, type, capital, origin, branch, status, verification,
#  days ago or None for now, extra partition fields)
_ITEMS = [
    ("7H3M2Q", "A7K2M9", "22K gold necklace, rope chain", 15.750, 16.400, 22, "goods", 8200000, "Maria Santos",
     "kidapawan", "listed", "verified", 5, {}),
    ("B4T9KD", "A3T8QD", "18K gold ring w/ diamond chip", 3.200, 3.850, 18, "goods", 1350000, "Rico Dela Cruz",
     "kidapawan", "pending", "awaitingVerification", None, {}),
    ("X2P7LN", "A9P4XN", "Bulk scrap lot – broken chains", 27.500, None, 18, "scrap", 10500000,
     "Bulk buy – pawnshop consignment", "kidapawan", "forDisposal", "verified", 10,
     {"originalGrams": 42.5, "originalAmount": 16500000, "remainingGrams": 27.5, "remainingAmount": 10500000}),
    ("M9Q4RT", "A9P4XN", "Partitioned – 18K fine filings, listed for resale", 15.000, None, 18, "goods", 6000000,
     "Bulk buy – pawnshop consignment", "kidapawan", "listed", "verified", 9, {"parentLotId": "X2P7LN"}),
    ("K7D3WZ", "A7K2M9", "Mixed small jewelry", 8.900, 9.400, 14, "goods", 2470000, "Maria Santos", "kidapawan",
     "listed", "verified", 3, {}),
    ("S2L9VQ", "A4S7VN", "925 silver ring set (3 pcs)", 30.000, None, 925, "silver", 180000, "Joy Villareal",
     "kidapawan", "listed", "verified", 4, {}),
    ("S5K8VD", "B6S3VD", "999 silver coins, assorted", 62.200, None, 999, "silver", 460000, "Mario Tan", "davao",
     "listed", "verified", 6, {}),
    ("S7V2RB", "A5S9VR", "925 silver bracelet, curb link", 24.500, 25.000, 925, "silver", 150000, "Lorna Diaz",
     "kidapawan", "pending", "awaitingVerification", None, {}),
    ("S8B3VN", "A5S9VR", "999 silver bar, 50g", 50.000, None, 999, "silver", 360000, "Lorna Diaz", "kidapawan",
     "pending", "awaitingVerification", None, {}),
    ("V5N8JH", "A3T8QD", "24K gold bar clipping", 2.100, None, 24, "goods", 1260000, "Rico Dela Cruz", "kidapawan",
     "pending", "awaitingVerification", None, {}),
    ("T3R6PC", "A8R3PC", "21K gold bangle", 20.300, None, 21, "goods", 9800000, "Eloisa Gomez", "kidapawan", "sold",
     "verified", 12, {}),
    ("G8L2XF", "A4L9XF", "Scrap batch – prior disposal lot", 38.200, None, 18, "scrap", 14000000, "Bulk buy",
     "kidapawan", "disposed", "verified", 25, {}),
    ("W4K7MB", "A6K4MB", "18K gold ring, plain band", 4.000, None, 18, "goods", 1700000, "Grace Palma", "kidapawan",
     "sold", "verified", 1, {}),
    ("J4W8PT", "A9W7PT", "Scrap lot – mixed 18K oddments", 21.400, 22.900, 18, "scrap", 9200000,
     "Bulk buy – estate clearance", "kidapawan", "disposed", "verified", 19, {}),
    ("Q6Y3DN", "A7Y2DN", "Scrap batch – loan payoff lot", 93.000, None, 21, "scrap", 44000000, "Bulk buy",
     "kidapawan", "disposed", "verified", 18, {}),
    ("Z9C4HT", "B9C3HT", "22K gold earrings, hoop pair", 6.400, None, 22, "goods", 3420000, "Ana Villanueva", "davao",
     "listed", "verified", 6, {}),
    ("L2M8XK", "B2M7XK", "18K gold pendant, cross", 4.100, None, 18, "goods", 1680000, "Jun Alba", "davao", "pending",
     "awaitingVerification", None, {}),
    ("N7V3BQ", "B7V4BQ", "Scrap – assorted broken pieces", 65.800, None, 18, "scrap", 25500000,
     "Bulk buy – estate lot", "davao", "forDisposal", "verified", 8, {}),
    ("R4J9WD", "B4J8WD", "21K gold ring, solitaire setting", 5.500, None, 21, "goods", 2830000, "Carmela Reyes",
     "davao", "reserved", "verified", 2, {}),
    ("C8F2TM", "B8F3TM", "24K gold ingot piece", 10.000, None, 24, "goods", 6150000, "Danny Uy", "davao", "sold",
     "verified", 9, {}),
    ("H5P7LZ", "B5P6LZ", "Broken earrings mix", 12.300, 13.100, 14, "scrap", 3410000, "Perla Cruz", "davao", "pending",
     "returnedForCorrection", 1, {}),
    ("S4N6VK", "B5S2VK", "925 silver necklace, box chain", 18.500, None, 925, "silver", 111000, "Tess Navarro", "davao",
     "pending", "awaitingVerification", None, {}),
    ("D3X6KN", "B3X7KN", "Scrap batch – prior disposal lot", 55.000, None, 18, "scrap", 21000000, "Bulk buy", "davao",
     "disposed", "verified", 18, {}),
]

_RATES = {24: 615000, 22: 563800, 21: 538100, 20: 512500, 18: 461300, 14: 358800, 10: 256300, 999: 7500, 925: 6500}
_CONTACTS = {"A7K2M9": "0917 555 0142", "A3T8QD": "0918 231 7744", "A8R3PC": "0905 887 3310",
             "A6K4MB": "0936 221 9087", "B9C3HT": "0922 604 1180", "B4J8WD": "0947 118 2265"}
_ADDRESSES = {"A7K2M9": "Poblacion, Kidapawan City", "A3T8QD": "Amas, Kidapawan City",
              "A8R3PC": "Lanao, Kidapawan City", "B9C3HT": "Matina, Davao City", "B4J8WD": "Buhangin, Davao City"}


def _item(row, now: datetime) -> dict:
    (iid, batch, desc, weight, gross, karat, kind, capital, origin, branch, status, verification, days, extra) = row
    return {
        "id": iid, "description": desc, "weight": weight, "gross": gross, "karat": karat, "type": kind,
        "capital": capital, "origin": origin, "branch": branch, "status": status, "verification": verification,
        "purchaseDate": now if days is None else now - timedelta(days=days), "submittedByRole": "assistantAppraiser",
        "photo": None, "encodedBy": for_role("assistantAppraiser", branch)["id"], "batchId": batch,
        "verificationNote": None, "parentLotId": extra.get("parentLotId"), "originalGrams": extra.get("originalGrams"),
        "originalAmount": extra.get("originalAmount"), "remainingGrams": extra.get("remainingGrams"),
        "remainingAmount": extra.get("remainingAmount"),
    }


def _original_amount(item: dict) -> int:
    return item["originalAmount"] if item["originalAmount"] is not None else item["capital"]


def _payment_label(cash: int, bank: int) -> str:
    if cash > 0 and bank > 0:
        return "Cash + Bank"
    if bank > 0 and cash == 0:
        return "Bank Transfer"
    return "Cash"


def build(now: datetime | None = None) -> dict:
    """The demo shop as a phone snapshot (dates as datetimes until encoded)."""
    now = timezone.localtime(now or timezone.now())
    items = [_item(row, now) for row in _ITEMS]
    find = {i["id"]: i for i in items}

    rated = now - timedelta(hours=2)
    gold_rates = [{"karat": k, "price": p, "updatedAt": rated} for k, p in _RATES.items()]
    history = []
    for rate in gold_rates:
        current = rate["price"]
        first, second = _whole_pesos(current * 0.96), _whole_pesos(current * 0.98)
        for before, after, at in ((None, first, now - timedelta(days=30)), (first, second, now - timedelta(days=14)),
                                  (second, current, rate["updatedAt"])):
            history.append({"karat": rate["karat"], "before": before, "after": after, "at": at,
                            "userId": ADMIN, "userName": "Arnel Javier", "restoredFrom": None})

    sales = [
        {"id": "S4M2HQ", "lines": [{"item": dict(find["T3R6PC"]), "price": 11500000, "finalGrams": 20.100}],
         "customer": {"name": "Teresa Lim", "contact": "0916 774 2098", "address": "Poblacion, Kidapawan City",
                      "customerId": None},
         "note": None, "cash": 11500000, "bank": 0, "verification": "verified", "verificationNote": None,
         "branch": "kidapawan", "date": now - timedelta(days=2), "submittedByRole": "salesRep",
         "submittedBy": "USR-K-REP", "receivedBy": "USR-K-CSH"},
        {"id": "S8K7TD", "lines": [{"item": dict(find["C8F2TM"]), "price": 7200000, "finalGrams": 10.000}],
         "customer": {"name": "Michael Ong", "contact": "0933 512 8841", "address": None, "customerId": None},
         "note": None, "cash": 2200000, "bank": 5000000, "verification": "awaitingVerification",
         "verificationNote": None, "branch": "davao", "date": now, "submittedByRole": "salesRep",
         "submittedBy": "USR-D-REP", "receivedBy": None},
        {"id": "S3W9NL", "lines": [{"item": dict(find["W4K7MB"]), "price": 2200000, "finalGrams": 3.950}],
         "customer": {"name": "Grace Palma", "contact": None, "address": None, "customerId": None},
         "note": None, "cash": 2200000, "bank": 0, "verification": "awaitingVerification", "verificationNote": None,
         "branch": "kidapawan", "date": now, "submittedByRole": "salesRep", "submittedBy": "USR-K-REP",
         "receivedBy": None},
    ]

    commitments = [
        {"id": "P7B4QX", "lender": "Metro Pawnshop Corp", "amount": 50000000, "rate": 538100, "branch": "kidapawan",
         "approved": now - timedelta(days=30), "received": now - timedelta(days=28), "proofPhoto": None},
        {"id": "P2N9KM", "lender": "Golden Circle Lending", "amount": 75000000, "rate": 563800, "branch": None,
         "approved": now - timedelta(days=15), "received": now - timedelta(days=10), "proofPhoto": None},
        {"id": "P5T3HD", "lender": "Kidapawan Credit Union", "amount": 30000000, "rate": 461300, "branch": "kidapawan",
         "approved": now - timedelta(days=5), "received": None, "proofPhoto": None},
    ]
    disposals = [
        {"id": "F9R2MW", "branch": "kidapawan", "itemIds": ["G8L2XF"], "capital": 14000000, "grossGrams": 38.200,
         "grossAmount": 15280000, "commitmentRef": "P7B4QX", "date": now - timedelta(days=20), "photo": None},
        {"id": "F4K8QT", "branch": "davao", "itemIds": ["D3X6KN"], "capital": 21000000, "grossGrams": 55.000,
         "grossAmount": 20450000, "commitmentRef": "P2N9KM", "date": now - timedelta(days=15), "photo": None},
        {"id": "F6H3ZN", "branch": "kidapawan", "itemIds": ["Q6Y3DN", "J4W8PT"], "capital": 53200000,
         "grossGrams": 114.400, "grossAmount": 50000000, "commitmentRef": "P7B4QX", "date": now - timedelta(days=15),
         "photo": None},
    ]

    # Purchase batches, rebuilt from their pieces; newest first (a stable sort).
    grouped: dict[str, list[dict]] = {}
    for item in items:
        grouped.setdefault(item["batchId"], []).append(item)
    batches = []
    for bid, group in grouped.items():
        lead = next((i for i in group if i["parentLotId"] is None), group[0])
        verified = lead["verification"] == "verified"
        batches.append({
            "id": bid, "customer": {"name": lead["origin"], "contact": _CONTACTS.get(bid), "address": _ADDRESSES.get(bid),
                                    "customerId": None},
            "branch": lead["branch"], "date": lead["purchaseDate"], "submittedByRole": lead["submittedByRole"],
            "verification": lead["verification"], "verificationNote": lead["verificationNote"],
            "releasedAt": lead["purchaseDate"] + timedelta(minutes=20) if verified else None,
            "submittedBy": lead["encodedBy"],
            "releasedBy": for_role("cashier", lead["branch"])["id"] if verified else None,
            "releaseProofPhoto": None,
        })
    batches.sort(key=lambda b: b["date"], reverse=True)

    # The customer book, derived from the transactions.
    book: dict[str, dict] = {}
    for record in [*batches, *sales]:
        details, seen_at = record["customer"], record["date"]
        key = name_key(details["name"])
        existing = book.get(key)
        if existing is None:
            book[key] = {"id": f"CUS{len(book) + 1:03d}", "name": details["name"].strip(), "contact": details["contact"],
                         "address": details["address"], "firstSeen": seen_at, "photo": None}
        else:
            existing["contact"] = existing["contact"] or details["contact"]
            existing["address"] = existing["address"] or details["address"]
            existing["firstSeen"] = min(existing["firstSeen"], seen_at)
    for record in [*batches, *sales]:
        record["customer"]["customerId"] = book[name_key(record["customer"]["name"])]["id"]

    # The ledger behind the opening balances.
    entries = []
    def entry(**fields):
        entries.append({"id": f"CSH{len(entries) + 1:03d}", "category": None, "transferPairId": None, **fields})
    for batch in batches:
        if batch["verification"] != "verified":
            continue
        lines = [i for i in items if i["batchId"] == batch["id"] and i["parentLotId"] is None]
        entry(branch=batch["branch"], type="expense", account="purchase", amount=sum(_original_amount(i) for i in lines),
              note=f"Purchase released - {batch['customer']['name']} ({len(lines)} item(s))", category="Purchase",
              date=batch["releasedAt"] or batch["date"], recordedByRole="cashier", recordedBy=batch["releasedBy"],
              source="purchase", linkedRecordId=batch["id"])
    for sale in sales:
        if sale["verification"] == "verified" and sale["cash"] > 0:
            entry(branch=sale["branch"], type="cashIn", account="sales", amount=sale["cash"],
                  note=f"Payment received - {sale['customer']['name']}", date=sale["date"], recordedByRole="cashier",
                  recordedBy=sale["receivedBy"], source="sale", linkedRecordId=sale["id"])
    for sale in sales:
        if sale["verification"] == "verified" and sale["bank"] > 0:
            entry(branch=sale["branch"], type="cashIn", account="bank", amount=sale["bank"],
                  note=f"Bank payment received - {sale['customer']['name']}", date=sale["date"],
                  recordedByRole="cashier", recordedBy=sale["receivedBy"], source="sale", linkedRecordId=sale["id"])
    for c in commitments:
        if c["branch"] is not None and c["received"] is not None:
            entry(branch=c["branch"], type="cashIn", account="purchase", amount=c["amount"],
                  note=f"Loan proceeds received - {c['lender']}", date=c["received"], recordedByRole="admin",
                  recordedBy=ADMIN, source="commitment", linkedRecordId=c["id"])

    # The log history behind the records.
    logs = []
    def log(at, action, user_id, fallback_role, branch, summary, record_id=None, record_kind=None, amount=None,
            changes=()):
        person = by_id(user_id) or for_role(fallback_role, branch)
        logs.append({"id": f"LOG{len(logs) + 1:03d}", "at": at, "action": action, "userId": person["id"],
                     "userName": person["name"], "role": person["role"], "summary": summary, "branch": branch,
                     "recordId": record_id, "recordKind": record_kind, "amount": amount, "changes": list(changes)})
    for batch in batches:
        lines = [i for i in items if i["batchId"] == batch["id"] and i["parentLotId"] is None]
        total = sum(_original_amount(i) for i in lines)
        name = batch["customer"]["name"]
        log(batch["date"], "purchaseRecorded", batch["submittedBy"], "assistantAppraiser", batch["branch"],
            f"Recorded {len(lines)} item(s) from {name} for {peso(total)}", batch["id"], "purchaseBatch", total)
        if batch["releasedAt"]:
            log(batch["releasedAt"], "cashReleased", batch["releasedBy"], "cashier", batch["branch"],
                f"Released {peso(total)} to {name} for {len(lines)} item(s)", batch["id"], "purchaseBatch", total)
        if batch["verification"] == "returnedForCorrection":
            note = f": {batch['verificationNote']}" if batch["verificationNote"] else ""
            log(batch["date"] + timedelta(minutes=15), "purchaseReturned", None, "cashier", batch["branch"],
                f"Returned the purchase from {name} for correction{note}", batch["id"], "purchaseBatch")
    for piece in (i for i in items if i["parentLotId"]):
        log(piece["purchaseDate"], "partitionCreated", piece["encodedBy"], "assistantAppraiser", piece["branch"],
            f'Drew "{piece["description"]}" ({fixed3(Decimal(str(piece["weight"])))}g, {peso(piece["capital"])}) '
            f'out of lot {piece["parentLotId"]}', piece["id"], "item", piece["capital"])
    for sale in sales:
        total = sum(line["price"] for line in sale["lines"])
        name = sale["customer"]["name"]
        log(sale["date"], "saleSubmitted", sale["submittedBy"], "salesRep", sale["branch"],
            f"Sent an order of {len(sale['lines'])} item(s) for {name} ({peso(total)}) to the Cashier",
            sale["id"], "sale", total)
        if sale["verification"] == "verified":
            paid = sale["cash"] + sale["bank"]
            log(sale["date"] + timedelta(minutes=10), "paymentReceived", sale["receivedBy"], "cashier", sale["branch"],
                f"Received {peso(paid)} from {name} by {_payment_label(sale['cash'], sale['bank']).lower()}",
                sale["id"], "sale", paid)
    for c in commitments:
        log(c["approved"], "commitmentAdded", ADMIN, "admin", c["branch"],
            f"Added a {peso(c['amount'])} commitment with {c['lender']}", c["id"], "commitment", c["amount"])
        if c["received"]:
            log(c["received"], "commitmentReceived", ADMIN, "admin", c["branch"],
                f"Recorded {peso(c['amount'])} received from {c['lender']}", c["id"], "commitment", c["amount"])
    lenders = {c["id"]: c["lender"] for c in commitments}
    for d in disposals:
        log(d["date"], "disposalCompleted", ADMIN, "admin", d["branch"],
            f"Disposed {len(d['itemIds'])} item(s), {fixed3(Decimal(str(d['grossGrams'])))}g, for "
            f"{peso(d['grossAmount'])} applied to {lenders.get(d['commitmentRef'], d['commitmentRef'])}",
            d["id"], "disposal", d["grossAmount"])
    for change in history:
        name = f"{change['karat']} silver" if change["karat"] >= 100 else f"{change['karat']}K"
        if change["before"] is None:
            log(change["at"], "goldRateAdded", change["userId"], "admin", None,
                f"Added a {name} rate at {peso(change['after'])} per gram",
                changes=[{"field": f"{name} per gram", "before": "—", "after": peso(change["after"])}])
        else:
            log(change["at"], "goldRateUpdated", change["userId"], "admin", None,
                f"{name} rate changed from {peso(change['before'])} to {peso(change['after'])} per gram",
                changes=[{"field": f"{name} per gram", "before": peso(change["before"]),
                          "after": peso(change["after"])}])
    logs.sort(key=lambda entry_: entry_["at"])

    snapshot = {
        "version": 1, "savedAt": now,
        "users": [{**p, "contact": None, "active": True} for p in STAFF],
        "branches": [
            {"id": "kidapawan", "startingCash": 159840300, "startingSalesCash": 0, "startingBank": 25850000,
             "silverValue": 0},
            {"id": "davao", "startingCash": 128776900, "startingSalesCash": 0, "startingBank": 18420000,
             "silverValue": 14926100},
        ],
        "goldRates": gold_rates, "rateHistory": history, "items": items, "sales": sales, "commitments": commitments,
        "disposalBatches": disposals, "cashEntries": entries, "purchaseBatches": batches, "receipts": [],
        "customers": list(book.values()), "logs": logs,
    }
    return _encode_dates(snapshot)


def _encode_dates(value):
    if isinstance(value, datetime):
        return dt(value)
    if isinstance(value, dict):
        return {k: _encode_dates(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_encode_dates(v) for v in value]
    return value
