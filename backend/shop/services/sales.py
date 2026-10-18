"""Selling: cart holds, checkout, payment, return and resubmit.

A Sales Rep holds pieces for an order (reserved), sends it to the Cashier, and
no cash moves. The Cashier receives payment — which must add up to the order —
marks every piece sold, and credits each part where it physically went: the
cash part into Sales Cash, the transferred part into Cash in Bank. Sale
takings never top up the purchase float.
"""

from dataclasses import dataclass
from decimal import Decimal

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
)
from ..errors import NotFound, Refusal
from ..ids import claim
from ..models import Item, Sale, SaleLineItem
from ..snapshot import item_json
from ..text import peso
from . import cash
from .base import BUILD_SALES, MOVE_CASH, Ctx, blank_to_none, branch_for_write, change, require_branch, require_role, write_log
from .customers import CustomerDetails, file_on_transaction


@dataclass
class LineInput:
    item_id: str
    negotiated_price_centavos: int
    final_grams: Decimal | None = None


def get_sale(sale_id: str) -> Sale:
    try:
        return Sale.objects.select_related("branch").get(pk=sale_id)
    except Sale.DoesNotExist:
        raise NotFound("Order not found") from None


def _open_sale_holding(item: Item, except_sale: str | None = None) -> Sale | None:
    """The open order (awaiting payment or returned to the rep) holding this piece."""
    lines = SaleLineItem.objects.filter(item=item).exclude(sale__verification_status=VerificationStatus.VERIFIED)
    if except_sale:
        lines = lines.exclude(sale_id=except_sale)
    line = lines.select_related("sale").first()
    return line.sale if line else None


def _check_sellable(item: Item, branch_id: str, *, held_by_this_sale: bool = False) -> None:
    if item.branch_id != branch_id:
        raise Refusal("Every piece in an order has to come from the same branch", code="wrong_branch")
    if item.type == ItemType.SCRAP:
        raise Refusal("Scrap is never sold over the counter — it leaves through a disposal batch",
                      code="scrap_not_sellable")
    if item.verification_status != VerificationStatus.VERIFIED:
        raise Refusal(f'"{item.description}" has not been verified yet', code="not_verified")
    if held_by_this_sale:
        return
    if item.item_status == ItemStatus.RESERVED:
        holder = _open_sale_holding(item)
        if holder is not None:
            raise Refusal(f'"{item.description}" is already held for order {holder.id}', code="already_held",
                          sale_id=holder.id)
        return  # held by a cart, which is what checkout turns into an order
    if item.item_status != ItemStatus.LISTED:
        raise Refusal(f'"{item.description}" is {ItemStatus(item.item_status).label.lower()} and cannot be sold',
                      code="not_sellable")


def _check_lines(lines: list[LineInput], branch_id: str, sale_id: str | None = None) -> list[tuple[Item, LineInput]]:
    if not lines:
        raise Refusal("An order needs at least one item", code="no_items")
    seen = set()
    checked = []
    current = set()
    if sale_id:
        current = set(SaleLineItem.objects.filter(sale_id=sale_id).values_list("item_id", flat=True))
    for line in lines:
        if line.item_id in seen:
            raise Refusal("The same piece is in the order twice", code="duplicate_line")
        seen.add(line.item_id)
        item = Item.objects.select_for_update().filter(pk=line.item_id).first()
        if item is None:
            raise Refusal(f"Item {line.item_id} does not exist", code="unknown_item")
        _check_sellable(item, branch_id, held_by_this_sale=line.item_id in current)
        if line.negotiated_price_centavos is None or line.negotiated_price_centavos <= 0:
            raise Refusal(f'Each piece needs a price above zero — "{item.description}" has none',
                          code="price_not_positive")
        if line.final_grams is not None and line.final_grams <= 0:
            raise Refusal("Final weight must be above zero", code="grams_not_positive")
        checked.append((item, line))
    return checked


def _check_payment(cash_centavos: int, bank_centavos: int) -> None:
    if cash_centavos < 0 or bank_centavos < 0:
        raise Refusal("A payment cannot be negative", code="payment_negative")


def _write_lines(sale: Sale, checked: list[tuple[Item, LineInput]]) -> None:
    for position, (item, line) in enumerate(checked):
        SaleLineItem.objects.create(
            sale=sale, item=item, position=position, negotiated_price_centavos=line.negotiated_price_centavos,
            final_grams=line.final_grams, item_snapshot=item_json(item, photos=False),
        )


def _reserve(item: Item) -> None:
    if item.item_status != ItemStatus.RESERVED:
        item.item_status = ItemStatus.RESERVED
        item.save()


def checkout(ctx: Ctx, *, branch_id: str | None, customer: CustomerDetails, lines: list[LineInput],
             cash_centavos: int = 0, bank_centavos: int = 0, note: str | None = None,
             sale_id: str | None = None) -> Sale:
    """Hands an order to the Cashier's queue. Its pieces are held (reserved);
    no balance moves until the Cashier receives payment."""
    require_role(ctx, BUILD_SALES, "build sales")
    branch = branch_for_write(ctx, branch_id)
    checked = _check_lines(lines, branch.id)
    _check_payment(cash_centavos, bank_centavos)
    saved = file_on_transaction(ctx, customer)
    sale = Sale.objects.create(
        id=claim(sale_id, "sale"),
        customer_name=customer.name,
        customer_contact_number=blank_to_none(customer.contact_number),
        customer_address=blank_to_none(customer.address),
        customer=saved,
        note=blank_to_none(note),
        cash_centavos=cash_centavos,
        bank_centavos=bank_centavos,
        verification_status=VerificationStatus.AWAITING,
        branch=branch,
        date=ctx.now,
        submitted_by_role=ctx.actor.role,
        submitted_by=ctx.actor,
    )
    for item, _ in checked:
        _reserve(item)
    _write_lines(sale, checked)
    total = sale.total_centavos
    write_log(
        ctx, LogAction.SALE_SUBMITTED,
        f"Sent an order of {len(checked)} item(s) for {customer.name} ({peso(total)}) to the Cashier",
        branch=branch.id, record_id=sale.id, record_kind=LogRecordKind.SALE, amount_centavos=total,
    )
    notify.sale_awaiting_payment(ctx, sale)
    return sale


def complete(ctx: Ctx, sale_id: str, *, cash_centavos: int, bank_centavos: int,
             cash_entry_id: str | None = None, bank_entry_id: str | None = None) -> Sale:
    """Cashier: receives payment. It must add up to the order. Marks every
    piece sold and credits Sales Cash and/or Cash in Bank — never the
    purchase float."""
    require_role(ctx, MOVE_CASH, "receive payment")
    sale = get_sale(sale_id)
    require_branch(ctx, sale.branch_id)
    if sale.verification_status == VerificationStatus.VERIFIED:
        raise Refusal("Payment for this order was already received", code="already_paid")
    if sale.verification_status == VerificationStatus.RETURNED:
        raise Refusal("This order was returned to the rep — it can be paid once it is resubmitted",
                      code="returned_for_correction")
    _check_payment(cash_centavos, bank_centavos)
    total = sale.total_centavos
    paid = cash_centavos + bank_centavos
    if paid != total:
        raise Refusal(f"Payment of {peso(paid)} does not match the order total of {peso(total)}",
                      code="payment_mismatch", total_centavos=total, paid_centavos=paid)

    sale.verification_status = VerificationStatus.VERIFIED
    sale.verification_note = None
    sale.cash_centavos = cash_centavos
    sale.bank_centavos = bank_centavos
    sale.received_by = ctx.actor
    sale.save()

    for line in sale.lines.select_related("item"):
        line.item.item_status = ItemStatus.SOLD
        line.item.save()
        # The piece as sold — what the receipt prints even if it is corrected later.
        line.item_snapshot = item_json(line.item, photos=False)
        line.save()

    split = cash_centavos > 0 and bank_centavos > 0
    if cash_centavos > 0:
        cash.write_entry(
            ctx, branch_id=sale.branch_id, type=CashEntryType.CASH_IN, account=CashAccount.SALES,
            amount_centavos=cash_centavos,
            note=f"Payment received - {sale.customer_name}{' (cash portion)' if split else ''}",
            source_type=CashEntrySourceType.SALE, linked_record_id=sale.id, entry_id=cash_entry_id,
        )
    if bank_centavos > 0:
        cash.write_entry(
            ctx, branch_id=sale.branch_id, type=CashEntryType.CASH_IN, account=CashAccount.BANK,
            amount_centavos=bank_centavos,
            note=f"Bank payment received - {sale.customer_name}{' (bank portion)' if split else ''}",
            source_type=CashEntrySourceType.SALE, linked_record_id=sale.id, entry_id=bank_entry_id,
        )
    method = "Cash + Bank" if split else ("Bank Transfer" if bank_centavos > 0 else "Cash")
    how = (f" ({peso(cash_centavos)} cash, {peso(bank_centavos)} bank)" if split
           else f" by {method.lower()}")
    write_log(
        ctx, LogAction.PAYMENT_RECEIVED, f"Received {peso(paid)} from {sale.customer_name}{how}",
        branch=sale.branch_id, record_id=sale.id, record_kind=LogRecordKind.SALE, amount_centavos=paid,
    )
    return sale


def return_for_correction(ctx: Ctx, sale_id: str, note: str) -> Sale:
    """Cashier: sends the order back to the rep. Its pieces stay held."""
    require_role(ctx, MOVE_CASH, "return an order for correction")
    sale = get_sale(sale_id)
    require_branch(ctx, sale.branch_id)
    note = (note or "").strip()
    if not note:
        raise Refusal("Explain what needs to be fixed — the note goes back to the rep", code="note_required")
    if sale.verification_status != VerificationStatus.AWAITING:
        raise Refusal("Only an order waiting on payment can be returned for correction", code="not_awaiting")
    sale.verification_status = VerificationStatus.RETURNED
    sale.verification_note = note
    sale.save()
    write_log(ctx, LogAction.SALE_RETURNED, f"Returned the order for {sale.customer_name} to the rep: {note}",
              branch=sale.branch_id, record_id=sale.id, record_kind=LogRecordKind.SALE)
    notify.sale_returned(ctx, sale, note)
    return sale


def resubmit(ctx: Ctx, sale_id: str, *, lines: list[LineInput], customer: CustomerDetails | None = None,
             note=None, cash_centavos: int | None = None, bank_centavos: int | None = None) -> Sale:
    """Rep: re-sends a returned order with a fixed set of lines. Pieces dropped
    from it go back on sale; pieces added are held."""
    require_role(ctx, BUILD_SALES, "build sales")
    sale = get_sale(sale_id)
    require_branch(ctx, sale.branch_id)
    if sale.verification_status != VerificationStatus.RETURNED:
        raise Refusal("Only an order returned for correction can be resubmitted", code="not_returned")
    checked = _check_lines(lines, sale.branch_id, sale_id=sale.id)
    new_cash = sale.cash_centavos if cash_centavos is None else cash_centavos
    new_bank = sale.bank_centavos if bank_centavos is None else bank_centavos
    _check_payment(new_cash, new_bank)

    before_total = sale.total_centavos
    before_items = list(sale.lines.order_by("position").values_list("item_id", flat=True))
    changes = []
    if customer is not None and customer.name:
        saved = file_on_transaction(ctx, customer)
        if customer.name != sale.customer_name:
            changes.append(change("Customer", sale.customer_name, customer.name))
        sale.customer = saved
        sale.customer_name = customer.name
        sale.customer_contact_number = blank_to_none(customer.contact_number)
        sale.customer_address = blank_to_none(customer.address)
    if note is not None and blank_to_none(note) != sale.note:
        changes.append(change("Note", sale.note or "—", blank_to_none(note) or "—"))
        sale.note = blank_to_none(note)

    keep = {item.id for item, _ in checked}
    for line in sale.lines.select_related("item"):
        if line.item_id not in keep:
            line.item.item_status = ItemStatus.LISTED
            line.item.save()
    sale.lines.all().delete()
    for item, _ in checked:
        _reserve(item)
    _write_lines(sale, checked)

    sale.cash_centavos, sale.bank_centavos = new_cash, new_bank
    sale.verification_status = VerificationStatus.AWAITING
    sale.verification_note = None
    sale.save()
    after_total = sale.total_centavos
    after_items = [item.id for item, _ in checked]
    if after_items != before_items:
        changes.append(change("Items", ", ".join(before_items), ", ".join(after_items)))
    if after_total != before_total:
        changes.append(change("Total", peso(before_total), peso(after_total)))
    write_log(
        ctx, LogAction.SALE_RESUBMITTED,
        f"Corrected the order for {sale.customer_name} and sent it back to the Cashier",
        branch=sale.branch_id, record_id=sale.id, record_kind=LogRecordKind.SALE, amount_centavos=after_total,
        changes=changes,
    )
    notify.sale_awaiting_payment(ctx, sale)
    return sale


# --- cart holds --------------------------------------------------------------

def reserve(ctx: Ctx, item_id: str) -> Item:
    """Holds a piece for an order being built, so it can't go into a second
    order at the same time."""
    require_role(ctx, BUILD_SALES, "build sales")
    item = Item.objects.select_for_update().filter(pk=item_id).first()
    if item is None:
        raise NotFound("Item not found")
    require_branch(ctx, item.branch_id)
    if item.item_status == ItemStatus.RESERVED:
        holder = _open_sale_holding(item)
        raise Refusal(f'"{item.description}" is already held'
                      f'{" for order " + holder.id if holder else " for another order"}', code="already_held")
    _check_sellable(item, item.branch_id)
    item.item_status = ItemStatus.RESERVED
    item.save()
    write_log(ctx, LogAction.ITEM_RESERVED, f'Held "{item.description}" for an order being built',
              branch=item.branch_id, record_id=item.id, record_kind=LogRecordKind.ITEM)
    return item


def release_reservation(ctx: Ctx, item_id: str) -> Item:
    """Puts a cart-held piece back on sale — an abandoned cart."""
    require_role(ctx, BUILD_SALES, "build sales")
    item = Item.objects.select_for_update().filter(pk=item_id).first()
    if item is None:
        raise NotFound("Item not found")
    require_branch(ctx, item.branch_id)
    if item.item_status != ItemStatus.RESERVED:
        raise Refusal(f'"{item.description}" is not being held', code="not_reserved")
    holder = _open_sale_holding(item)
    if holder is not None:
        raise Refusal(f'"{item.description}" is held by order {holder.id} — return or correct that order instead',
                      code="held_by_order", sale_id=holder.id)
    item.item_status = ItemStatus.LISTED
    item.save()
    write_log(ctx, LogAction.RESERVATION_RELEASED, f'Put "{item.description}" back on sale',
              branch=item.branch_id, record_id=item.id, record_kind=LogRecordKind.ITEM)
    return item
