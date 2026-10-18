"""Every enumeration the shop uses, stored as the exact names the Flutter
client serialises (`enum.name`), so a value read off the phone's snapshot is
the value in the database.

The labels match the app's `label` getters, because log summaries and change
lists are written in the words the app shows.
"""

from django.db import models


class BranchId(models.TextChoices):
    KIDAPAWAN = "kidapawan", "Kidapawan"
    DAVAO = "davao", "Davao"


class Role(models.TextChoices):
    ASSISTANT_APPRAISER = "assistantAppraiser", "Assistant Appraiser"
    SALES_REP = "salesRep", "Sales Rep"
    CASHIER = "cashier", "Cashier"
    ADMIN = "admin", "Admin"
    # Runs one branch without needing the Admin (cash ledger, corrections,
    # disposal, that branch's loans and counter staff) — scoped to home_branch.
    SUPERVISOR = "supervisor", "Supervisor"
    # An Admin everywhere in the shop, and the only role that may use the
    # Django administration site.
    SUPERUSER = "superuser", "Superuser"


# Who oversees both branches (has no home_branch).
BOTH_BRANCH_ROLES = frozenset({Role.ADMIN, Role.SUPERUSER})
# Counter work at one branch.
COUNTER_ROLES = frozenset({Role.CASHIER, Role.ASSISTANT_APPRAISER, Role.SALES_REP})


def oversees_both(role: str) -> bool:
    return role in BOTH_BRANCH_ROLES


def a_role(role: str, *, capital: bool = False) -> str:
    """'an Admin', 'a Supervisor' — a role with its article, for messages."""
    label = Role(role).label
    article = "an" if label[0] in "AEIOU" else "a"
    return f"{article.capitalize() if capital else article} {label}"


def needs_branch(role: str) -> bool:
    """Everyone but an Admin or Superuser works from exactly one branch."""
    return role not in BOTH_BRANCH_ROLES


class ItemType(models.TextChoices):
    GOODS = "goods", "Goods"
    SCRAP = "scrap", "Scrap"
    SILVER = "silver", "Silver"


class ItemStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    LISTED = "listed", "Listed"
    SOLD = "sold", "Sold"
    RESERVED = "reserved", "Reserved"
    FOR_DISPOSAL = "forDisposal", "For Disposal"
    DISPOSED = "disposed", "Disposed"


class VerificationStatus(models.TextChoices):
    AWAITING = "awaitingVerification", "Awaiting Verification"
    VERIFIED = "verified", "Verified"
    RETURNED = "returnedForCorrection", "Returned for Correction"


class CommitmentStatus(models.TextChoices):
    """Derived, never stored — see shop.services.commitments.ledger."""

    LOAN_PENDING = "loanPending", "Loan Pending"
    LOAN_RECEIVED = "loanReceived", "Loan Received"
    LOAN_PAID = "loanPaid", "Loan Paid"


class CashAccount(models.TextChoices):
    PURCHASE = "purchase", "Purchase Cash"
    SALES = "sales", "Sales Cash"
    BANK = "bank", "Cash in Bank"


class CashEntryType(models.TextChoices):
    CASH_IN = "cashIn", "Cash in"
    EXPENSE = "expense", "Expense"
    WITHDRAWAL = "withdrawal", "Withdrawal"
    TRANSFER_OUT = "transferOut", "Transfer out"
    TRANSFER_IN = "transferIn", "Transfer in"


CREDIT_TYPES = frozenset({CashEntryType.CASH_IN, CashEntryType.TRANSFER_IN})
MANUAL_TYPES = frozenset({CashEntryType.CASH_IN, CashEntryType.EXPENSE, CashEntryType.WITHDRAWAL})


class CashEntrySourceType(models.TextChoices):
    MANUAL = "manual", "Manual"
    PURCHASE = "purchase", "Purchase"
    SALE = "sale", "Sale"
    COMMITMENT = "commitment", "Commitment"


class ReceiptKind(models.TextChoices):
    PURCHASE = "purchase", "Purchase"
    SALE = "sale", "Sale"


class LogCategory(models.TextChoices):
    PURCHASE = "purchase", "Purchase"
    SALE = "sale", "Sale"
    SCRAP = "scrap", "Scrap & Loans"
    CASH = "cash", "Cash"
    ADMIN = "admin", "Admin"


class LogRecordKind(models.TextChoices):
    PURCHASE_BATCH = "purchaseBatch", "Purchase"
    ITEM = "item", "Item"
    SALE = "sale", "Sale"
    DISPOSAL = "disposal", "Disposal"
    COMMITMENT = "commitment", "Commitment"
    CASH_ENTRY = "cashEntry", "Cash entry"
    CUSTOMER = "customer", "Customer"
    USER = "user", "User"


class LogAction(models.TextChoices):
    # --- the app's own vocabulary (LogAction in transaction_log.dart) -------
    PURCHASE_RECORDED = "purchaseRecorded", "Purchase recorded"
    CASH_RELEASED = "cashReleased", "Cash released"
    PURCHASE_RETURNED = "purchaseReturned", "Purchase returned"
    PURCHASE_RESUBMITTED = "purchaseResubmitted", "Purchase resubmitted"
    PARTITION_CREATED = "partitionCreated", "Partition created"
    PARTITION_RETURNED = "partitionReturned", "Partition returned"
    ITEM_EDITED = "itemEdited", "Item edited"
    PHOTO_ATTACHED = "photoAttached", "Photo attached"
    SALE_SUBMITTED = "saleSubmitted", "Sale submitted"
    SALE_RESUBMITTED = "saleResubmitted", "Sale resubmitted"
    PAYMENT_RECEIVED = "paymentReceived", "Payment received"
    SALE_RETURNED = "saleReturned", "Sale returned"
    DISPOSAL_COMPLETED = "disposalCompleted", "Disposal completed"
    COMMITMENT_ADDED = "commitmentAdded", "Commitment added"
    COMMITMENT_RECEIVED = "commitmentReceived", "Loan cash received"
    CASH_ENTRY_RECORDED = "cashEntryRecorded", "Cash entry"
    CASH_TRANSFERRED = "cashTransferred", "Cash transfer"
    CASH_ENTRY_EDITED = "cashEntryEdited", "Cash entry edited"
    CASH_ENTRY_DELETED = "cashEntryDeleted", "Cash entry deleted"
    GOLD_RATE_UPDATED = "goldRateUpdated", "Rate updated"
    GOLD_RATE_ADDED = "goldRateAdded", "Rate added"
    CUSTOMER_PHOTO_UPDATED = "customerPhotoUpdated", "Customer photo"
    USER_ADDED = "userAdded", "User added"
    USER_UPDATED = "userUpdated", "User edited"
    USER_DEACTIVATED = "userDeactivated", "User deactivated"
    USER_REACTIVATED = "userReactivated", "User reactivated"
    USER_DELETED = "userDeleted", "User deleted"
    # --- server-only actions -------------------------------------------------
    # The phone never logged these because they never left the device; on a
    # server every mutating request writes a row. The v1 app cannot parse
    # these names, so phone-format exports leave them out (see PHONE_ACTIONS).
    ITEM_RESERVED = "itemReserved", "Item held for an order"
    RESERVATION_RELEASED = "reservationReleased", "Item put back on sale"
    CUSTOMER_ADDED = "customerAdded", "Customer added"
    CUSTOMER_UPDATED = "customerUpdated", "Customer edited"
    RECEIPT_ISSUED = "receiptIssued", "Receipt issued"
    SNAPSHOT_IMPORTED = "snapshotImported", "Phone data imported"


_CATEGORY = {
    LogAction.PURCHASE_RECORDED: LogCategory.PURCHASE,
    LogAction.CASH_RELEASED: LogCategory.PURCHASE,
    LogAction.PURCHASE_RETURNED: LogCategory.PURCHASE,
    LogAction.PURCHASE_RESUBMITTED: LogCategory.PURCHASE,
    LogAction.PARTITION_CREATED: LogCategory.PURCHASE,
    LogAction.PARTITION_RETURNED: LogCategory.PURCHASE,
    LogAction.ITEM_EDITED: LogCategory.PURCHASE,
    LogAction.PHOTO_ATTACHED: LogCategory.PURCHASE,
    LogAction.SALE_SUBMITTED: LogCategory.SALE,
    LogAction.SALE_RESUBMITTED: LogCategory.SALE,
    LogAction.PAYMENT_RECEIVED: LogCategory.SALE,
    LogAction.SALE_RETURNED: LogCategory.SALE,
    LogAction.DISPOSAL_COMPLETED: LogCategory.SCRAP,
    LogAction.COMMITMENT_ADDED: LogCategory.SCRAP,
    LogAction.COMMITMENT_RECEIVED: LogCategory.SCRAP,
    LogAction.CASH_ENTRY_RECORDED: LogCategory.CASH,
    LogAction.CASH_TRANSFERRED: LogCategory.CASH,
    LogAction.CASH_ENTRY_EDITED: LogCategory.CASH,
    LogAction.CASH_ENTRY_DELETED: LogCategory.CASH,
    LogAction.GOLD_RATE_UPDATED: LogCategory.ADMIN,
    LogAction.GOLD_RATE_ADDED: LogCategory.ADMIN,
    LogAction.CUSTOMER_PHOTO_UPDATED: LogCategory.ADMIN,
    LogAction.USER_ADDED: LogCategory.ADMIN,
    LogAction.USER_UPDATED: LogCategory.ADMIN,
    LogAction.USER_DEACTIVATED: LogCategory.ADMIN,
    LogAction.USER_REACTIVATED: LogCategory.ADMIN,
    LogAction.USER_DELETED: LogCategory.ADMIN,
    LogAction.ITEM_RESERVED: LogCategory.SALE,
    LogAction.RESERVATION_RELEASED: LogCategory.SALE,
    LogAction.CUSTOMER_ADDED: LogCategory.ADMIN,
    LogAction.CUSTOMER_UPDATED: LogCategory.ADMIN,
    LogAction.RECEIPT_ISSUED: LogCategory.ADMIN,
    LogAction.SNAPSHOT_IMPORTED: LogCategory.ADMIN,
}

# Actions the v1 phone app knows by name; anything else would make its
# SnapshotCodec throw, so phone-format exports carry only these.
PHONE_ACTIONS = frozenset(a for a in LogAction if a not in {
    LogAction.ITEM_RESERVED,
    LogAction.RESERVATION_RELEASED,
    LogAction.CUSTOMER_ADDED,
    LogAction.CUSTOMER_UPDATED,
    LogAction.RECEIPT_ISSUED,
    LogAction.SNAPSHOT_IMPORTED,
})


def category_for(action: str) -> str:
    return _CATEGORY[LogAction(action)]


def label(choices: type[models.TextChoices], value: str | None) -> str:
    """The display label of an enum value, e.g. label(Role, 'cashier') -> 'Cashier'."""
    if value is None:
        return ""
    return choices(value).label


def is_silver_purity(purity: int) -> bool:
    """Silver fineness (925, 999) is 100 and up; gold karats are 24 and under."""
    return purity >= 100


def choices_check(field: str, choices: type[models.TextChoices]):
    """A CheckConstraint condition limiting a column to an enum's values."""
    return models.Q(**{f"{field}__in": choices.values})
