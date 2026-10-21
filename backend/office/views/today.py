"""The shop today: both branches' cash, what is waiting on someone, and the
day's purchases and sales."""

from datetime import timedelta

from django.shortcuts import render
from django.urls import reverse
from django.utils import timezone

from shop.enums import BranchId, ItemStatus, VerificationStatus
from shop.models import Branch, Commitment, Item, PurchaseBatch, Sale
from shop.services import cash
from shop.services.purchases import batch_total

from .common import day_start


def _waiting(branches):
    """Each queue, counted per branch, with the filtered list it opens."""
    queues = [
        ("Purchases waiting for their cash", PurchaseBatch.objects.filter(
            verification_status=VerificationStatus.AWAITING), "office:purchases",
         f"status={VerificationStatus.AWAITING}"),
        ("Purchases returned for correction", PurchaseBatch.objects.filter(
            verification_status=VerificationStatus.RETURNED), "office:purchases",
         f"status={VerificationStatus.RETURNED}"),
        ("Sales waiting for payment", Sale.objects.filter(
            verification_status=VerificationStatus.AWAITING), "office:sales", f"status={VerificationStatus.AWAITING}"),
        ("Sales returned for correction", Sale.objects.filter(
            verification_status=VerificationStatus.RETURNED), "office:sales", f"status={VerificationStatus.RETURNED}"),
        ("Loans waiting for their cash", Commitment.objects.filter(date_received__isnull=True),
         "office:commitments", "status=loanPending"),
        ("Pieces waiting for disposal", Item.objects.filter(item_status=ItemStatus.FOR_DISPOSAL), "office:items",
         f"status={ItemStatus.FOR_DISPOSAL}"),
    ]
    rows = []
    for title, queryset, page, query in queues:
        counts = [queryset.filter(branch_id=b.id).count() for b in branches]
        rows.append({"title": title, "counts": counts, "total": queryset.count(),
                     "url": f"{reverse(page)}?{query}"})
    return rows


def today(request):
    day = timezone.localdate()
    start, end = day_start(day), day_start(day + timedelta(days=1))
    # In the app's order: Kidapawan, then Davao.
    branches = sorted(Branch.objects.all(), key=lambda b: BranchId.values.index(b.id))
    purchases = list(PurchaseBatch.objects.filter(date__gte=start, date__lt=end).select_related("submitted_by"))
    for batch in purchases:
        batch.total = batch_total(batch)
    sales = list(Sale.objects.filter(date__gte=start, date__lt=end).select_related("submitted_by")
                 .prefetch_related("lines"))
    return render(request, "office/today.html", {
        "title": "The shop today",
        "day": day,
        "branches": [{"branch": b, "accounts": cash.balances(b, day).values()} for b in branches],
        "branch_names": [b.label for b in branches],
        "waiting": _waiting(branches),
        "purchases": purchases,
        "purchases_total": sum(b.total for b in purchases),
        "sales": sales,
        "sales_total": sum(s.total_centavos for s in sales),
    })
