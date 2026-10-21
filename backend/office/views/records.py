"""The records, read-only: a filterable table and a detail page for each kind.
The filters are the app's: branch, date range, status, type, search."""

from django.db.models import Case, F, Prefetch, Q, Sum, Value, When
from django.db.models.functions import Coalesce
from django.shortcuts import render

from shop.enums import CashAccount, CashEntryType, CommitmentStatus, ItemStatus, ItemType, VerificationStatus
from shop.models import CashEntry, Commitment, Customer, DisposalBatch, Item, PurchaseBatch, Sale, StoredReceipt
from shop.services import cash, commitments, disposal, items
from shop.services.purchases import batch_total, lines_of

from .auth import not_found
from .common import history, page_context, paged, read_filters


def _search(queryset, q, *fields):
    if not q:
        return queryset
    match = Q(id__iexact=q)
    for field in fields:
        match |= Q(**{f"{field}__icontains": q})
    return queryset.filter(match)


# --- purchases -----------------------------------------------------------------

def with_lines(batches):
    """Purchases with their lines fetched in one extra query for the whole page,
    rather than two per row. The lines are lines_of(): the pieces handed over,
    not partitions drawn later."""
    pieces = Item.objects.filter(parent_lot__isnull=True).order_by("line_no", "id")
    return batches.prefetch_related(Prefetch("items", queryset=pieces, to_attr="visit_lines"))


def tally(batches):
    """Each purchase's total and piece count, from its prefetched lines — the
    same sum as purchases.batch_total."""
    for batch in batches:
        batch.total = sum(item.effective_original_amount for item in batch.visit_lines)
        batch.line_count = len(batch.visit_lines)
    return batches


def purchases(request):
    f = read_filters(request, statuses=VerificationStatus.values)
    # Every list ends its ordering on the id, so a page boundary never splits
    # records that share a date (one would show twice and another never).
    queryset = with_lines(PurchaseBatch.objects.select_related("submitted_by", "released_by")
                          .order_by("-date", "-id"))
    queryset = _search(f.dated(f.branched(queryset), "date"), f.q, "customer_name", "customer_contact_number")
    if f.status:
        queryset = queryset.filter(verification_status=f.status)
    page = paged(request, queryset)
    tally(page.rows)
    return render(request, "office/purchases.html", page_context(
        title="Purchases", f=f, page=page, status_choices=VerificationStatus.choices))


def purchase(request, pk):
    batch = PurchaseBatch.objects.select_related("submitted_by", "released_by", "customer").filter(pk=pk).first()
    if batch is None:
        return not_found(request)
    lines = lines_of(batch)
    return render(request, "office/purchase.html", {
        "title": f"Purchase {batch.id}", "batch": batch, "lines": lines, "total": batch_total(batch),
        "receipt": StoredReceipt.objects.filter(record_id=batch.id).first(),
        "log": history(request, batch.id, *[item.id for item in lines]),
    })


# --- sales ---------------------------------------------------------------------

def sales(request):
    f = read_filters(request, statuses=VerificationStatus.values)
    queryset = (Sale.objects.select_related("submitted_by", "received_by").prefetch_related("lines")
                .order_by("-date", "-id"))
    queryset = _search(f.dated(f.branched(queryset), "date"), f.q, "customer_name", "customer_contact_number")
    if f.status:
        queryset = queryset.filter(verification_status=f.status)
    return render(request, "office/sales.html", page_context(
        title="Sales", f=f, page=paged(request, queryset), status_choices=VerificationStatus.choices))


def sale(request, pk):
    order = Sale.objects.select_related("submitted_by", "received_by", "customer").filter(pk=pk).first()
    if order is None:
        return not_found(request)
    lines = list(order.lines.select_related("item").order_by("position"))
    return render(request, "office/sale.html", {
        "title": f"Sale {order.id}", "sale": order, "lines": lines, "total": sum(l.negotiated_price_centavos for l in lines),
        "receipt": StoredReceipt.objects.filter(record_id=order.id).first(),
        "log": history(request, order.id),
    })


# --- items ---------------------------------------------------------------------

def items_list(request):
    f = read_filters(request, statuses=ItemStatus.values, types=ItemType.values)
    queryset = _search(f.dated(f.branched(Item.objects.all()), "purchase_date"), f.q, "description", "origin")
    if f.status:
        queryset = queryset.filter(item_status=f.status)
    if f.type:
        queryset = queryset.filter(type=f.type)
    return render(request, "office/items.html", page_context(
        title="Items", f=f, page=paged(request, queryset), status_choices=ItemStatus.choices,
        type_choices=ItemType.choices))


def item(request, pk):
    piece = Item.objects.select_related("batch", "parent_lot", "encoded_by").filter(pk=pk).first()
    if piece is None:
        return not_found(request)
    return render(request, "office/item.html", {
        "title": f"Item {piece.id}", "item": piece, "can_correct": items.can_edit(piece),
        "partitions": piece.partitions.order_by("id"),
        "sale_lines": piece.sale_lines.select_related("sale"),
        "disposals": piece.disposals.all(),
        "log": history(request, piece.id),
    })


# --- cash ----------------------------------------------------------------------

def cash_entries(request):
    f = read_filters(request, types=CashEntryType.values)
    account = request.GET.get("account") or ""
    account = account if account in CashAccount.values else ""
    queryset = CashEntry.objects.select_related("recorded_by")
    queryset = _search(f.dated(f.branched(queryset), "date"), f.q, "note", "category", "linked_record_id")
    if f.type:
        queryset = queryset.filter(type=f.type)
    if account:
        queryset = queryset.filter(account=account)
    return render(request, "office/cash_entries.html", page_context(
        title="Cash entries", f=f, account=account, page=paged(request, queryset),
        type_choices=CashEntryType.choices, account_choices=CashAccount.choices))


def cash_entry(request, pk):
    entry = CashEntry.objects.select_related("recorded_by").filter(pk=pk).first()
    if entry is None:
        return not_found(request)
    return render(request, "office/cash_entry.html", {
        "title": f"Cash entry {entry.id}", "entry": entry, "group": cash.group_of(entry),
        "lock": cash.lock_reason(entry), "log": history(request, *[e.id for e in cash.group_of(entry)]),
    })


# --- customers -----------------------------------------------------------------

def customers(request):
    f = read_filters(request)
    queryset = _search(f.dated(Customer.objects.order_by("name_key", "id"), "first_seen"), f.q, "name",
                       "contact_number", "address")
    return render(request, "office/customers.html", page_context(
        title="Customers", f=f, page=paged(request, queryset)))


def customer(request, pk):
    person = Customer.objects.filter(pk=pk).first()
    if person is None:
        return not_found(request)
    bought = with_lines(PurchaseBatch.objects.filter(customer=person).order_by("-date", "-id"))
    bought = paged(request, bought, param="ppage", per=20, choices=())
    tally(bought.rows)
    sold = Sale.objects.filter(customer=person).prefetch_related("lines").order_by("-date", "-id")
    return render(request, "office/customer.html", {
        "title": person.name, "customer": person, "purchases": bought,
        "sales": paged(request, sold, param="spage", per=20, choices=()),
        "log": history(request, person.id),
    })


# --- loans and disposal --------------------------------------------------------

def commitments_list(request):
    f = read_filters(request, statuses=CommitmentStatus.values)
    queryset = Commitment.objects.select_related("branch").annotate(
        repaid=Coalesce(Sum("disposals__gross_amount_centavos"), Value(0)),
        # The same three states as commitments.Ledger.status, worked out by the
        # database so a status filter never loads every loan.
        state=Case(
            When(date_received__isnull=True, then=Value(CommitmentStatus.LOAN_PENDING.value)),
            When(repaid__gte=F("amount_centavos"), then=Value(CommitmentStatus.LOAN_PAID.value)),
            default=Value(CommitmentStatus.LOAN_RECEIVED.value),
        ),
    )
    if request.GET.get("branch") == "none":
        queryset = queryset.filter(branch__isnull=True)
    queryset = _search(f.dated(f.branched(queryset), "date_approved"), f.q, "lender")
    if f.status:
        queryset = queryset.filter(state=f.status)
    queryset = queryset.order_by("-date_approved", "-id")  # grouping drops the model's own ordering
    page = paged(request, queryset)
    page.rows = [commitments.Ledger(commitment=c, repaid_centavos=c.repaid) for c in page.rows]
    return render(request, "office/commitments.html", page_context(
        title="Commitments", f=f, page=page, status_choices=CommitmentStatus.choices,
        company_wide=request.GET.get("branch") == "none"))


def commitment(request, pk):
    loan = Commitment.objects.select_related("branch").filter(pk=pk).first()
    if loan is None:
        return not_found(request)
    return render(request, "office/commitment.html", {
        "title": f"Commitment {loan.id}", "loan": commitments.ledger(loan), "figures": commitments.ledger(loan).as_dict(),
        "disposals": loan.disposals.order_by("date"), "log": history(request, loan.id),
    })


def disposals(request):
    f = read_filters(request)
    batches = DisposalBatch.objects.select_related("commitment").order_by("-date", "-id")
    queryset = _search(f.dated(f.branched(batches), "date"), f.q, "commitment__lender")
    return render(request, "office/disposals.html", page_context(
        title="Disposal batches", f=f, page=paged(request, queryset)))


def disposal_batch(request, pk):
    batch = DisposalBatch.objects.select_related("commitment", "branch").filter(pk=pk).first()
    if batch is None:
        return not_found(request)
    return render(request, "office/disposal.html", {
        "title": f"Disposal {batch.id}", "batch": batch, "pieces": batch.ordered_items(),
        "breakdown": disposal.karat_breakdown(batch), "log": history(request, batch.id),
    })
