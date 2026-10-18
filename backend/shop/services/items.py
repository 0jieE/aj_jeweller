"""Pieces of metal: admin corrections, photos, and lot partitions.

A correction never moves cash — even on a purchase already paid. When the
amount of a paid purchase changes, the log says so; if money actually changed
hands to settle it, that is a cash entry of its own.

A partition draws grams and amount out of a lot. It can never draw more than
remains, inherits the lot's karat and metal, and returning it gives both back
exactly.
"""

from decimal import Decimal

from django.core.files.base import ContentFile

from ..enums import ItemStatus, ItemType, LogAction, LogRecordKind, VerificationStatus
from ..errors import NotFound, Refusal
from ..ids import claim
from ..models import Item
from ..text import fixed3, grams, karat_text, peso
from .base import BRANCH_MANAGERS, ENCODE_PURCHASES, Ctx, change, require_branch, require_role, write_log
from .purchases import check_figures, check_purity, post_verification_status

ZERO = Decimal("0")
_UNSET = object()


def get_item(item_id: str, *, lock: bool = False) -> Item:
    queryset = Item.objects.select_for_update() if lock else Item.objects
    try:
        return queryset.get(pk=item_id)
    except Item.DoesNotExist:
        raise NotFound("Item not found") from None


# --- describing a change -----------------------------------------------------

def snapshot_figures(item: Item) -> dict:
    """The figures an edit form shows. For a partitioned lot, weight and
    amount are its *original* figures — what was actually bought."""
    return {
        "description": item.description,
        "type": item.type,
        "karat": item.karat,
        "weight": item.effective_original_grams if item.has_partitions else item.weight_grams,
        "gross": item.gross_weight_grams,
        "amount": item.effective_original_amount if item.has_partitions else item.capital_amount_centavos,
        "has_partitions": item.has_partitions,
    }


def diff_item(before: dict, after: dict) -> list[dict]:
    """Field-by-field differences, in the words the edit form uses."""
    changes = []
    if before["description"] != after["description"]:
        changes.append(change("Description", before["description"], after["description"]))
    if before["type"] != after["type"]:
        changes.append(change("Type", ItemType(before["type"]).label, ItemType(after["type"]).label))
    if before["karat"] != after["karat"]:
        changes.append(change("Karat", karat_text(before["karat"]), karat_text(after["karat"])))
    if Decimal(before["weight"]) != Decimal(after["weight"]):
        changes.append(change("Original final weight" if before["has_partitions"] else "Final weight",
                              f"{fixed3(before['weight'])}g", f"{fixed3(after['weight'])}g"))
    if before["gross"] != after["gross"]:
        changes.append(change("Original weight",
                              "—" if before["gross"] is None else f"{fixed3(before['gross'])}g",
                              "—" if after["gross"] is None else f"{fixed3(after['gross'])}g"))
    if before["amount"] != after["amount"]:
        changes.append(change("Original amount" if before["has_partitions"] else "Amount",
                              peso(before["amount"]), peso(after["amount"])))
    return changes


def _remaining_text(item: Item) -> str:
    return f"{fixed3(item.effective_remaining_grams)}g · {peso(item.effective_remaining_amount)}"


# --- admin correction --------------------------------------------------------

def can_edit(item: Item) -> bool:
    """Sold and disposed pieces are written into other records already, and a
    reserved one is held in an open order — correct those records instead."""
    return item.item_status not in (ItemStatus.SOLD, ItemStatus.DISPOSED, ItemStatus.RESERVED)


def correct(ctx: Ctx, item_id: str, *, description=_UNSET, type=_UNSET, karat=_UNSET, weight_grams=_UNSET,
            gross_weight_grams=_UNSET, amount_centavos=_UNSET) -> tuple[Item, list[dict], str]:
    """Admin (or the branch's Supervisor) correction of an item's recorded details.

    Returns (item, changes, cash_note). `changes` is empty — and nothing is
    written — when nothing changed.
    """
    require_role(ctx, BRANCH_MANAGERS, "correct records")
    old = get_item(item_id, lock=True)
    require_branch(ctx, old.branch_id)  # a Supervisor corrects their own branch's records
    if not can_edit(old):
        raise Refusal(f"A {ItemStatus(old.item_status).label.lower()} item can no longer be edited",
                      code="item_locked")
    before = snapshot_figures(old)

    new_description = (old.description if description is _UNSET else (description or "")).strip()
    new_type = old.type if type is _UNSET else type
    new_karat = old.karat if karat is _UNSET else karat
    old_weight, old_amount = before["weight"], before["amount"]
    new_weight = old_weight if weight_grams is _UNSET else weight_grams
    new_amount = old_amount if amount_centavos is _UNSET else amount_centavos
    # With nothing deducted, gross and net are one reading, so a corrected net
    # carries the gross with it; with a real deduction the gross stays as
    # weighed unless it is corrected too.
    nothing_deducted = old.gross_weight_grams is not None and old.gross_weight_grams == old_weight
    if gross_weight_grams is not _UNSET:
        new_gross = gross_weight_grams
    else:
        new_gross = new_weight if nothing_deducted else old.gross_weight_grams

    check_figures(new_description, new_weight, new_gross, new_amount)
    if old.is_partition and new_karat != old.karat:
        raise Refusal("A partition takes its karat from its lot — change it on the lot", code="partition_karat")
    check_purity(new_type, new_karat)
    if old.has_partitions and (new_type == ItemType.SILVER) != (old.type == ItemType.SILVER):
        raise Refusal("A lot with partitions cannot change metal — its pieces are already drawn",
                      code="lot_metal_fixed")

    d_grams = new_weight - old_weight
    d_amount = new_amount - old_amount

    # Status follows type once the piece is in stock.
    status = old.item_status
    if new_type != old.type and old.verification_status == VerificationStatus.VERIFIED:
        status = post_verification_status(new_type)

    # A partition takes its change from (or hands it back to) its lot.
    parent = None
    parent_before = None
    if old.is_partition and (d_grams != 0 or d_amount != 0):
        parent = get_item(old.parent_lot_id, lock=True)
        parent_before = _remaining_text(parent)
        remaining_grams = parent.effective_remaining_grams - d_grams
        remaining_amount = parent.effective_remaining_amount - d_amount
        if remaining_grams < 0 or remaining_amount < 0:
            raise Refusal(
                f"Lot {parent.id} only has {fixed3(parent.effective_remaining_grams)}g "
                f"and {peso(parent.effective_remaining_amount)} left to give",
                code="lot_overdrawn",
            )
        parent.original_grams = parent.effective_original_grams
        parent.original_amount_centavos = parent.effective_original_amount
        parent.remaining_grams = remaining_grams
        parent.remaining_amount_centavos = remaining_amount

    old_karat = old.karat
    if old.has_partitions:
        # A partitioned lot keeps what has been drawn; the change lands on the remainder.
        remaining_grams = old.effective_remaining_grams + d_grams
        remaining_amount = old.effective_remaining_amount + d_amount
        if remaining_grams < 0 or remaining_amount < 0:
            raise Refusal("More than that has already been drawn out of this lot into partitions",
                          code="lot_overdrawn")
        old.weight_grams = old.weight_grams + d_grams
        old.capital_amount_centavos = old.capital_amount_centavos + d_amount
        old.original_grams = new_weight
        old.original_amount_centavos = new_amount
        old.remaining_grams = remaining_grams
        old.remaining_amount_centavos = remaining_amount
    else:
        old.weight_grams = new_weight
        old.capital_amount_centavos = new_amount
    old.description = new_description
    old.type = new_type
    old.karat = new_karat
    old.item_status = status
    old.gross_weight_grams = new_gross

    changes = diff_item(before, {**snapshot_figures(old), "has_partitions": before["has_partitions"]})
    if not changes:
        return get_item(item_id), [], ""
    old.save()

    if parent is not None:
        parent.save()
        changes.append(change(f"Lot {parent.id} remaining", parent_before, _remaining_text(parent)))

    # A lot's karat is every piece's karat.
    if before["has_partitions"] and new_karat != old_karat:
        for piece in Item.objects.filter(parent_lot_id=old.id):
            piece.karat = new_karat
            piece.save()
        changes.append(change("Partitions", karat_text(old_karat),
                              f"{karat_text(new_karat)} (carried to every piece drawn from this lot)"))

    # Flag, never fabricate, a difference against cash already paid out.
    paid = (not old.is_partition and old.batch_id is not None
            and old.batch.verification_status == VerificationStatus.VERIFIED)
    cash_note = ""
    if paid and d_amount != 0:
        cash_note = (f" Cash was already released for this purchase; the {peso(abs(d_amount))} "
                     f"{'increase' if d_amount > 0 else 'decrease'} was not moved in the ledger.")
    write_log(
        ctx, LogAction.ITEM_EDITED, f'Corrected "{old.description}".{cash_note}',
        branch=old.branch_id, record_id=old.id, record_kind=LogRecordKind.ITEM,
        amount_centavos=new_amount if d_amount != 0 else None, changes=changes,
    )
    return old, changes, cash_note.strip()


# --- photos ------------------------------------------------------------------

def set_photo(ctx: Ctx, item_id: str, photo: ContentFile) -> Item:
    """Attaches or replaces the photo of a piece — whoever is handling it at
    the counter, so the Cashier has something to check it against."""
    item = get_item(item_id, lock=True)
    require_branch(ctx, item.branch_id)
    had = bool(item.photo)
    item.photo.save(photo.name, photo, save=False)
    item.save()
    write_log(ctx, LogAction.PHOTO_ATTACHED, f'{"Replaced" if had else "Attached"} the photo of "{item.description}"',
              branch=item.branch_id, record_id=item.id, record_kind=LogRecordKind.ITEM)
    return item


# --- partitions --------------------------------------------------------------

def create_partition(ctx: Ctx, parent_id: str, *, description: str, type: str, grams_drawn: Decimal,
                     amount_centavos: int, photo: ContentFile | None = None,
                     partition_id: str | None = None) -> Item:
    """Carves a smaller piece out of a lot, drawing down grams and amount
    together."""
    require_role(ctx, ENCODE_PURCHASES, "partition a lot")
    parent = get_item(parent_id, lock=True)
    require_branch(ctx, parent.branch_id)
    if parent.verification_status != VerificationStatus.VERIFIED:
        raise Refusal("Only a verified lot can be partitioned — release its purchase first", code="lot_not_verified")
    if parent.item_status not in (ItemStatus.LISTED, ItemStatus.FOR_DISPOSAL):
        raise Refusal(f"A {ItemStatus(parent.item_status).label.lower()} lot can no longer be partitioned",
                      code="lot_not_in_stock")
    if (type == ItemType.SILVER) != parent.is_silver:
        raise Refusal("A partition is the same metal as its lot", code="partition_metal")
    description = (description or "").strip()
    if not description:
        raise Refusal("An item needs a description", code="description_required")
    if grams_drawn is None or amount_centavos is None or grams_drawn <= 0 or amount_centavos <= 0:
        raise Refusal("A partition must draw a positive weight and amount", code="figures_not_positive")
    remaining_grams = parent.effective_remaining_grams
    remaining_amount = parent.effective_remaining_amount
    if grams_drawn > remaining_grams:
        raise Refusal(f"Only {grams(remaining_grams)} remain on this lot — reduce the weight.",
                      code="partition_overdraw", remaining_grams=fixed3(remaining_grams))
    if amount_centavos > remaining_amount:
        raise Refusal(f"Only {peso(remaining_amount)} remain on this lot — reduce the amount.",
                      code="partition_overdraw", remaining_amount_centavos=remaining_amount)

    child = Item(
        id=claim(partition_id, "item"),
        description=description,
        weight_grams=grams_drawn,
        karat=parent.karat,
        type=type,
        capital_amount_centavos=amount_centavos,
        origin=parent.origin,
        branch_id=parent.branch_id,
        item_status=post_verification_status(type),
        verification_status=VerificationStatus.VERIFIED,
        purchase_date=ctx.now,
        submitted_by_role=parent.submitted_by_role,
        encoded_by=ctx.actor,
        batch_id=parent.batch_id,
        parent_lot=parent,
    )
    if photo is not None:
        child.photo.save(photo.name, photo, save=False)
    child.save()

    parent.original_grams = parent.effective_original_grams
    parent.original_amount_centavos = parent.effective_original_amount
    parent.remaining_grams = remaining_grams - grams_drawn
    parent.remaining_amount_centavos = remaining_amount - amount_centavos
    parent.save()

    write_log(
        ctx, LogAction.PARTITION_CREATED,
        f'Drew "{description}" ({fixed3(grams_drawn)}g, {peso(amount_centavos)}) out of lot {parent.id}',
        branch=parent.branch_id, record_id=child.id, record_kind=LogRecordKind.ITEM, amount_centavos=amount_centavos,
    )
    return child


def delete_partition(ctx: Ctx, partition_id: str) -> Item:
    """Admin or the branch's Supervisor: removes a partition drawn by mistake and returns its grams and
    amount to the lot — the exact inverse of create_partition. Moves no cash:
    the lot was paid for once, at release. Returns the restored lot."""
    require_role(ctx, BRANCH_MANAGERS, "return a partition to its lot")
    child = get_item(partition_id, lock=True)
    require_branch(ctx, child.branch_id)
    if child.parent_lot_id is None:
        raise Refusal("Only a partition can be returned to a parent lot", code="not_a_partition")
    if not child.can_return_to_parent:
        raise Refusal(f"A {ItemStatus(child.item_status).label.lower()} partition can no longer be returned to its lot",
                      code="partition_locked")
    if Item.objects.filter(parent_lot_id=child.id).exists():
        raise Refusal("Return the pieces drawn out of this partition first", code="partition_has_partitions")

    parent = get_item(child.parent_lot_id, lock=True)
    restored_grams = parent.effective_remaining_grams + child.weight_grams
    restored_amount = parent.effective_remaining_amount + child.capital_amount_centavos
    siblings_left = Item.objects.filter(parent_lot_id=parent.id).exclude(pk=child.id).exists()
    # With the last partition gone the lot reads as never partitioned again —
    # but only when its own figures already say the same thing. A lot recorded
    # at its post-partition remainder keeps original/remaining as the only
    # record of the whole lot.
    own_figures_match = restored_grams == parent.weight_grams and restored_amount == parent.capital_amount_centavos
    if siblings_left or not own_figures_match:
        parent.remaining_grams = restored_grams
        parent.remaining_amount_centavos = restored_amount
    else:
        parent.original_grams = None
        parent.original_amount_centavos = None
        parent.remaining_grams = None
        parent.remaining_amount_centavos = None

    summary = (f'Returned partition {child.id} "{child.description}" ({fixed3(child.weight_grams)}g, '
               f"{peso(child.capital_amount_centavos)}) to lot {parent.id}")
    amount = child.capital_amount_centavos
    child.delete()
    parent.save()
    write_log(ctx, LogAction.PARTITION_RETURNED, summary, branch=parent.branch_id, record_id=parent.id,
              record_kind=LogRecordKind.ITEM, amount_centavos=amount)
    return parent
