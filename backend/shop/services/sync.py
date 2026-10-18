"""The phone's side of the offline outbox.

* GET /sync/snapshot — everything the person may see, in the phone's own file
  format, to start from (or start over from).
* GET /sync/changes?since=N — what changed after cursor N, in the same format,
  plus the ids of records that no longer exist. The cursor is the SyncChange
  sequence, which is commit order (writes are serialised), so a phone that
  stores the returned cursor never misses a change.
* POST /sync/push — replays queued writes; see api/views_sync.py.

Branch staff receive their own branch's records plus everything company-wide
(staff, customers, rates, company loans and log entries). Both branches are
always included, because the phone's parser refuses a snapshot without them.
"""

from django.db.models import Max, Q
from django.utils import timezone

from accounts.models import User

from .. import snapshot as codec
from ..models import (
    Branch,
    CashEntry,
    Commitment,
    Customer,
    DisposalBatch,
    GoldRate,
    Item,
    PurchaseBatch,
    RateChange,
    Sale,
    StoredReceipt,
    SyncChange,
    TransactionLog,
)

PAGE = 1000


def _scoped(model, branch: str | None, *, company_wide: bool = False):
    queryset = model.objects.all()
    if branch is None:
        return queryset
    if company_wide:
        return queryset.filter(Q(branch_id=branch) | Q(branch__isnull=True))
    return queryset.filter(branch_id=branch)


# section -> (queryset for a branch scope, encoder)
def _sections(branch: str | None, photos: bool) -> dict:
    return {
        "users": (User.objects.all(), codec.user_json),
        "branches": (Branch.objects.all(), codec.branch_json),
        "goldRates": (GoldRate.objects.all(), codec.gold_rate_json),
        "rateHistory": (RateChange.objects.all(), codec.rate_change_json),
        "items": (_scoped(Item, branch), lambda o: codec.item_json(o, photos)),
        "sales": (_scoped(Sale, branch), lambda o: codec.sale_json(o, photos)),
        "commitments": (_scoped(Commitment, branch, company_wide=True), lambda o: codec.commitment_json(o, photos)),
        "disposalBatches": (_scoped(DisposalBatch, branch), lambda o: codec.disposal_json(o, photos)),
        "cashEntries": (_scoped(CashEntry, branch), codec.cash_entry_json),
        "purchaseBatches": (_scoped(PurchaseBatch, branch), lambda o: codec.purchase_batch_json(o, photos)),
        "receipts": (_scoped(StoredReceipt, branch), lambda o: codec.receipt_json(o, photos)),
        "customers": (Customer.objects.all(), lambda o: codec.customer_json(o, photos)),
        "logs": (_scoped(TransactionLog, branch, company_wide=True), codec.log_json),
    }


_ORDER = {
    "items": ("-purchase_date", "id"), "sales": ("-date",), "purchaseBatches": ("-date",),
    "cashEntries": ("-date", "id"), "logs": ("at", "id"), "rateHistory": ("at", "id"), "commitments": ("-date_approved",),
    "disposalBatches": ("-date",), "receipts": ("-issued_at",), "customers": ("name_key",), "users": ("name",),
    "branches": ("id",), "goldRates": ("-karat",),
}


def cursor() -> int:
    return SyncChange.objects.aggregate(top=Max("seq"))["top"] or 0


def full_snapshot(branch: str | None, *, photos: bool = True) -> dict:
    """Everything in scope, as one phone snapshot, plus the cursor to pull from next."""
    top = cursor()
    out = {"version": codec.SNAPSHOT_VERSION, "savedAt": codec.dt(timezone.now()), "cursor": top}
    for name, (queryset, encode) in _sections(branch, photos).items():
        rows = [encode(o) for o in queryset.order_by(*_ORDER[name])]
        out[name] = [row for row in rows if row is not None]
    return out


def changes_since(since: int, branch: str | None, *, photos: bool = True, limit: int = PAGE) -> dict:
    feed = list(SyncChange.objects.filter(seq__gt=since).order_by("seq")[: limit + 1])
    has_more = len(feed) > limit
    feed = feed[:limit]
    last = feed[-1].seq if feed else since

    wanted: dict[str, list[str]] = {}
    for change in feed:
        ids = wanted.setdefault(change.kind, [])
        if change.record_id not in ids:
            ids.append(change.record_id)

    sections = _sections(branch, photos)
    changed: dict[str, list] = {}
    deleted: dict[str, list[str]] = {}
    for kind, ids in wanted.items():
        if kind not in sections:
            continue
        queryset, encode = sections[kind]
        model = queryset.model
        lookup = [int(i) for i in ids] if model in (GoldRate, RateChange) else ids
        present = {str(o.pk): o for o in queryset.filter(pk__in=lookup)}
        anywhere = {str(pk) for pk in model.objects.filter(pk__in=lookup).values_list("pk", flat=True)}
        rows = [encode(present[i]) for i in ids if i in present]
        rows = [row for row in rows if row is not None]
        if rows:
            changed[kind] = rows
        gone = [i for i in ids if i not in anywhere]
        if gone:
            deleted[kind] = gone
    return {"since": since, "cursor": last, "has_more": has_more, "changes": changed, "deleted": deleted}
