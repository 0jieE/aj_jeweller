"""The phone's own file format — SnapshotCodec in snapshot_codec.dart.

Writing records in exactly the shape the app reads means the phone can take
server data with the parser it already has: a full snapshot to start from
(GET /sync/snapshot) and the records changed since its last pull
(GET /sync/changes).

Two details of the codec decide the encoding:

* Dates are local wall-clock times with no offset — what Dart's
  `toIso8601String()` writes for a local DateTime — so they are written in
  Manila time without an offset.
* Enums are parsed with `values.byName`, which throws on a name it does not
  know. Log rows whose action is server-only are therefore left out
  (enums.PHONE_ACTIONS); they remain on the server's own log.
"""

import base64
from datetime import date, datetime, time
from decimal import Decimal

from django.utils import timezone

from .enums import PHONE_ACTIONS

SNAPSHOT_VERSION = 1


def dt(value: datetime | None) -> str | None:
    if value is None:
        return None
    local = timezone.localtime(value) if timezone.is_aware(value) else value
    return local.replace(tzinfo=None).isoformat(timespec="microseconds")


def day(value: date | None) -> str | None:
    """A day as the app stores it: midnight local time."""
    return None if value is None else datetime.combine(value, time.min).isoformat(timespec="microseconds")


def num(value: Decimal | None) -> float | None:
    return None if value is None else float(value)


def b64(field, include: bool) -> str | None:
    if not include or not field:
        return None
    try:
        with field.open("rb") as handle:
            return base64.b64encode(handle.read()).decode()
    except (FileNotFoundError, OSError):
        return None


# --- one record each --------------------------------------------------------

def user_json(u) -> dict:
    return {"id": u.id, "name": u.name, "role": u.role, "homeBranch": u.home_branch,
            "contact": u.contact_number, "active": u.active}


def branch_json(b) -> dict:
    # silverValue is carried by the app's Branch model but read nowhere; the
    # server stores no money figure besides the three opening balances.
    return {"id": b.id, "startingCash": b.starting_purchase_cash_centavos,
            "startingSalesCash": b.starting_sales_cash_centavos, "startingBank": b.starting_bank_centavos,
            "silverValue": 0}


def gold_rate_json(r) -> dict:
    return {"karat": r.karat, "price": r.price_per_gram_centavos, "updatedAt": dt(r.updated_at)}


def rate_change_json(c) -> dict:
    return {"karat": c.karat, "before": c.before_centavos, "after": c.after_centavos, "at": dt(c.at),
            "userId": c.user_id or "", "userName": c.user_name, "restoredFrom": day(c.restored_from)}


def item_json(i, photos: bool = True) -> dict:
    return {
        "id": i.id, "description": i.description, "weight": num(i.weight_grams), "gross": num(i.gross_weight_grams),
        "karat": i.karat, "type": i.type, "capital": i.capital_amount_centavos, "origin": i.origin,
        "branch": i.branch_id, "status": i.item_status, "verification": i.verification_status,
        "purchaseDate": dt(i.purchase_date), "submittedByRole": i.submitted_by_role, "photo": b64(i.photo, photos),
        "encodedBy": i.encoded_by_id, "batchId": i.batch_id, "verificationNote": i.verification_note,
        "parentLotId": i.parent_lot_id, "originalGrams": num(i.original_grams),
        "originalAmount": i.original_amount_centavos, "remainingGrams": num(i.remaining_grams),
        "remainingAmount": i.remaining_amount_centavos,
    }


def customer_details_json(record) -> dict:
    return {"name": record.customer_name, "contact": record.customer_contact_number,
            "address": record.customer_address, "customerId": record.customer_id}


def customer_json(c, photos: bool = True) -> dict:
    return {"id": c.id, "name": c.name, "contact": c.contact_number, "address": c.address,
            "firstSeen": dt(c.first_seen), "photo": b64(c.photo, photos)}


def purchase_batch_json(b, photos: bool = True) -> dict:
    return {"id": b.id, "customer": customer_details_json(b), "branch": b.branch_id, "date": dt(b.date),
            "submittedByRole": b.submitted_by_role, "verification": b.verification_status,
            "verificationNote": b.verification_note, "releasedAt": dt(b.released_at),
            "submittedBy": b.submitted_by_id, "releasedBy": b.released_by_id,
            "releaseProofPhoto": b64(b.release_proof_photo, photos)}


def sale_line_item_json(line, photos: bool = True) -> dict:
    """A completed sale keeps the piece as it was sold; an open one shows it as it is."""
    if not line.sale.is_open and line.item_snapshot:
        item = dict(line.item_snapshot)
        if not photos:
            item["photo"] = None
    else:
        item = item_json(line.item, photos)
    return {"item": item, "price": line.negotiated_price_centavos, "finalGrams": num(line.final_grams)}


def sale_json(s, photos: bool = True) -> dict:
    lines = s.lines.select_related("item", "sale").order_by("position")
    return {"id": s.id, "lines": [sale_line_item_json(line, photos) for line in lines],
            "customer": customer_details_json(s), "note": s.note, "cash": s.cash_centavos, "bank": s.bank_centavos,
            "verification": s.verification_status, "verificationNote": s.verification_note, "branch": s.branch_id,
            "date": dt(s.date), "submittedByRole": s.submitted_by_role, "submittedBy": s.submitted_by_id,
            "receivedBy": s.received_by_id}


def commitment_json(c, photos: bool = True) -> dict:
    return {"id": c.id, "lender": c.lender, "amount": c.amount_centavos, "rate": c.rate_per_gram_centavos,
            "branch": c.branch_id, "approved": dt(c.date_approved), "received": dt(c.date_received),
            "proofPhoto": b64(c.received_proof_photo, photos)}


def disposal_json(d, photos: bool = True) -> dict:
    return {"id": d.id, "branch": d.branch_id,
            "itemIds": list(d.links.order_by("position").values_list("item_id", flat=True)),
            "capital": d.capital_centavos, "grossGrams": num(d.gross_grams), "grossAmount": d.gross_amount_centavos,
            "commitmentRef": d.commitment_id, "date": dt(d.date), "photo": b64(d.photo, photos)}


def cash_entry_json(e) -> dict:
    return {"id": e.id, "branch": e.branch_id, "type": e.type, "account": e.account, "amount": e.amount_centavos,
            "note": e.note, "category": e.category, "date": dt(e.date), "recordedByRole": e.recorded_by_role,
            "recordedBy": e.recorded_by_id, "source": e.source_type, "linkedRecordId": e.linked_record_id,
            "transferPairId": e.transfer_pair_id}


def receipt_json(r, photos: bool = True) -> dict:
    # `bytes` is required by the app's parser, so the PDF always travels.
    return {"id": r.id, "recordId": r.record_id, "kind": r.kind, "branch": r.branch_id,
            "counterparty": r.counterparty, "total": r.total_centavos, "issuedAt": dt(r.issued_at),
            "bytes": b64(r.pdf, True) or "", "text": r.text}


def log_json(log) -> dict | None:
    if log.action not in PHONE_ACTIONS:
        return None
    return {"id": log.id, "at": dt(log.at), "action": log.action, "userId": log.user_id, "userName": log.user_name,
            "role": log.role, "summary": log.summary, "branch": log.branch_id, "recordId": log.record_id,
            "recordKind": log.record_kind, "amount": log.amount_centavos, "changes": log.changes or []}
