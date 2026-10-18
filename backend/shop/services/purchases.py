"""Buying gold: one customer visit, verified and paid once.

An Appraiser records the visit — the customer and every piece — and no cash
moves. A Cashier then checks the pieces and releases the cash for the whole
batch in one movement out of Purchase Cash (one ledger entry, not one per
piece), or returns it for correction.
"""

from dataclasses import dataclass, field
from decimal import Decimal

from django.core.files.base import ContentFile

from notifications import events as notify

from ..enums import (
    CashAccount,
    CashEntrySourceType,
    CashEntryType,
    ItemStatus,
    ItemType,
    LogAction,
    LogRecordKind,
    VerificationStatus,
    is_silver_purity,
)
from ..errors import NotFound, Refusal
from ..ids import claim
from ..models import Item, PurchaseBatch
from ..text import peso
from . import cash
from .base import (
    ENCODE_PURCHASES,
    MOVE_CASH,
    Ctx,
    blank_to_none,
    branch_for_write,
    require_branch,
    require_role,
    write_log,
)
from .customers import CustomerDetails, file_on_transaction

ZERO = Decimal("0")


def check_purity(item_type: str, karat: int) -> None:
    """Silver takes a fineness, gold a karat — a 925 "goods" ring or an 18K
    "silver" chain would be priced from the wrong table."""
    silver = item_type == ItemType.SILVER
    if silver != is_silver_purity(karat):
        raise Refusal(
            "A silver piece needs a silver purity (e.g. 925), not a gold karat" if silver
            else "A gold piece needs a karat, not a silver purity",
            code="purity_mismatch",
        )
    if silver and not 100 <= karat <= 999:
        raise Refusal("Silver fineness is 100 to 999 (e.g. 925)", code="purity_out_of_range")
    if not silver and not 1 <= karat <= 24:
        raise Refusal("Gold karat is 1 to 24", code="purity_out_of_range")


def check_figures(description: str, weight: Decimal, gross: Decimal | None, amount: int) -> None:
    if not description or not description.strip():
        raise Refusal("An item needs a description", code="description_required")
    if weight is None or amount is None or weight <= 0 or amount <= 0:
        raise Refusal("Weight and amount must both be above zero", code="figures_not_positive")
    if gross is not None and gross < weight:
        raise Refusal("The original weight cannot be less than the final weight", code="gross_below_net")


def post_verification_status(item_type: str) -> str:
    """Scrap goes to the disposal pool; goods and silver go on the shelf."""
    return ItemStatus.FOR_DISPOSAL if item_type == ItemType.SCRAP else ItemStatus.LISTED


@dataclass
class DraftLine:
    description: str
    weight_grams: Decimal
    karat: int
    type: str
    amount_centavos: int
    gross_weight_grams: Decimal | None = None
    photo: ContentFile | None = None
    item_id: str | None = None

    @classmethod
    def from_input(cls, data: dict) -> "DraftLine":
        return cls(
            description=(data.get("description") or "").strip(),
            weight_grams=data.get("weight_grams"),
            gross_weight_grams=data.get("gross_weight_grams"),
            karat=data.get("karat"),
            type=data.get("type"),
            amount_centavos=data.get("amount_centavos"),
            photo=data.get("photo"),
            item_id=data.get("id") or None,
        )


@dataclass
class BatchInput:
    customer: CustomerDetails
    lines: list[DraftLine] = field(default_factory=list)
    branch_id: str | None = None
    date: object = None
    batch_id: str | None = None


def get_batch(batch_id: str) -> PurchaseBatch:
    try:
        return PurchaseBatch.objects.select_related("branch").get(pk=batch_id)
    except PurchaseBatch.DoesNotExist:
        raise NotFound("Purchase not found") from None


def lines_of(batch: PurchaseBatch) -> list[Item]:
    """The pieces the customer handed over, in the order entered. Partitions
    inherit their lot's batch but were never part of the visit."""
    return list(batch.items.filter(parent_lot__isnull=True).order_by("line_no", "id"))


def batch_total(batch: PurchaseBatch) -> int:
    """What the customer is owed for the whole visit — each lot's original
    amount, since a lot partitioned later was paid for in full."""
    return sum(item.effective_original_amount for item in lines_of(batch))


def record_batch(ctx: Ctx, data: BatchInput) -> PurchaseBatch:
    """Records a whole counter visit. Cash has NOT moved: the batch waits,
    awaitingVerification, for a Cashier."""
    require_role(ctx, ENCODE_PURCHASES, "encode purchases")
    branch = branch_for_write(ctx, data.branch_id)
    if not data.lines:
        raise Refusal("A purchase needs at least one item", code="no_items")
    for line in data.lines:
        check_purity(line.type, line.karat)
        gross = line.gross_weight_grams if line.gross_weight_grams is not None else line.weight_grams
        check_figures(line.description, line.weight_grams, gross, line.amount_centavos)

    when = data.date or ctx.now
    customer = file_on_transaction(ctx, data.customer)
    batch = PurchaseBatch.objects.create(
        id=claim(data.batch_id, "purchaseBatch"),
        # The customer exactly as given on this visit — the receipt's copy.
        customer_name=data.customer.name,
        customer_contact_number=blank_to_none(data.customer.contact_number),
        customer_address=blank_to_none(data.customer.address),
        customer=customer,
        branch=branch,
        date=when,
        submitted_by_role=ctx.actor.role,
        submitted_by=ctx.actor,
        verification_status=VerificationStatus.AWAITING,
    )
    for number, line in enumerate(data.lines, start=1):
        item = Item(
            id=claim(line.item_id, "item"),
            description=line.description,
            weight_grams=line.weight_grams,
            gross_weight_grams=line.gross_weight_grams if line.gross_weight_grams is not None else line.weight_grams,
            karat=line.karat,
            type=line.type,
            capital_amount_centavos=line.amount_centavos,
            origin=data.customer.name,
            branch=branch,
            item_status=ItemStatus.PENDING,
            verification_status=VerificationStatus.AWAITING,
            purchase_date=when,
            submitted_by_role=ctx.actor.role,
            encoded_by=ctx.actor,
            batch=batch,
            line_no=number,
        )
        if line.photo is not None:
            item.photo.save(line.photo.name, line.photo, save=False)
        item.save()

    total = sum(line.amount_centavos for line in data.lines)
    write_log(
        ctx, LogAction.PURCHASE_RECORDED,
        f"Recorded {len(data.lines)} item(s) from {data.customer.name} for {peso(total)}",
        branch=branch.id, record_id=batch.id, record_kind=LogRecordKind.PURCHASE_BATCH, amount_centavos=total,
    )
    notify.purchase_awaiting_release(ctx, batch, item_count=len(data.lines), total_centavos=total)
    return batch


def release(ctx: Ctx, batch_id: str, proof_photo: ContentFile | None, cash_entry_id: str | None = None):
    """Cashier: confirms the whole batch against the pieces and pays the
    customer once, out of Purchase Cash. Returns (batch, cash entry)."""
    require_role(ctx, MOVE_CASH, "release cash")
    batch = get_batch(batch_id)
    require_branch(ctx, batch.branch_id)
    if batch.verification_status == VerificationStatus.VERIFIED:
        raise Refusal("Cash for this purchase was already released", code="already_released")
    if batch.verification_status == VerificationStatus.RETURNED:
        raise Refusal("This purchase was returned for correction — it can be released once it is resubmitted",
                      code="returned_for_correction")
    if proof_photo is None:
        raise Refusal("A photo of the cash being handed over is required to release it",
                      code="proof_photo_required")
    lines = lines_of(batch)
    if not lines:
        raise Refusal("A purchase needs at least one item", code="no_items")

    for item in lines:
        item.item_status = post_verification_status(item.type)
        item.verification_status = VerificationStatus.VERIFIED
        item.verification_note = None
        item.save()

    total = sum(item.effective_original_amount for item in lines)
    batch.verification_status = VerificationStatus.VERIFIED
    batch.verification_note = None
    batch.released_at = ctx.now
    batch.released_by = ctx.actor
    batch.release_proof_photo.save(proof_photo.name, proof_photo, save=False)
    batch.save()

    entry = cash.write_entry(
        ctx,
        branch_id=batch.branch_id,
        type=CashEntryType.EXPENSE,
        account=CashAccount.PURCHASE,
        amount_centavos=total,
        note=f"Purchase released - {batch.customer_name} ({len(lines)} item(s))",
        category="Purchase",
        source_type=CashEntrySourceType.PURCHASE,
        linked_record_id=batch.id,
        entry_id=cash_entry_id,
    )
    write_log(
        ctx, LogAction.CASH_RELEASED,
        f"Released {peso(total)} to {batch.customer_name} for {len(lines)} item(s)",
        branch=batch.branch_id, record_id=batch.id, record_kind=LogRecordKind.PURCHASE_BATCH, amount_centavos=total,
    )
    return batch, entry


def return_for_correction(ctx: Ctx, batch_id: str, note: str) -> PurchaseBatch:
    """Cashier: sends the whole batch back to the encoder with a note instead
    of releasing cash. Moves no cash."""
    require_role(ctx, MOVE_CASH, "return a purchase for correction")
    batch = get_batch(batch_id)
    require_branch(ctx, batch.branch_id)
    note = (note or "").strip()
    if not note:
        raise Refusal("Say what needs to be fixed — the note goes back to the Appraiser", code="note_required")
    if batch.verification_status != VerificationStatus.AWAITING:
        raise Refusal("Only a purchase waiting on cash release can be returned for correction",
                      code="not_awaiting")
    batch.verification_status = VerificationStatus.RETURNED
    batch.verification_note = note
    batch.save()
    for item in lines_of(batch):
        item.verification_status = VerificationStatus.RETURNED
        item.verification_note = note
        item.save()
    write_log(
        ctx, LogAction.PURCHASE_RETURNED,
        f"Returned the purchase from {batch.customer_name} for correction: {note}",
        branch=batch.branch_id, record_id=batch.id, record_kind=LogRecordKind.PURCHASE_BATCH,
    )
    notify.purchase_returned(ctx, batch, note)
    return batch


def _apply_resubmitted_line(item: Item, line: dict) -> list[dict]:
    from .items import diff_item, snapshot_figures

    before = snapshot_figures(item)
    new_type = line.get("type", item.type)
    new_karat = line.get("karat", item.karat)
    new_weight = line.get("weight_grams", item.weight_grams)
    if "gross_weight_grams" in line:
        new_gross = line["gross_weight_grams"]
    elif item.gross_weight_grams is not None and item.gross_weight_grams == item.weight_grams:
        new_gross = new_weight  # nothing was deducted: gross and net are one reading
    else:
        new_gross = item.gross_weight_grams
    new_amount = line.get("amount_centavos", item.capital_amount_centavos)
    new_description = (line.get("description", item.description) or "").strip()
    check_purity(new_type, new_karat)
    check_figures(new_description, new_weight, new_gross, new_amount)

    item.description = new_description
    item.type = new_type
    item.karat = new_karat
    item.weight_grams = new_weight
    item.gross_weight_grams = new_gross
    item.capital_amount_centavos = new_amount
    item.item_status = ItemStatus.PENDING
    item.verification_status = VerificationStatus.AWAITING
    item.verification_note = None
    if line.get("photo") is not None:
        item.photo.save(line["photo"].name, line["photo"], save=False)
    item.save()
    return diff_item(before, snapshot_figures(item))


def resubmit(ctx: Ctx, batch_id: str, lines: list[dict]) -> PurchaseBatch:
    """Appraiser: re-encodes the pieces a Cashier returned and puts the batch
    back in the Cashier's queue. Lines not sent are resubmitted unchanged."""
    require_role(ctx, ENCODE_PURCHASES, "correct and resubmit purchases")
    batch = get_batch(batch_id)
    require_branch(ctx, batch.branch_id)
    if batch.verification_status != VerificationStatus.RETURNED:
        raise Refusal("Only a purchase returned for correction can be resubmitted", code="not_returned")
    pieces = {item.id: item for item in lines_of(batch)}
    by_id = {}
    for line in lines:
        item_id = line.get("id")
        if item_id not in pieces:
            raise Refusal(f"Item {item_id} is not part of purchase {batch.id}", code="not_in_batch")
        by_id[item_id] = line

    changes: list[dict] = []
    for item_id, item in pieces.items():
        line_changes = _apply_resubmitted_line(item, by_id.get(item_id, {}))
        changes.extend({**c, "field": f"{item.id} {c['field']}"} if len(pieces) > 1 else c for c in line_changes)

    batch.verification_status = VerificationStatus.AWAITING
    batch.verification_note = None
    batch.save()
    corrected = [pieces[i].description for i in by_id] or [p.description for p in pieces.values()]
    quoted = ", ".join('"' + d + '"' for d in corrected)
    write_log(
        ctx, LogAction.PURCHASE_RESUBMITTED,
        f"Corrected {quoted} and sent the purchase back to the Cashier",
        branch=batch.branch_id, record_id=batch.id, record_kind=LogRecordKind.PURCHASE_BATCH,
        amount_centavos=batch_total(batch), changes=changes,
    )
    _back_in_queue(ctx, batch)
    return batch


def resubmit_item(ctx: Ctx, item_id: str, line: dict) -> PurchaseBatch:
    """The app's per-piece resubmit: fixing one piece puts the whole batch back
    in the Cashier's queue."""
    item = Item.objects.filter(pk=item_id).first()
    if item is None:
        raise NotFound("Item not found")
    if item.batch_id is None or item.is_partition:
        raise Refusal("Only a piece from a purchase can be resubmitted", code="not_in_batch")
    require_role(ctx, ENCODE_PURCHASES, "correct and resubmit purchases")
    batch = get_batch(item.batch_id)
    require_branch(ctx, batch.branch_id)
    if item.verification_status != VerificationStatus.RETURNED and batch.verification_status != VerificationStatus.RETURNED:
        raise Refusal("Only an item returned for correction can be resubmitted", code="not_returned")
    changes = _apply_resubmitted_line(item, line)
    batch.verification_status = VerificationStatus.AWAITING
    batch.verification_note = None
    batch.save()
    write_log(
        ctx, LogAction.PURCHASE_RESUBMITTED,
        f'Corrected "{item.description}" and sent the purchase back to the Cashier',
        branch=batch.branch_id, record_id=batch.id, record_kind=LogRecordKind.PURCHASE_BATCH,
        amount_centavos=item.capital_amount_centavos, changes=changes,
    )
    _back_in_queue(ctx, batch)
    return batch


def _back_in_queue(ctx: Ctx, batch: PurchaseBatch) -> None:
    """A resubmitted purchase is waiting on the Cashier again."""
    notify.purchase_awaiting_release(ctx, batch, item_count=len(lines_of(batch)), total_centavos=batch_total(batch))
