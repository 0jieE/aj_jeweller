"""POST /sync/import — moves the phone's existing data onto the server.

Takes one snapshot in the phone's file format (snapshot_codec.dart) and
creates every record with its existing id, so nothing is re-entered and every
receipt and claim tag keeps pointing at the right thing.

* The whole snapshot is read and checked before anything is written (like
  `restoreSnapshot`, a bad file changes nothing), and the import runs in one
  transaction.
* Importing twice duplicates nothing: a record whose id the server already
  holds is skipped, and so is a rate-history row it already has. A deleted
  record's id stays registered, so an old snapshot cannot resurrect it.
* An id the server holds for a *different* kind of record is a conflict, and
  the import is refused.
* Historical records are taken as they are: business rules governed how they
  were made on the phone, so they are not re-run — only the database's own
  constraints are checked up front, so a refusal can say what is wrong.
"""

import base64
import binascii
from decimal import ROUND_HALF_UP, Decimal

from django.core.files.base import ContentFile
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from accounts.models import User, name_key

from ..enums import (
    BranchId,
    CashAccount,
    CashEntrySourceType,
    CashEntryType,
    ItemStatus,
    ItemType,
    LogAction,
    LogRecordKind,
    ReceiptKind,
    Role,
    VerificationStatus,
    category_for,
    needs_branch,
)
from ..errors import Conflict, Refusal
from ..ids import LEGACY_ID_RE
from ..models import (
    Branch,
    CashEntry,
    Commitment,
    Customer,
    DisposalBatch,
    DisposalItem,
    GoldRate,
    Item,
    PurchaseBatch,
    RateChange,
    RecordId,
    Sale,
    SaleLineItem,
    StoredReceipt,
    TransactionLog,
)

from .base import ADMIN_ONLY, Ctx, require_role, write_log

THREE = Decimal("0.001")
SECTIONS = ["users", "branches", "goldRates", "rateHistory", "customers", "purchaseBatches", "items", "commitments",
            "disposalBatches", "sales", "cashEntries", "receipts", "logs"]
MAX_PROBLEMS = 50


class _Reader:
    """Reads one record's fields, noting every problem instead of stopping at
    the first, so a refused import lists everything that needs fixing."""

    def __init__(self, problems: list[str]):
        self.problems = problems

    def fail(self, path: str, message: str) -> None:
        self.problems.append(f"{path}: {message}")

    def get(self, obj: dict, key: str, path: str, kind: str, *, null: bool = False, choices=None, default=...):
        here = f"{path}.{key}"
        if key not in obj or obj[key] is None:
            if default is not ...:
                return default
            if null:
                return None
            self.fail(here, "is required")
            return None
        value = obj[key]
        if kind == "str":
            if not isinstance(value, str):
                return self.fail(here, "must be text")
        elif kind == "int":
            if not isinstance(value, int) or isinstance(value, bool):
                return self.fail(here, "must be a whole number")
        elif kind == "bool":
            if not isinstance(value, bool):
                return self.fail(here, "must be true or false")
        elif kind == "grams":
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                return self.fail(here, "must be a number")
            value = Decimal(str(value)).quantize(THREE, rounding=ROUND_HALF_UP)
        elif kind == "date":
            parsed = parse_datetime(value) if isinstance(value, str) else None
            if parsed is None:
                return self.fail(here, f"{value!r} is not an ISO-8601 date and time")
            value = timezone.make_aware(parsed) if timezone.is_naive(parsed) else parsed
        elif kind == "bytes":
            if not isinstance(value, str):
                return self.fail(here, "must be base64 text")
            try:
                value = base64.b64decode(value, validate=True)
            except (binascii.Error, ValueError):
                return self.fail(here, "is not valid base64")
        elif kind == "list":
            if not isinstance(value, list):
                return self.fail(here, "must be a list")
        elif kind == "dict":
            if not isinstance(value, dict):
                return self.fail(here, "must be an object")
        if choices is not None and value not in choices:
            return self.fail(here, f"{value!r} is not one of {', '.join(choices)}")
        return value

    def record_id(self, obj: dict, path: str, key: str = "id", null: bool = False) -> str | None:
        value = self.get(obj, key, path, "str", null=null)
        if value is not None and not LEGACY_ID_RE.match(value):
            self.fail(f"{path}.{key}", f"{value!r} is not a record id")
            return None
        return value


# --- reading -------------------------------------------------------------------

def _parse(data, problems: list[str]) -> dict:
    r = _Reader(problems)
    if not isinstance(data, dict):
        r.fail("snapshot", "must be a JSON object")
        return {}
    version = data.get("version", 1)
    if version != 1:
        r.fail("version", f"snapshot version {version!r} is not supported (this server reads version 1)")
    sections = {}
    for name in SECTIONS:
        raw = data.get(name, [])
        if raw is None:
            raw = []
        if not isinstance(raw, list):
            r.fail(name, "must be a list")
            raw = []
        sections[name] = [row if isinstance(row, dict) else {} for row in raw]
    if len(sections["branches"]) != len(BranchId.values):
        r.fail("branches", "Saved data is missing a branch")

    roles, branches = Role.values, BranchId.values
    out: dict[str, list[dict]] = {name: [] for name in SECTIONS}

    for i, u in enumerate(sections["users"]):
        p = f"users[{i}]"
        row = {"id": r.get(u, "id", p, "str"), "name": r.get(u, "name", p, "str"),
               "role": r.get(u, "role", p, "str", choices=roles),
               "home_branch": r.get(u, "homeBranch", p, "str", null=True, choices=branches),
               "contact": r.get(u, "contact", p, "str", null=True), "active": r.get(u, "active", p, "bool", default=True)}
        if row["role"] and needs_branch(row["role"]) == (row["home_branch"] is None):
            r.fail(p, "an Admin or Superuser works across both branches; everyone else works from one")
        if row["name"] is not None and not row["name"].strip():
            r.fail(f"{p}.name", "is blank")
        out["users"].append(row)

    for i, b in enumerate(sections["branches"]):
        p = f"branches[{i}]"
        out["branches"].append({"id": r.get(b, "id", p, "str", choices=branches),
                                "purchase": r.get(b, "startingCash", p, "int"),
                                "sales": r.get(b, "startingSalesCash", p, "int", default=0),
                                "bank": r.get(b, "startingBank", p, "int", default=0)})

    for i, g in enumerate(sections["goldRates"]):
        p = f"goldRates[{i}]"
        row = {"karat": r.get(g, "karat", p, "int"), "price": r.get(g, "price", p, "int"),
               "updated_at": r.get(g, "updatedAt", p, "date")}
        if row["karat"] is not None and not (1 <= row["karat"] <= 24 or 100 <= row["karat"] <= 999):
            r.fail(f"{p}.karat", "must be a gold karat (1–24) or a silver fineness (100–999)")
        if row["price"] is not None and row["price"] <= 0:
            r.fail(f"{p}.price", "must be above zero")
        out["goldRates"].append(row)

    for i, c in enumerate(sections["rateHistory"]):
        p = f"rateHistory[{i}]"
        row = {"karat": r.get(c, "karat", p, "int"), "before": r.get(c, "before", p, "int", null=True),
               "after": r.get(c, "after", p, "int"), "at": r.get(c, "at", p, "date"),
               "user_id": r.get(c, "userId", p, "str", null=True), "user_name": r.get(c, "userName", p, "str", default=""),
               "restored_from": r.get(c, "restoredFrom", p, "date", null=True)}
        if row["after"] is not None and row["after"] <= 0:
            r.fail(f"{p}.after", "must be above zero")
        out["rateHistory"].append(row)

    for i, c in enumerate(sections["customers"]):
        p = f"customers[{i}]"
        row = {"id": r.record_id(c, p), "name": r.get(c, "name", p, "str"),
               "contact": r.get(c, "contact", p, "str", null=True), "address": r.get(c, "address", p, "str", null=True),
               "first_seen": r.get(c, "firstSeen", p, "date"), "photo": r.get(c, "photo", p, "bytes", null=True)}
        if row["name"] is not None and not row["name"].strip():
            r.fail(f"{p}.name", "is blank")
        out["customers"].append(row)

    def customer_details(obj, p):
        raw = r.get(obj, "customer", p, "dict")
        if raw is None:
            return {"name": "", "contact": None, "address": None, "customer_id": None}
        p = f"{p}.customer"
        return {"name": r.get(raw, "name", p, "str"), "contact": r.get(raw, "contact", p, "str", null=True),
                "address": r.get(raw, "address", p, "str", null=True),
                "customer_id": r.record_id(raw, p, "customerId", null=True)}

    verification = VerificationStatus.values
    for i, b in enumerate(sections["purchaseBatches"]):
        p = f"purchaseBatches[{i}]"
        out["purchaseBatches"].append({
            "id": r.record_id(b, p), "customer": customer_details(b, p),
            "branch": r.get(b, "branch", p, "str", choices=branches), "date": r.get(b, "date", p, "date"),
            "submitted_by_role": r.get(b, "submittedByRole", p, "str", choices=roles),
            "verification": r.get(b, "verification", p, "str", choices=verification),
            "verification_note": r.get(b, "verificationNote", p, "str", null=True),
            "released_at": r.get(b, "releasedAt", p, "date", null=True),
            "submitted_by": r.get(b, "submittedBy", p, "str", null=True),
            "released_by": r.get(b, "releasedBy", p, "str", null=True),
            "proof": r.get(b, "releaseProofPhoto", p, "bytes", null=True),
        })

    def item(obj, p):
        row = {
            "id": r.record_id(obj, p), "description": r.get(obj, "description", p, "str"),
            "weight": r.get(obj, "weight", p, "grams"), "gross": r.get(obj, "gross", p, "grams", null=True),
            "karat": r.get(obj, "karat", p, "int"), "type": r.get(obj, "type", p, "str", choices=ItemType.values),
            "capital": r.get(obj, "capital", p, "int"), "origin": r.get(obj, "origin", p, "str", default=""),
            "branch": r.get(obj, "branch", p, "str", choices=branches),
            "status": r.get(obj, "status", p, "str", choices=ItemStatus.values),
            "verification": r.get(obj, "verification", p, "str", choices=verification),
            "purchase_date": r.get(obj, "purchaseDate", p, "date"),
            "submitted_by_role": r.get(obj, "submittedByRole", p, "str", choices=roles),
            "photo": r.get(obj, "photo", p, "bytes", null=True), "encoded_by": r.get(obj, "encodedBy", p, "str", null=True),
            "batch_id": r.record_id(obj, p, "batchId", null=True),
            "verification_note": r.get(obj, "verificationNote", p, "str", null=True),
            "parent_id": r.record_id(obj, p, "parentLotId", null=True),
            "original_grams": r.get(obj, "originalGrams", p, "grams", null=True),
            "original_amount": r.get(obj, "originalAmount", p, "int", null=True),
            "remaining_grams": r.get(obj, "remainingGrams", p, "grams", null=True),
            "remaining_amount": r.get(obj, "remainingAmount", p, "int", null=True),
        }
        karat, kind = row["karat"], row["type"]
        if karat is not None and kind is not None:
            silver = kind == ItemType.SILVER
            if silver and not 100 <= karat <= 999:
                r.fail(p, f"a silver piece needs a silver purity (e.g. 925), not {karat}")
            if not silver and not 1 <= karat <= 24:
                r.fail(p, f"a gold piece needs a karat of 1–24, not {karat}")
        for key in ("weight", "capital", "remaining_grams", "remaining_amount"):
            if row[key] is not None and row[key] < 0:
                r.fail(f"{p}.{key}", "cannot be negative")
        if row["gross"] is not None and row["weight"] is not None and row["gross"] < row["weight"]:
            r.fail(p, "the original (gross) weight is less than the final (net) weight")
        return row

    for i, it in enumerate(sections["items"]):
        out["items"].append(item(it, f"items[{i}]"))

    for i, c in enumerate(sections["commitments"]):
        p = f"commitments[{i}]"
        row = {"id": r.record_id(c, p), "lender": r.get(c, "lender", p, "str"), "amount": r.get(c, "amount", p, "int"),
               "rate": r.get(c, "rate", p, "int"), "branch": r.get(c, "branch", p, "str", null=True, choices=branches),
               "approved": r.get(c, "approved", p, "date"), "received": r.get(c, "received", p, "date", null=True),
               "proof": r.get(c, "proofPhoto", p, "bytes", null=True)}
        for key in ("amount", "rate"):
            if row[key] is not None and row[key] <= 0:
                r.fail(f"{p}.{key}", "must be above zero")
        out["commitments"].append(row)

    for i, d in enumerate(sections["disposalBatches"]):
        p = f"disposalBatches[{i}]"
        ids = r.get(d, "itemIds", p, "list") or []
        out["disposalBatches"].append({
            "id": r.record_id(d, p), "branch": r.get(d, "branch", p, "str", choices=branches),
            "item_ids": [x for x in ids if isinstance(x, str)], "capital": r.get(d, "capital", p, "int"),
            "gross_grams": r.get(d, "grossGrams", p, "grams"), "gross_amount": r.get(d, "grossAmount", p, "int"),
            "commitment_id": r.record_id(d, p, "commitmentRef"), "date": r.get(d, "date", p, "date"),
            "photo": r.get(d, "photo", p, "bytes", null=True),
        })

    for i, s in enumerate(sections["sales"]):
        p = f"sales[{i}]"
        lines = []
        for j, line in enumerate(r.get(s, "lines", p, "list") or []):
            lp = f"{p}.lines[{j}]"
            line = line if isinstance(line, dict) else {}
            raw_item = r.get(line, "item", lp, "dict") or {}
            parsed = {"item": item(raw_item, f"{lp}.item"), "raw_item": raw_item,
                      "price": r.get(line, "price", lp, "int"),
                      "final_grams": r.get(line, "finalGrams", lp, "grams", null=True)}
            if parsed["price"] is not None and parsed["price"] <= 0:
                r.fail(f"{lp}.price", "must be above zero")
            if parsed["final_grams"] is not None and parsed["final_grams"] <= 0:
                r.fail(f"{lp}.finalGrams", "must be above zero")
            lines.append(parsed)
        row = {"id": r.record_id(s, p), "lines": lines, "customer": customer_details(s, p),
               "note": r.get(s, "note", p, "str", null=True), "cash": r.get(s, "cash", p, "int", default=0),
               "bank": r.get(s, "bank", p, "int", default=0),
               "verification": r.get(s, "verification", p, "str", choices=verification),
               "verification_note": r.get(s, "verificationNote", p, "str", null=True),
               "branch": r.get(s, "branch", p, "str", choices=branches), "date": r.get(s, "date", p, "date"),
               "submitted_by_role": r.get(s, "submittedByRole", p, "str", choices=roles),
               "submitted_by": r.get(s, "submittedBy", p, "str", null=True),
               "received_by": r.get(s, "receivedBy", p, "str", null=True)}
        if len({line["item"]["id"] for line in lines}) != len(lines):
            r.fail(p, "the same piece appears twice in one sale")
        out["sales"].append(row)

    transfer_types = {CashEntryType.TRANSFER_IN, CashEntryType.TRANSFER_OUT}
    for i, e in enumerate(sections["cashEntries"]):
        p = f"cashEntries[{i}]"
        row = {"id": r.record_id(e, p), "branch": r.get(e, "branch", p, "str", choices=branches),
               "type": r.get(e, "type", p, "str", choices=CashEntryType.values),
               "account": r.get(e, "account", p, "str", choices=CashAccount.values, default=CashAccount.PURCHASE),
               "amount": r.get(e, "amount", p, "int"), "note": r.get(e, "note", p, "str"),
               "category": r.get(e, "category", p, "str", null=True), "date": r.get(e, "date", p, "date"),
               "recorded_by_role": r.get(e, "recordedByRole", p, "str", choices=roles),
               "recorded_by": r.get(e, "recordedBy", p, "str", null=True),
               "source": r.get(e, "source", p, "str", choices=CashEntrySourceType.values),
               "linked": r.get(e, "linkedRecordId", p, "str", null=True),
               "pair": r.get(e, "transferPairId", p, "str", null=True)}
        if row["amount"] is not None and row["amount"] <= 0:
            r.fail(f"{p}.amount", "must be above zero")
        if row["note"] is not None and not row["note"].strip():
            r.fail(f"{p}.note", "is blank")
        if row["source"] is not None and (row["source"] == CashEntrySourceType.MANUAL) != (row["linked"] is None):
            r.fail(p, "a manual entry points at no record; a linked one must name its record")
        if row["type"] is not None and (row["type"] in transfer_types) != (row["pair"] is not None):
            r.fail(p, "both halves of a transfer carry a transferPairId, and nothing else does")
        if row["category"] is not None and row["type"] != CashEntryType.EXPENSE:
            row["category"] = None  # only expenses carry a category
        out["cashEntries"].append(row)

    for i, rc in enumerate(sections["receipts"]):
        p = f"receipts[{i}]"
        out["receipts"].append({
            "id": r.record_id(rc, p), "record_id": r.get(rc, "recordId", p, "str"),
            "kind": r.get(rc, "kind", p, "str", choices=ReceiptKind.values),
            "branch": r.get(rc, "branch", p, "str", choices=branches),
            "counterparty": r.get(rc, "counterparty", p, "str", default=""), "total": r.get(rc, "total", p, "int"),
            "issued_at": r.get(rc, "issuedAt", p, "date"), "bytes": r.get(rc, "bytes", p, "bytes"),
            "text": r.get(rc, "text", p, "str", default=""),
        })

    for i, log in enumerate(sections["logs"]):
        p = f"logs[{i}]"
        changes = []
        for j, c in enumerate(r.get(log, "changes", p, "list", default=[]) or []):
            c = c if isinstance(c, dict) else {}
            changes.append({"field": r.get(c, "field", f"{p}.changes[{j}]", "str"),
                            "before": r.get(c, "before", f"{p}.changes[{j}]", "str"),
                            "after": r.get(c, "after", f"{p}.changes[{j}]", "str")})
        out["logs"].append({
            "id": r.record_id(log, p), "at": r.get(log, "at", p, "date"),
            "action": r.get(log, "action", p, "str", choices=LogAction.values),
            "user_id": r.get(log, "userId", p, "str", null=True), "user_name": r.get(log, "userName", p, "str", default=""),
            "role": r.get(log, "role", p, "str", choices=roles), "summary": r.get(log, "summary", p, "str", default=""),
            "branch": r.get(log, "branch", p, "str", null=True, choices=branches),
            "record_id": r.get(log, "recordId", p, "str", null=True),
            "record_kind": r.get(log, "recordKind", p, "str", null=True, choices=LogRecordKind.values),
            "amount": r.get(log, "amount", p, "int", null=True), "changes": changes,
        })
    return out


# --- writing -------------------------------------------------------------------

class _Report:
    def __init__(self):
        self.created = {name: 0 for name in SECTIONS}
        self.skipped = {name: 0 for name in SECTIONS}
        self.warnings: list[str] = []

    def warn(self, message: str) -> None:
        if message not in self.warnings:
            self.warnings.append(message)

    def as_dict(self, dry_run: bool) -> dict:
        return {"dry_run": dry_run, "created": self.created, "skipped": self.skipped, "warnings": self.warnings}


_KINDS = {"customers": "customer", "purchaseBatches": "purchaseBatch", "items": "item", "commitments": "commitment",
          "disposalBatches": "disposal", "sales": "sale", "cashEntries": "cashEntry", "receipts": "receipt",
          "logs": "log", "users": "user"}


def _photo(raw: bytes | None, write_files: bool) -> ContentFile | None:
    if raw is None or not write_files:
        return None
    return ContentFile(raw, name="photo.jpg")


def import_snapshot(ctx: Ctx, data, *, dry_run: bool = False, write_files: bool = True) -> dict:
    """Creates every record in `data` the server does not already hold."""
    require_role(ctx, ADMIN_ONLY, "import phone data")
    problems: list[str] = []
    snap = _parse(data, problems)
    if problems:
        raise Refusal(problems[0] if len(problems) == 1 else f"The snapshot has {len(problems)} problem(s): "
                      f"{problems[0]}", code="invalid_snapshot", problems=problems[:MAX_PROBLEMS])

    # One code, one record: check every id against the snapshot and the server.
    seen: dict[str, str] = {}
    conflicts = []
    for section, kind in _KINDS.items():
        for row in snap[section]:
            if row["id"] in seen and seen[row["id"]] != kind:
                problems.append(f"{row['id']} is used for both a {seen[row['id']]} and a {kind} in the snapshot")
            seen[row["id"]] = kind
    held = dict(RecordId.objects.filter(id__in=list(seen)).values_list("id", "kind"))
    for record_id, kind in seen.items():
        if record_id in held and held[record_id] != kind:
            conflicts.append(f"{record_id} is a {kind} on the phone but already a {held[record_id]} on the server")
    for row in snap["users"]:
        clash = User.objects.filter(name_key=name_key(row["name"])).exclude(pk=row["id"]).first()
        if clash is not None:
            conflicts.append(f"{row['name']} ({row['id']}) has the same name as {clash.name} ({clash.id}) on the server")
    if problems:
        raise Refusal(f"The snapshot has {len(problems)} problem(s): {problems[0]}", code="invalid_snapshot",
                      problems=problems[:MAX_PROBLEMS])
    if conflicts:
        raise Conflict(f"{len(conflicts)} record(s) clash with the server: {conflicts[0]}", code="import_conflict",
                       conflicts=conflicts[:MAX_PROBLEMS])

    report = _Report()
    users_known = set(User.objects.values_list("id", flat=True))

    def is_new(section: str, record_id: str) -> bool:
        if record_id in held:
            report.skipped[section] += 1
            return False
        RecordId.objects.create(id=record_id, kind=_KINDS[section])
        report.created[section] += 1
        return True

    def user_ref(user_id: str | None, where: str):
        if user_id is None:
            return None
        if user_id in users_known:
            return user_id
        report.warn(f"User {user_id} is named on records (first: {where}) but is not on file — "
                    f"those records keep the name without the link")
        return None

    # Staff -----------------------------------------------------------------
    for row in snap["users"]:
        if row["id"] in users_known:
            report.skipped["users"] += 1
            if row["id"] not in held:
                RecordId.objects.create(id=row["id"], kind="user")
            continue
        if not is_new("users", row["id"]):
            continue  # deleted on the server: an old snapshot does not bring them back
        user = User(id=row["id"], name=row["name"], role=row["role"], home_branch=row["home_branch"],
                    contact_number=row["contact"], active=row["active"], created_at=ctx.now)
        user.set_unusable_password()  # an Admin sets their PIN before they can sign in
        user.save()
        users_known.add(user.id)
        report.warn(f"{user.name} has no PIN yet — an Admin must set one (POST /users/{user.id}/pin)")

    # Branch opening balances: taken only while the server's ledger is empty.
    for row in snap["branches"]:
        branch = Branch.objects.get(pk=row["id"])
        figures = (row["purchase"], row["sales"], row["bank"])
        current = (branch.starting_purchase_cash_centavos, branch.starting_sales_cash_centavos,
                   branch.starting_bank_centavos)
        if figures == current:
            report.skipped["branches"] += 1
        elif not CashEntry.objects.filter(branch=branch).exists():
            (branch.starting_purchase_cash_centavos, branch.starting_sales_cash_centavos,
             branch.starting_bank_centavos) = figures
            branch.save()
            report.created["branches"] += 1
        else:
            report.skipped["branches"] += 1
            report.warn(f"{branch.label} already has ledger entries, so its opening balances were kept as they are")

    # Rates ------------------------------------------------------------------
    for row in snap["goldRates"]:
        if GoldRate.objects.filter(pk=row["karat"]).exists():
            report.skipped["goldRates"] += 1
            continue
        GoldRate.objects.create(karat=row["karat"], price_per_gram_centavos=row["price"], updated_at=row["updated_at"])
        report.created["goldRates"] += 1
    for row in snap["rateHistory"]:
        if RateChange.objects.filter(karat=row["karat"], at=row["at"], after_centavos=row["after"]).exists():
            report.skipped["rateHistory"] += 1
            continue
        RateChange.objects.create(
            karat=row["karat"], before_centavos=row["before"], after_centavos=row["after"], at=row["at"],
            user_id=user_ref(row["user_id"], "A rate change"), user_name=row["user_name"],
            restored_from=timezone.localtime(row["restored_from"]).date() if row["restored_from"] else None,
        )
        report.created["rateHistory"] += 1

    # Customers ----------------------------------------------------------------
    customers_known = set(Customer.objects.values_list("id", flat=True))
    for row in snap["customers"]:
        if not is_new("customers", row["id"]):
            continue
        customer = Customer(id=row["id"], name=row["name"], contact_number=row["contact"], address=row["address"],
                            first_seen=row["first_seen"])
        photo = _photo(row["photo"], write_files)
        if photo:
            customer.photo.save(photo.name, photo, save=False)
        customer.save()
        customers_known.add(customer.id)

    def customer_ref(details: dict, where: str):
        cid = details["customer_id"]
        if cid is None or cid in customers_known:
            return cid
        report.warn(f"{where} points at customer {cid}, who is not in the book — kept without the link")
        return None

    # Purchases --------------------------------------------------------------
    batches_known = set(PurchaseBatch.objects.values_list("id", flat=True))
    for row in snap["purchaseBatches"]:
        if not is_new("purchaseBatches", row["id"]):
            continue
        c = row["customer"]
        batch = PurchaseBatch(
            id=row["id"], customer_name=c["name"], customer_contact_number=c["contact"],
            customer_address=c["address"], customer_id=customer_ref(c, f"Purchase {row['id']}"),
            branch_id=row["branch"], date=row["date"], submitted_by_role=row["submitted_by_role"],
            verification_status=row["verification"], verification_note=row["verification_note"],
            released_at=row["released_at"], submitted_by_id=user_ref(row["submitted_by"], f"Purchase {row['id']}"),
            released_by_id=user_ref(row["released_by"], f"Purchase {row['id']}"),
        )
        proof = _photo(row["proof"], write_files)
        if proof:
            batch.release_proof_photo.save(proof.name, proof, save=False)
        batch.save()
        batches_known.add(batch.id)

    # Items: every piece first, then the lot each partition was drawn from.
    items_known = set(Item.objects.values_list("id", flat=True))
    pending_parents: list[tuple[Item, str]] = []
    # The phone lists items newest first, so a purchase's lines, in the order
    # they were entered, are the list read backwards.
    line_numbers: dict[str, int] = {}
    per_batch: dict[str, int] = {}
    for row in reversed(snap["items"]):
        if row["batch_id"] and not row["parent_id"]:
            per_batch[row["batch_id"]] = per_batch.get(row["batch_id"], 0) + 1
            line_numbers[row["id"]] = per_batch[row["batch_id"]]

    def create_item(row: dict, where: str) -> Item:
        batch_id = row["batch_id"] if row["batch_id"] in batches_known else None
        if row["batch_id"] and batch_id is None:
            report.warn(f"{where} belongs to purchase {row['batch_id']}, which is not in the snapshot — kept unlinked")
        item = Item(
            id=row["id"], description=row["description"], weight_grams=row["weight"], gross_weight_grams=row["gross"],
            karat=row["karat"], type=row["type"], capital_amount_centavos=row["capital"], origin=row["origin"],
            branch_id=row["branch"], item_status=row["status"], verification_status=row["verification"],
            purchase_date=row["purchase_date"], submitted_by_role=row["submitted_by_role"],
            encoded_by_id=user_ref(row["encoded_by"], where), batch_id=batch_id,
            verification_note=row["verification_note"], original_grams=row["original_grams"],
            original_amount_centavos=row["original_amount"], remaining_grams=row["remaining_grams"],
            remaining_amount_centavos=row["remaining_amount"], line_no=line_numbers.get(row["id"], 0),
        )
        photo = _photo(row["photo"], write_files)
        if photo:
            item.photo.save(photo.name, photo, save=False)
        item.save()
        items_known.add(item.id)
        if row["parent_id"]:
            pending_parents.append((item, row["parent_id"]))
        return item

    for row in snap["items"]:
        if is_new("items", row["id"]):
            create_item(row, f"Item {row['id']}")
    # A piece sold on the phone is in the sale even if the items list lost it.
    for sale in snap["sales"]:
        for line in sale["lines"]:
            row = line["item"]
            if row["id"] not in items_known and row["id"] not in seen \
                    and not RecordId.objects.filter(pk=row["id"]).exists():
                RecordId.objects.create(id=row["id"], kind="item")
                report.created["items"] += 1
                create_item(row, f"Item {row['id']} (from sale {sale['id']})")
    for item, parent_id in pending_parents:
        if parent_id in items_known:
            item.parent_lot_id = parent_id
            item.save()
        else:
            report.warn(f"Partition {item.id} was drawn from lot {parent_id}, which is not in the snapshot")

    # Commitments and disposals ---------------------------------------------------
    commitments_known = set(Commitment.objects.values_list("id", flat=True))
    for row in snap["commitments"]:
        if not is_new("commitments", row["id"]):
            continue
        commitment = Commitment(id=row["id"], lender=row["lender"], amount_centavos=row["amount"],
                                rate_per_gram_centavos=row["rate"], branch_id=row["branch"],
                                date_approved=row["approved"], date_received=row["received"])
        proof = _photo(row["proof"], write_files)
        if proof:
            commitment.received_proof_photo.save(proof.name, proof, save=False)
        commitment.save()
        commitments_known.add(commitment.id)
    for row in snap["disposalBatches"]:
        if row["commitment_id"] not in commitments_known:
            raise Refusal(f"Disposal {row['id']} applies to commitment {row['commitment_id']}, which is not in the "
                          f"snapshot or on the server", code="invalid_snapshot")
        if not is_new("disposalBatches", row["id"]):
            continue
        batch = DisposalBatch(id=row["id"], branch_id=row["branch"], capital_centavos=row["capital"],
                              gross_grams=row["gross_grams"], gross_amount_centavos=row["gross_amount"],
                              commitment_id=row["commitment_id"], date=row["date"])
        photo = _photo(row["photo"], write_files)
        if photo:
            batch.photo.save(photo.name, photo, save=False)
        batch.save()
        for position, item_id in enumerate(row["item_ids"]):
            if item_id not in items_known:
                report.warn(f"Disposal {batch.id} lists item {item_id}, which is not in the snapshot")
            elif DisposalItem.objects.filter(item_id=item_id).exists():
                report.warn(f"Item {item_id} is already in another disposal batch — not added to {batch.id}")
            else:
                DisposalItem.objects.create(batch=batch, item_id=item_id, position=position)

    # Sales ------------------------------------------------------------------
    for row in snap["sales"]:
        if not is_new("sales", row["id"]):
            continue
        c = row["customer"]
        sale = Sale.objects.create(
            id=row["id"], customer_name=c["name"], customer_contact_number=c["contact"], customer_address=c["address"],
            customer_id=customer_ref(c, f"Sale {row['id']}"), note=row["note"], cash_centavos=row["cash"],
            bank_centavos=row["bank"], verification_status=row["verification"],
            verification_note=row["verification_note"], branch_id=row["branch"], date=row["date"],
            submitted_by_role=row["submitted_by_role"], submitted_by_id=user_ref(row["submitted_by"], f"Sale {row['id']}"),
            received_by_id=user_ref(row["received_by"], f"Sale {row['id']}"),
        )
        for position, line in enumerate(row["lines"]):
            snapshot = dict(line["raw_item"])
            snapshot["photo"] = None  # the piece's photo lives on the item, not on every sale
            SaleLineItem.objects.create(sale=sale, item_id=line["item"]["id"], position=position,
                                        negotiated_price_centavos=line["price"], final_grams=line["final_grams"],
                                        item_snapshot=snapshot)

    # The ledger -------------------------------------------------------------
    for row in snap["cashEntries"]:
        if not is_new("cashEntries", row["id"]):
            continue
        if row["pair"] and not RecordId.objects.filter(pk=row["pair"]).exists():
            RecordId.objects.create(id=row["pair"], kind="transferPair")
        CashEntry.objects.create(
            id=row["id"], branch_id=row["branch"], type=row["type"], account=row["account"],
            amount_centavos=row["amount"], note=row["note"], category=row["category"], date=row["date"],
            recorded_by_role=row["recorded_by_role"], recorded_by_id=user_ref(row["recorded_by"], f"Cash entry {row['id']}"),
            source_type=row["source"], linked_record_id=row["linked"], transfer_pair_id=row["pair"],
        )

    # Receipts ---------------------------------------------------------------
    for row in snap["receipts"]:
        if StoredReceipt.objects.filter(record_id=row["record_id"]).exists():
            report.skipped["receipts"] += 1
            continue
        if not is_new("receipts", row["id"]):
            continue
        receipt = StoredReceipt(id=row["id"], record_id=row["record_id"], kind=row["kind"], branch_id=row["branch"],
                                counterparty=row["counterparty"], total_centavos=row["total"],
                                issued_at=row["issued_at"], text=row["text"])
        if write_files:
            receipt.pdf.save(f"{row['kind']}-{row['record_id']}.pdf", ContentFile(row["bytes"]), save=False)
        receipt.save()

    # The log, exactly as it was ------------------------------------------------
    for row in snap["logs"]:
        if not is_new("logs", row["id"]):
            continue
        TransactionLog.objects.create(
            id=row["id"], at=row["at"], received_at=ctx.received_at, action=row["action"],
            category=category_for(row["action"]), user_id=user_ref(row["user_id"], f"Log {row['id']}"),
            user_name=row["user_name"], role=row["role"], summary=row["summary"], branch_id=row["branch"],
            record_id=row["record_id"], record_kind=row["record_kind"], amount_centavos=row["amount"],
            changes=row["changes"],
        )

    # A cart lives only while the app is open: a piece reserved that no open
    # order holds goes back on sale — what the app itself does on every load.
    open_lines = SaleLineItem.objects.exclude(sale__verification_status=VerificationStatus.VERIFIED)
    held_items = set(open_lines.values_list("item_id", flat=True))
    for row in snap["items"]:
        if row["status"] == ItemStatus.RESERVED and row["id"] not in held_items and row["id"] not in held:
            item = Item.objects.get(pk=row["id"])
            item.item_status = ItemStatus.LISTED
            item.save()
            report.warn(f"Item {item.id} was held by an unfinished cart and is back on sale")

    made = sum(report.created.values())
    summary = (f"Imported phone data: {made} record(s) created, {sum(report.skipped.values())} already on the server"
               f" ({report.created['items']} item(s), {report.created['purchaseBatches']} purchase(s), "
               f"{report.created['sales']} sale(s), {report.created['cashEntries']} cash entr(ies))")
    write_log(ctx, LogAction.SNAPSHOT_IMPORTED, summary,
              changes=[{"field": k, "before": str(report.skipped[k]), "after": str(report.created[k])}
                       for k in SECTIONS if report.created[k] or report.skipped[k]])
    return report.as_dict(dry_run)
