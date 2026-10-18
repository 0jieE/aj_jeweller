"""Feeds SyncChange: every saved or deleted record the phone holds is noted,
in commit order, for GET /sync/changes.

Writes run one at a time under the shop's write lock (services.base), which is
what makes the feed's sequence order equal commit order.
"""

from django.db import connection
from django.db.models.signals import post_delete, post_save

from .models import (
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
    Sale,
    SaleLineItem,
    StoredReceipt,
    SyncChange,
    TransactionLog,
)

# Model -> (snapshot section, how to find the record id). Child rows report
# their parent, since the phone holds them inside it.
TRACKED = {
    Branch: ("branches", lambda o: o.pk),
    GoldRate: ("goldRates", lambda o: str(o.pk)),
    RateChange: ("rateHistory", lambda o: str(o.pk)),
    Item: ("items", lambda o: o.pk),
    Sale: ("sales", lambda o: o.pk),
    SaleLineItem: ("sales", lambda o: o.sale_id),
    Commitment: ("commitments", lambda o: o.pk),
    DisposalBatch: ("disposalBatches", lambda o: o.pk),
    DisposalItem: ("disposalBatches", lambda o: o.batch_id),
    CashEntry: ("cashEntries", lambda o: o.pk),
    PurchaseBatch: ("purchaseBatches", lambda o: o.pk),
    StoredReceipt: ("receipts", lambda o: o.pk),
    Customer: ("customers", lambda o: o.pk),
    TransactionLog: ("logs", lambda o: o.pk),
}

# Saving only these on a person is sign-in bookkeeping, not a staff change.
_SIGN_IN_FIELDS = frozenset({"failed_pin_attempts", "locked_until", "last_login"})


def note_change(kind: str, record_id: str) -> None:
    if connection.in_atomic_block:
        from .services.base import acquire_write_lock

        acquire_write_lock()
    SyncChange.objects.create(kind=kind, record_id=record_id)


def _on_save(sender, instance, raw=False, update_fields=None, **kwargs):
    if raw:
        return
    kind, ident = TRACKED[sender]
    note_change(kind, ident(instance))


def _on_delete(sender, instance, **kwargs):
    kind, ident = TRACKED[sender]
    note_change(kind, ident(instance))


def _on_user_save(sender, instance, raw=False, update_fields=None, **kwargs):
    if raw or (update_fields and set(update_fields) <= _SIGN_IN_FIELDS):
        return
    note_change("users", instance.pk)


def _on_user_delete(sender, instance, **kwargs):
    note_change("users", instance.pk)


def connect() -> None:
    from django.contrib.auth import get_user_model

    for model in TRACKED:
        post_save.connect(_on_save, sender=model, dispatch_uid=f"sync-save-{model.__name__}")
        post_delete.connect(_on_delete, sender=model, dispatch_uid=f"sync-delete-{model.__name__}")
    user = get_user_model()
    post_save.connect(_on_user_save, sender=user, dispatch_uid="sync-save-user")
    post_delete.connect(_on_user_delete, sender=user, dispatch_uid="sync-delete-user")
