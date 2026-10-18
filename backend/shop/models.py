"""The shop's records.

Ground rules, enforced here wherever a database can enforce them:

* Money is integer centavos (BigIntegerField). Weights are grams to 3 decimals.
* No balance is stored anywhere. A branch's cash is its opening figure plus its
  ledger; a commitment's balance is its amount less the disposals applied to it.
* Ids are client-chosen codes, unique across every record type — `RecordId`
  is the registry that makes "one code, one record" true in the database.
* The transaction log and the rate history are append-only; a trigger refuses
  UPDATE and DELETE on both (migration 0002).
"""

from decimal import Decimal

from django.conf import settings
from django.db import models
from django.db.models import F, Q
from django.utils import timezone

from .enums import (
    BranchId,
    CashAccount,
    CashEntrySourceType,
    CashEntryType,
    ItemStatus,
    ItemType,
    LogAction,
    LogCategory,
    LogRecordKind,
    ReceiptKind,
    Role,
    VerificationStatus,
    choices_check,
)

USER = settings.AUTH_USER_MODEL
ZERO = Decimal("0")


def grams_field(**kwargs):
    return models.DecimalField(max_digits=10, decimal_places=3, **kwargs)


# Module-level functions, so migrations can reference them by import path —
# keep these names. Each files its kind under kind/branch/YYYY/MM/ (see
# shop/media_paths.py, which also says which date each kind uses).
def customer_photo_path(instance, filename):
    from .media_paths import upload_path

    return upload_path("customers", instance, filename)


def item_photo_path(instance, filename):
    from .media_paths import upload_path

    return upload_path("items", instance, filename)


def release_proof_path(instance, filename):
    from .media_paths import upload_path

    return upload_path("release-proofs", instance, filename)


def commitment_proof_path(instance, filename):
    from .media_paths import upload_path

    return upload_path("loan-proofs", instance, filename)


def disposal_photo_path(instance, filename):
    from .media_paths import upload_path

    return upload_path("disposals", instance, filename)


def receipt_pdf_path(instance, filename):
    from .media_paths import upload_path

    return upload_path("receipts", instance, filename)


class RecordId(models.Model):
    """Every client-chosen id ever used, so one code identifies exactly one
    record across all record types. Rows stay after a permitted hard delete,
    which keeps a deleted record's code from being reused for something else
    (and keeps a re-imported snapshot from resurrecting it)."""

    id = models.CharField(primary_key=True, max_length=32)
    kind = models.CharField(max_length=24)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "shop_record_id"


class Branch(models.Model):
    """One of the two shops. Opening balances are the only stored money
    figures in the whole schema; live balances are derived from the ledger."""

    id = models.CharField(primary_key=True, max_length=16, choices=BranchId.choices)
    starting_purchase_cash_centavos = models.BigIntegerField(default=0)
    starting_sales_cash_centavos = models.BigIntegerField(default=0)
    starting_bank_centavos = models.BigIntegerField(default=0)

    class Meta:
        ordering = ["id"]
        constraints = [models.CheckConstraint(condition=choices_check("id", BranchId), name="branch_id_valid")]

    @property
    def label(self) -> str:
        return BranchId(self.id).label

    def starting_balance(self, account: str) -> int:
        return {
            CashAccount.PURCHASE: self.starting_purchase_cash_centavos,
            CashAccount.SALES: self.starting_sales_cash_centavos,
            CashAccount.BANK: self.starting_bank_centavos,
        }[CashAccount(account)]

    def __str__(self) -> str:
        return self.label


class Customer(models.Model):
    id = models.CharField(primary_key=True, max_length=32)
    name = models.CharField(max_length=160)
    # Names get typed with inconsistent spacing and casing at a counter; this
    # is the key "is this the same person?" is decided on.
    name_key = models.CharField(max_length=160, db_index=True, editable=False)
    contact_number = models.CharField(max_length=40, null=True, blank=True)
    address = models.CharField(max_length=255, null=True, blank=True)
    first_seen = models.DateTimeField(default=timezone.now)
    photo = models.ImageField(upload_to=customer_photo_path, null=True, blank=True)

    class Meta:
        ordering = ["name_key"]

    def save(self, *args, **kwargs):
        from accounts.models import name_key

        self.name = self.name.strip()
        self.name_key = name_key(self.name)
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


class CustomerSnapshot(models.Model):
    """The customer as written onto one transaction — a copy, so a receipt
    keeps saying what it said on the day. The photo is deliberately not part
    of it: screens show the customer's current photo."""

    customer_name = models.CharField(max_length=160)
    customer_contact_number = models.CharField(max_length=40, null=True, blank=True)
    customer_address = models.CharField(max_length=255, null=True, blank=True)
    customer = models.ForeignKey(Customer, null=True, blank=True, on_delete=models.PROTECT, related_name="+")

    class Meta:
        abstract = True


class PurchaseBatch(CustomerSnapshot):
    """One customer visit: everything bought from one person at one counter
    visit. The unit a Cashier verifies and releases cash against."""

    id = models.CharField(primary_key=True, max_length=32)
    branch = models.ForeignKey(Branch, on_delete=models.PROTECT, related_name="purchase_batches")
    date = models.DateTimeField()
    submitted_by_role = models.CharField(max_length=24, choices=Role.choices)
    verification_status = models.CharField(
        max_length=24, choices=VerificationStatus.choices, default=VerificationStatus.AWAITING
    )
    verification_note = models.TextField(null=True, blank=True)
    released_at = models.DateTimeField(null=True, blank=True)
    submitted_by = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    released_by = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    release_proof_photo = models.ImageField(upload_to=release_proof_path, null=True, blank=True)

    class Meta:
        ordering = ["-date"]
        verbose_name_plural = "purchase batches"
        constraints = [
            models.CheckConstraint(condition=choices_check("submitted_by_role", Role), name="batch_role_valid"),
            models.CheckConstraint(
                condition=choices_check("verification_status", VerificationStatus), name="batch_verification_valid"
            ),
        ]
        indexes = [models.Index(fields=["branch", "verification_status"])]

    def __str__(self) -> str:
        return f"Purchase {self.id} from {self.customer_name}"


class Item(models.Model):
    """A piece of metal. `weight_grams` is always the net weight — what the
    shop paid for and every figure works from."""

    id = models.CharField(primary_key=True, max_length=32)
    description = models.CharField(max_length=255)
    weight_grams = grams_field()
    gross_weight_grams = grams_field(null=True, blank=True)
    # Gold karat (24 and under) or silver fineness (100 and up), per `type`.
    karat = models.PositiveIntegerField()
    type = models.CharField(max_length=12, choices=ItemType.choices)
    capital_amount_centavos = models.BigIntegerField()
    origin = models.CharField(max_length=160)
    branch = models.ForeignKey(Branch, on_delete=models.PROTECT, related_name="items")
    item_status = models.CharField(max_length=16, choices=ItemStatus.choices, default=ItemStatus.PENDING)
    verification_status = models.CharField(
        max_length=24, choices=VerificationStatus.choices, default=VerificationStatus.AWAITING
    )
    purchase_date = models.DateTimeField()
    submitted_by_role = models.CharField(max_length=24, choices=Role.choices)
    photo = models.ImageField(upload_to=item_photo_path, null=True, blank=True)
    encoded_by = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    batch = models.ForeignKey(PurchaseBatch, null=True, blank=True, on_delete=models.PROTECT, related_name="items")
    verification_note = models.TextField(null=True, blank=True)

    # Partitioning: a piece drawn out of a larger lot points at it; the lot
    # freezes its original figures and tracks what remains. All four stay
    # null until the lot's first partition is drawn.
    parent_lot = models.ForeignKey("self", null=True, blank=True, on_delete=models.PROTECT, related_name="partitions")
    original_grams = grams_field(null=True, blank=True)
    original_amount_centavos = models.BigIntegerField(null=True, blank=True)
    remaining_grams = grams_field(null=True, blank=True)
    remaining_amount_centavos = models.BigIntegerField(null=True, blank=True)

    # Position within its purchase, so lines read back in the order entered.
    line_no = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["-purchase_date", "id"]
        constraints = [
            models.CheckConstraint(condition=choices_check("type", ItemType), name="item_type_valid"),
            models.CheckConstraint(condition=choices_check("item_status", ItemStatus), name="item_status_valid"),
            models.CheckConstraint(
                condition=choices_check("verification_status", VerificationStatus), name="item_verification_valid"
            ),
            models.CheckConstraint(condition=choices_check("submitted_by_role", Role), name="item_role_valid"),
            # Purity must match the metal: silver fineness 100–999, gold karat 1–24.
            models.CheckConstraint(
                condition=(Q(type=ItemType.SILVER, karat__gte=100, karat__lte=999)
                           | (~Q(type=ItemType.SILVER) & Q(karat__gte=1, karat__lte=24))),
                name="item_purity_matches_metal",
            ),
            models.CheckConstraint(condition=Q(weight_grams__gte=0), name="item_weight_not_negative"),
            models.CheckConstraint(condition=Q(capital_amount_centavos__gte=0), name="item_amount_not_negative"),
            models.CheckConstraint(
                condition=Q(gross_weight_grams__isnull=True) | Q(gross_weight_grams__gte=F("weight_grams")),
                name="item_gross_at_least_net",
            ),
            # A partition can never draw more than remains.
            models.CheckConstraint(
                condition=Q(remaining_grams__isnull=True) | Q(remaining_grams__gte=0), name="item_remaining_grams_ok"
            ),
            models.CheckConstraint(
                condition=Q(remaining_amount_centavos__isnull=True) | Q(remaining_amount_centavos__gte=0),
                name="item_remaining_amount_ok",
            ),
            models.CheckConstraint(condition=~Q(parent_lot=F("id")), name="item_not_own_parent"),
        ]
        indexes = [
            models.Index(fields=["branch", "item_status"]),
            models.Index(fields=["branch", "type", "item_status"]),
        ]

    # --- the app's `effective*` getters -------------------------------------
    @property
    def is_partition(self) -> bool:
        return self.parent_lot_id is not None

    @property
    def has_partitions(self) -> bool:
        return self.original_grams is not None

    @property
    def effective_gross_grams(self) -> Decimal:
        return self.gross_weight_grams if self.gross_weight_grams is not None else self.weight_grams

    @property
    def deducted_grams(self) -> Decimal:
        return self.effective_gross_grams - self.weight_grams

    @property
    def effective_original_grams(self) -> Decimal:
        return self.original_grams if self.original_grams is not None else self.weight_grams

    @property
    def effective_original_amount(self) -> int:
        return self.original_amount_centavos if self.original_amount_centavos is not None else self.capital_amount_centavos

    @property
    def effective_remaining_grams(self) -> Decimal:
        return self.remaining_grams if self.remaining_grams is not None else self.weight_grams

    @property
    def effective_remaining_amount(self) -> int:
        return (self.remaining_amount_centavos if self.remaining_amount_centavos is not None
                else self.capital_amount_centavos)

    @property
    def is_exhausted(self) -> bool:
        return self.has_partitions and self.effective_remaining_grams <= 0 and self.effective_remaining_amount <= 0

    @property
    def can_return_to_parent(self) -> bool:
        return self.is_partition and self.item_status in (
            ItemStatus.PENDING, ItemStatus.LISTED, ItemStatus.FOR_DISPOSAL
        )

    @property
    def is_silver(self) -> bool:
        return self.type == ItemType.SILVER

    def __str__(self) -> str:
        return f"{self.id} {self.description}"


class Sale(CustomerSnapshot):
    """A customer order. The payment is the customer's stated intent until a
    Cashier receives it; nothing moves in the ledger before that."""

    id = models.CharField(primary_key=True, max_length=32)
    note = models.TextField(null=True, blank=True)
    cash_centavos = models.BigIntegerField(default=0)
    bank_centavos = models.BigIntegerField(default=0)
    verification_status = models.CharField(
        max_length=24, choices=VerificationStatus.choices, default=VerificationStatus.AWAITING
    )
    verification_note = models.TextField(null=True, blank=True)
    branch = models.ForeignKey(Branch, on_delete=models.PROTECT, related_name="sales")
    date = models.DateTimeField()
    submitted_by_role = models.CharField(max_length=24, choices=Role.choices)
    submitted_by = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    received_by = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")

    class Meta:
        ordering = ["-date"]
        constraints = [
            models.CheckConstraint(condition=Q(cash_centavos__gte=0, bank_centavos__gte=0), name="sale_payment_not_negative"),
            models.CheckConstraint(
                condition=choices_check("verification_status", VerificationStatus), name="sale_verification_valid"
            ),
            models.CheckConstraint(condition=choices_check("submitted_by_role", Role), name="sale_role_valid"),
        ]
        indexes = [models.Index(fields=["branch", "verification_status"])]

    @property
    def is_open(self) -> bool:
        return self.verification_status != VerificationStatus.VERIFIED

    @property
    def total_centavos(self) -> int:
        return sum(line.negotiated_price_centavos for line in self.lines.all())

    def __str__(self) -> str:
        return f"Sale {self.id} to {self.customer_name}"


class SaleLineItem(models.Model):
    sale = models.ForeignKey(Sale, on_delete=models.CASCADE, related_name="lines")
    item = models.ForeignKey(Item, on_delete=models.PROTECT, related_name="sale_lines")
    position = models.PositiveIntegerField(default=0)
    negotiated_price_centavos = models.BigIntegerField()
    # Weight the piece is sold at; null means "its own net weight".
    final_grams = grams_field(null=True, blank=True)
    # The item as it stood when the line was written (refreshed when the sale
    # completes), so a finished sale still prints what was sold even if the
    # piece is later corrected. Same shape as the phone's item JSON.
    item_snapshot = models.JSONField(default=dict)

    class Meta:
        ordering = ["sale", "position"]
        constraints = [
            models.UniqueConstraint(fields=["sale", "item"], name="sale_line_item_once"),
            models.CheckConstraint(condition=Q(negotiated_price_centavos__gt=0), name="sale_line_price_positive"),
            models.CheckConstraint(condition=Q(final_grams__isnull=True) | Q(final_grams__gt=0), name="sale_line_grams_positive"),
        ]

    @property
    def effective_final_grams(self) -> Decimal:
        return self.final_grams if self.final_grams is not None else self.item.weight_grams

    @property
    def price_per_gram_centavos(self) -> int:
        grams = self.effective_final_grams
        if grams <= 0:
            return 0
        return int((Decimal(self.negotiated_price_centavos) / grams).quantize(Decimal("1"), rounding="ROUND_HALF_UP"))


class Commitment(models.Model):
    """A cash loan repaid in scrap. Balance, repaid amount and status are
    derived from the disposal batches applied to it — never stored."""

    id = models.CharField(primary_key=True, max_length=32)
    lender = models.CharField(max_length=160)
    amount_centavos = models.BigIntegerField()
    rate_per_gram_centavos = models.BigIntegerField()
    branch = models.ForeignKey(Branch, null=True, blank=True, on_delete=models.PROTECT, related_name="commitments")
    date_approved = models.DateTimeField()
    date_received = models.DateTimeField(null=True, blank=True)
    received_proof_photo = models.ImageField(upload_to=commitment_proof_path, null=True, blank=True)

    class Meta:
        ordering = ["-date_approved"]
        constraints = [
            models.CheckConstraint(condition=Q(amount_centavos__gt=0), name="commitment_amount_positive"),
            models.CheckConstraint(condition=Q(rate_per_gram_centavos__gt=0), name="commitment_rate_positive"),
        ]

    def __str__(self) -> str:
        return f"{self.lender} {self.id}"


class DisposalBatch(models.Model):
    """Scrap (or silver) sold off to settle a loan. Moves no cash; the gross
    pays down the commitment."""

    id = models.CharField(primary_key=True, max_length=32)
    branch = models.ForeignKey(Branch, on_delete=models.PROTECT, related_name="disposals")
    items = models.ManyToManyField(Item, through="DisposalItem", related_name="disposals")
    capital_centavos = models.BigIntegerField()
    gross_grams = grams_field()
    gross_amount_centavos = models.BigIntegerField()
    commitment = models.ForeignKey(Commitment, on_delete=models.PROTECT, related_name="disposals")
    date = models.DateTimeField()
    photo = models.ImageField(upload_to=disposal_photo_path, null=True, blank=True)

    class Meta:
        ordering = ["-date"]
        verbose_name_plural = "disposal batches"
        constraints = [
            models.CheckConstraint(condition=Q(capital_centavos__gte=0), name="disposal_capital_not_negative"),
            models.CheckConstraint(condition=Q(gross_grams__gte=0), name="disposal_grams_not_negative"),
            models.CheckConstraint(condition=Q(gross_amount_centavos__gte=0), name="disposal_gross_not_negative"),
        ]

    @property
    def net_centavos(self) -> int:
        return self.gross_amount_centavos - self.capital_centavos

    def ordered_items(self) -> list[Item]:
        return [link.item for link in self.links.select_related("item").order_by("position")]


class DisposalItem(models.Model):
    batch = models.ForeignKey(DisposalBatch, on_delete=models.CASCADE, related_name="links")
    item = models.ForeignKey(Item, on_delete=models.PROTECT, related_name="disposal_links")
    position = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["batch", "position"]
        constraints = [
            # A piece leaves the shop once.
            models.UniqueConstraint(fields=["item"], name="disposal_item_once"),
        ]


class CashEntry(models.Model):
    """The one place money moves. Every balance is an opening figure plus
    these rows; nothing else may move a balance."""

    id = models.CharField(primary_key=True, max_length=32)
    branch = models.ForeignKey(Branch, on_delete=models.PROTECT, related_name="cash_entries")
    type = models.CharField(max_length=16, choices=CashEntryType.choices)
    account = models.CharField(max_length=12, choices=CashAccount.choices, default=CashAccount.PURCHASE)
    amount_centavos = models.BigIntegerField()
    note = models.TextField()
    category = models.CharField(max_length=60, null=True, blank=True)
    date = models.DateTimeField()
    recorded_by_role = models.CharField(max_length=24, choices=Role.choices)
    recorded_by = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    source_type = models.CharField(max_length=12, choices=CashEntrySourceType.choices, default=CashEntrySourceType.MANUAL)
    linked_record_id = models.CharField(max_length=32, null=True, blank=True)
    transfer_pair_id = models.CharField(max_length=32, null=True, blank=True)

    class Meta:
        ordering = ["-date", "id"]
        verbose_name_plural = "cash entries"
        constraints = [
            models.CheckConstraint(condition=choices_check("type", CashEntryType), name="cash_type_valid"),
            models.CheckConstraint(condition=choices_check("account", CashAccount), name="cash_account_valid"),
            models.CheckConstraint(condition=choices_check("source_type", CashEntrySourceType), name="cash_source_valid"),
            models.CheckConstraint(condition=choices_check("recorded_by_role", Role), name="cash_role_valid"),
            models.CheckConstraint(condition=Q(amount_centavos__gt=0), name="cash_amount_positive"),
            models.CheckConstraint(condition=~Q(note=""), name="cash_note_required"),
            # Linked entries point at their source; manual ones point nowhere.
            models.CheckConstraint(
                condition=(Q(source_type=CashEntrySourceType.MANUAL, linked_record_id__isnull=True)
                           | (~Q(source_type=CashEntrySourceType.MANUAL) & Q(linked_record_id__isnull=False))),
                name="cash_link_matches_source",
            ),
            # Both halves of a transfer carry the pair id; nothing else does.
            models.CheckConstraint(
                condition=(Q(type__in=[CashEntryType.TRANSFER_IN, CashEntryType.TRANSFER_OUT], transfer_pair_id__isnull=False)
                           | (~Q(type__in=[CashEntryType.TRANSFER_IN, CashEntryType.TRANSFER_OUT])
                              & Q(transfer_pair_id__isnull=True))),
                name="cash_transfer_has_pair",
            ),
            models.CheckConstraint(
                condition=Q(category__isnull=True) | Q(type=CashEntryType.EXPENSE), name="cash_category_expense_only"
            ),
        ]
        indexes = [
            models.Index(fields=["branch", "account", "date"]),
            models.Index(fields=["linked_record_id"]),
            models.Index(fields=["transfer_pair_id"]),
        ]

    @property
    def is_manual(self) -> bool:
        return self.source_type == CashEntrySourceType.MANUAL

    @property
    def is_transfer(self) -> bool:
        return self.transfer_pair_id is not None

    @property
    def signed_amount_centavos(self) -> int:
        from .enums import CREDIT_TYPES

        return self.amount_centavos if self.type in CREDIT_TYPES else -self.amount_centavos


class GoldRate(models.Model):
    """The buying rate for one purity: a gold karat or a silver fineness."""

    karat = models.PositiveIntegerField(primary_key=True)
    price_per_gram_centavos = models.BigIntegerField()
    updated_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-karat"]
        constraints = [
            models.CheckConstraint(condition=Q(price_per_gram_centavos__gt=0), name="rate_price_positive"),
            models.CheckConstraint(
                condition=Q(karat__gte=1, karat__lte=24) | Q(karat__gte=100, karat__lte=999), name="rate_purity_valid"
            ),
        ]


class RateChange(models.Model):
    """One entry in a purity's price history. Never updated, never deleted."""

    karat = models.PositiveIntegerField(db_index=True)
    before_centavos = models.BigIntegerField(null=True, blank=True)
    after_centavos = models.BigIntegerField()
    at = models.DateTimeField()
    user = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    user_name = models.CharField(max_length=120)
    # The day whose prices this change put back, when it was a restore.
    restored_from = models.DateField(null=True, blank=True)

    class Meta:
        ordering = ["-at", "-id"]
        constraints = [
            models.CheckConstraint(condition=Q(after_centavos__gt=0), name="rate_change_after_positive"),
            # What makes a history row "the same row" when a snapshot is
            # imported twice — the phone gives these rows no id.
            models.UniqueConstraint(fields=["karat", "at", "after_centavos"], name="rate_change_natural_key"),
        ]


class StoredReceipt(models.Model):
    """The shop's own copy of a receipt it issued. One current receipt per
    record — re-issuing replaces the document, keeping the receipt's id."""

    id = models.CharField(primary_key=True, max_length=32)
    record_id = models.CharField(max_length=32, unique=True)
    kind = models.CharField(max_length=12, choices=ReceiptKind.choices)
    branch = models.ForeignKey(Branch, on_delete=models.PROTECT, related_name="receipts")
    counterparty = models.CharField(max_length=160)
    total_centavos = models.BigIntegerField()
    issued_at = models.DateTimeField()
    pdf = models.FileField(upload_to=receipt_pdf_path)
    text = models.TextField(blank=True, default="")

    class Meta:
        ordering = ["-issued_at"]
        constraints = [models.CheckConstraint(condition=choices_check("kind", ReceiptKind), name="receipt_kind_valid")]

    @property
    def filename(self) -> str:
        return f"{self.kind}-{self.record_id}.pdf"


class TransactionLog(models.Model):
    """Who did what, when, to which record. Append-only: the database refuses
    UPDATE and DELETE on this table."""

    id = models.CharField(primary_key=True, max_length=32)
    # When it happened — for a change made offline, when it was made on the phone.
    at = models.DateTimeField()
    # When the server wrote it. Equal to `at` for online requests.
    received_at = models.DateTimeField(default=timezone.now)
    action = models.CharField(max_length=32, choices=LogAction.choices)
    category = models.CharField(max_length=12, choices=LogCategory.choices)
    user = models.ForeignKey(USER, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    # Denormalised so the entry still reads correctly if the person is renamed.
    user_name = models.CharField(max_length=120)
    role = models.CharField(max_length=24, choices=Role.choices)
    summary = models.TextField()
    branch = models.ForeignKey(Branch, null=True, blank=True, on_delete=models.PROTECT, related_name="+")
    record_id = models.CharField(max_length=32, null=True, blank=True, db_index=True)
    record_kind = models.CharField(max_length=16, choices=LogRecordKind.choices, null=True, blank=True)
    amount_centavos = models.BigIntegerField(null=True, blank=True)
    # [{"field": ..., "before": ..., "after": ...}] — strings, as the app writes them.
    changes = models.JSONField(default=list, blank=True)

    class Meta:
        ordering = ["-at", "-id"]
        constraints = [
            models.CheckConstraint(condition=choices_check("action", LogAction), name="log_action_valid"),
            models.CheckConstraint(condition=choices_check("category", LogCategory), name="log_category_valid"),
            models.CheckConstraint(condition=choices_check("role", Role), name="log_role_valid"),
            models.CheckConstraint(
                condition=Q(record_kind__isnull=True) | choices_check("record_kind", LogRecordKind),
                name="log_record_kind_valid",
            ),
        ]
        indexes = [
            models.Index(fields=["branch", "at"]),
            models.Index(fields=["category", "at"]),
            models.Index(fields=["user", "at"]),
        ]

    def save(self, *args, **kwargs):
        if not self._state.adding:
            raise RuntimeError("The transaction log is append-only")
        super().save(*args, **kwargs)

    def delete(self, *args, **kwargs):
        raise RuntimeError("The transaction log is append-only")


class IdempotencyRecord(models.Model):
    """The first response to a write sent with an Idempotency-Key, so a
    replay returns it instead of acting twice."""

    key = models.CharField(max_length=128)
    user = models.ForeignKey(USER, on_delete=models.CASCADE, related_name="+")
    method = models.CharField(max_length=8)
    path = models.CharField(max_length=255)
    fingerprint = models.CharField(max_length=64)
    status_code = models.PositiveSmallIntegerField()
    body = models.JSONField(null=True)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "shop_idempotency_record"
        constraints = [models.UniqueConstraint(fields=["user", "key"], name="idempotency_key_per_user")]


class SyncChange(models.Model):
    """An append-only feed of which records changed, in commit order, for the
    phone's "changes since" pull. Writes are serialised (one writer at a time),
    so `seq` order is commit order and a cursor never skips a change."""

    seq = models.BigAutoField(primary_key=True)
    kind = models.CharField(max_length=24)
    record_id = models.CharField(max_length=64)
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = "shop_sync_change"
        indexes = [models.Index(fields=["kind", "record_id"])]
