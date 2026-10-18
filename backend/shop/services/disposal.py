"""Disposal: scrap (or silver) sold off in bulk to settle a loan.

Scrap only ever leaves the shop to pay down a commitment, so every batch names
one. Completing a batch marks each piece disposed and moves no cash: the gross,
entered by hand from the settlement, pays down the commitment.
"""

from collections import defaultdict
from decimal import Decimal

from django.core.files.base import ContentFile

from notifications import events as notify

from ..enums import CommitmentStatus, ItemStatus, ItemType, LogAction, LogRecordKind, VerificationStatus
from ..errors import Refusal
from ..ids import claim
from ..models import Commitment, DisposalBatch, DisposalItem, Item
from ..text import fixed3, peso
from .base import ADMIN_ONLY, Ctx, branch_for_write, require_role, write_log
from .commitments import ledger


def pool(branch_id: str | None, *, silver: bool = False):
    """Gold scrap waiting on a batch — or, with `silver`, silver stock on hand,
    which can be disposed of or sold, whichever happens first."""
    queryset = Item.objects.all()
    if branch_id:
        queryset = queryset.filter(branch_id=branch_id)
    if silver:
        queryset = queryset.filter(type=ItemType.SILVER, item_status=ItemStatus.LISTED,
                                   verification_status=VerificationStatus.VERIFIED)
    else:
        queryset = queryset.filter(item_status=ItemStatus.FOR_DISPOSAL)
    # A fully drawn-down lot has nothing left to dispose of.
    return [item for item in queryset.order_by("-purchase_date") if item.effective_remaining_grams > 0]


def _in_pool(item: Item, silver: bool) -> bool:
    if item.effective_remaining_grams <= 0:
        return False
    if silver:
        return (item.type == ItemType.SILVER and item.item_status == ItemStatus.LISTED
                and item.verification_status == VerificationStatus.VERIFIED)
    return item.item_status == ItemStatus.FOR_DISPOSAL


def karat_breakdown(batch: DisposalBatch) -> list[tuple[int, Decimal]]:
    """Grams per purity, highest first. 93g of 21K and 93g of 10K are different
    deliveries. Derived from the pieces, so it can never disagree with them."""
    grams = defaultdict(Decimal)
    for item in batch.ordered_items():
        # Disposal takes the whole remaining lot, which is what was weighed in.
        grams[item.karat] += item.effective_remaining_grams
    return sorted(grams.items(), key=lambda kv: kv[0], reverse=True)


def complete(ctx: Ctx, *, branch_id: str | None, item_ids: list[str], gross_grams: Decimal,
             gross_amount_centavos: int, commitment_id: str, capital_centavos: int | None = None, date=None,
             photo: ContentFile | None = None, batch_id: str | None = None) -> DisposalBatch:
    require_role(ctx, ADMIN_ONLY, "run disposal")
    branch = branch_for_write(ctx, branch_id)
    if not item_ids:
        raise Refusal("Pick at least one piece to dispose of", code="no_items")
    if len(set(item_ids)) != len(item_ids):
        raise Refusal("The same piece is in the batch twice", code="duplicate_item")
    commitment = Commitment.objects.filter(pk=commitment_id).first() if commitment_id else None
    if commitment is None:
        raise Refusal("Pick the commitment this batch settles to continue.", code="commitment_required")
    if commitment.branch_id is not None and commitment.branch_id != branch.id:
        raise Refusal(f"That loan belongs to {commitment.branch.label}, not {branch.label}", code="commitment_branch")
    loan = ledger(commitment)
    if commitment.date_received is None or loan.remaining_centavos <= 0:
        raise Refusal("Only a received loan with a balance left to pay can take a disposal batch",
                      code="commitment_not_open")

    items = []
    for item_id in item_ids:
        item = Item.objects.select_for_update().filter(pk=item_id).first()
        if item is None:
            raise Refusal(f"Item {item_id} does not exist", code="unknown_item")
        if item.branch_id != branch.id:
            raise Refusal(f'"{item.description}" belongs to {item.branch.label}', code="wrong_branch")
        items.append(item)
    silver = items[0].type == ItemType.SILVER
    if any((i.type == ItemType.SILVER) != silver for i in items):
        raise Refusal("A batch is all gold scrap or all silver — not both", code="mixed_metal")
    for item in items:
        if not _in_pool(item, silver):
            raise Refusal(f'"{item.description}" is not in the disposal pool', code="not_in_pool")

    expected_capital = sum(i.effective_remaining_amount for i in items)
    if capital_centavos is not None and capital_centavos != expected_capital:
        raise Refusal(f"Capital does not match the selected pieces ({peso(expected_capital)})",
                      code="capital_mismatch", expected_centavos=expected_capital)
    if gross_grams is None or gross_amount_centavos is None or gross_grams <= 0 or gross_amount_centavos <= 0:
        raise Refusal("Enter the gross weight and amount from the settlement", code="gross_required")

    batch = DisposalBatch(
        id=claim(batch_id, "disposal"), branch=branch, capital_centavos=expected_capital, gross_grams=gross_grams,
        gross_amount_centavos=gross_amount_centavos, commitment=commitment, date=date or ctx.now,
    )
    if photo is not None:
        batch.photo.save(photo.name, photo, save=False)
    batch.save()
    for position, item in enumerate(items):
        DisposalItem.objects.create(batch=batch, item=item, position=position)
        item.item_status = ItemStatus.DISPOSED
        item.save()
    write_log(
        ctx, LogAction.DISPOSAL_COMPLETED,
        f"Disposed {len(items)} item(s), {fixed3(gross_grams)}g, for {peso(gross_amount_centavos)} "
        f"applied to {commitment.lender}",
        branch=branch.id, record_id=batch.id, record_kind=LogRecordKind.DISPOSAL, amount_centavos=gross_amount_centavos,
    )
    # The loan was open before this batch (checked above); if this batch
    # covered what was left, it has just been cleared.
    if ledger(commitment).status == CommitmentStatus.LOAN_PAID:
        notify.commitment_cleared(ctx, commitment)
    return batch
