"""Output serializers: how each record reads over the API.

Money is integer centavos, weights are strings with 3 decimals, dates are
ISO-8601 with the Manila offset, enums are the app's names. People are named,
not just referenced, so a client never needs a second lookup to show "Grace
Ramos released ₱26,100".
"""

from rest_framework import serializers

from accounts.models import User

from ..enums import ItemType, VerificationStatus
from ..models import (
    CashEntry,
    Commitment,
    Customer,
    DisposalBatch,
    Item,
    PurchaseBatch,
    RateChange,
    Sale,
    SaleLineItem,
    StoredReceipt,
    TransactionLog,
)
from ..text import karat_text

GRAMS = {"max_digits": 10, "decimal_places": 3, "coerce_to_string": True}


def photo_url(request, field) -> str | None:
    if not field:
        return None
    url = field.url
    return request.build_absolute_uri(url) if request is not None else url


class PersonSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "name", "role"]


class PhotoUrlField(serializers.Field):
    """Reads an ImageField as an absolute URL (or null)."""

    def __init__(self, **kwargs):
        kwargs["read_only"] = True
        super().__init__(**kwargs)

    def get_attribute(self, instance):
        return getattr(instance, self.source)

    def to_representation(self, value):
        return photo_url(self.context.get("request"), value)


class ItemSerializer(serializers.ModelSerializer):
    weight_grams = serializers.DecimalField(**GRAMS)
    gross_weight_grams = serializers.DecimalField(**GRAMS, allow_null=True)
    deducted_grams = serializers.DecimalField(**GRAMS)
    original_grams = serializers.DecimalField(**GRAMS, allow_null=True)
    remaining_grams = serializers.DecimalField(**GRAMS, allow_null=True)
    effective_original_grams = serializers.DecimalField(**GRAMS)
    effective_remaining_grams = serializers.DecimalField(**GRAMS)
    effective_original_amount_centavos = serializers.IntegerField(source="effective_original_amount")
    effective_remaining_amount_centavos = serializers.IntegerField(source="effective_remaining_amount")
    purity = serializers.SerializerMethodField()
    photo_url = PhotoUrlField(source="photo")
    encoded_by = PersonSerializer(allow_null=True)
    is_partition = serializers.BooleanField()
    has_partitions = serializers.BooleanField()
    is_exhausted = serializers.BooleanField()
    can_edit = serializers.SerializerMethodField()
    batch_id = serializers.CharField(allow_null=True)
    parent_lot_id = serializers.CharField(allow_null=True)

    class Meta:
        model = Item
        fields = [
            "id", "description", "type", "karat", "purity", "weight_grams", "gross_weight_grams",
            "deducted_grams", "capital_amount_centavos", "origin", "branch", "item_status",
            "verification_status", "verification_note", "purchase_date", "submitted_by_role", "encoded_by",
            "batch_id", "photo_url", "parent_lot_id", "original_grams", "original_amount_centavos",
            "remaining_grams", "remaining_amount_centavos", "effective_original_grams",
            "effective_original_amount_centavos", "effective_remaining_grams",
            "effective_remaining_amount_centavos", "is_partition", "has_partitions", "is_exhausted", "can_edit",
        ]

    def get_purity(self, item) -> str:
        return karat_text(item.karat)

    def get_can_edit(self, item) -> bool:
        from ..services.items import can_edit

        return can_edit(item)


class ItemDetailSerializer(ItemSerializer):
    partitions = serializers.SerializerMethodField()
    parent_lot = serializers.SerializerMethodField()

    class Meta(ItemSerializer.Meta):
        fields = ItemSerializer.Meta.fields + ["partitions", "parent_lot"]

    def get_partitions(self, item):
        pieces = item.partitions.order_by("-purchase_date")
        return ItemSerializer(pieces, many=True, context=self.context).data

    def get_parent_lot(self, item):
        if item.parent_lot_id is None:
            return None
        return ItemSerializer(item.parent_lot, context=self.context).data


class CustomerSnapshotField(serializers.Field):
    """The customer as written on a transaction, plus the live record's photo."""

    def __init__(self, **kwargs):
        kwargs["read_only"] = True
        kwargs["source"] = "*"
        super().__init__(**kwargs)

    def to_representation(self, record):
        customer = record.customer
        return {
            "id": record.customer_id,
            "name": record.customer_name,
            "contact_number": record.customer_contact_number,
            "address": record.customer_address,
            "photo_url": photo_url(self.context.get("request"), customer.photo if customer else None),
        }


class PurchaseBatchSerializer(serializers.ModelSerializer):
    customer = CustomerSnapshotField()
    submitted_by = PersonSerializer(allow_null=True)
    released_by = PersonSerializer(allow_null=True)
    release_proof_photo_url = PhotoUrlField(source="release_proof_photo")
    items = serializers.SerializerMethodField()
    total_centavos = serializers.SerializerMethodField()
    cash_entry_id = serializers.SerializerMethodField()

    class Meta:
        model = PurchaseBatch
        fields = [
            "id", "customer", "branch", "date", "submitted_by_role", "verification_status",
            "verification_note", "released_at", "submitted_by", "released_by", "release_proof_photo_url",
            "total_centavos", "cash_entry_id", "items",
        ]

    def get_items(self, batch):
        from ..services.purchases import lines_of

        return ItemSerializer(lines_of(batch), many=True, context=self.context).data

    def get_total_centavos(self, batch) -> int:
        from ..services.purchases import batch_total

        return batch_total(batch)

    def get_cash_entry_id(self, batch):
        entry = CashEntry.objects.filter(linked_record_id=batch.id).only("id").first()
        return entry.id if entry else None


class CustomerSerializer(serializers.ModelSerializer):
    photo_url = PhotoUrlField(source="photo")

    class Meta:
        model = Customer
        fields = ["id", "name", "contact_number", "address", "first_seen", "photo_url"]


class CustomerDetailSerializer(CustomerSerializer):
    purchases = serializers.SerializerMethodField()
    sales = serializers.SerializerMethodField()

    class Meta(CustomerSerializer.Meta):
        fields = CustomerSerializer.Meta.fields + ["purchases", "sales"]

    def _branch(self):
        return self.context.get("branch")

    def get_purchases(self, customer):
        from ..services.purchases import batch_total, lines_of

        batches = PurchaseBatch.objects.filter(customer=customer).order_by("-date")
        if self._branch():
            batches = batches.filter(branch_id=self._branch())
        return [{
            "id": b.id, "branch": b.branch_id, "date": serializers.DateTimeField().to_representation(b.date),
            "verification_status": b.verification_status, "item_count": len(lines_of(b)),
            "total_centavos": batch_total(b),
        } for b in batches]

    def get_sales(self, customer):
        sales = Sale.objects.filter(customer=customer).order_by("-date").prefetch_related("lines")
        if self._branch():
            sales = sales.filter(branch_id=self._branch())
        return [{
            "id": s.id, "branch": s.branch_id, "date": serializers.DateTimeField().to_representation(s.date),
            "verification_status": s.verification_status, "item_count": s.lines.count(),
            "total_centavos": s.total_centavos,
        } for s in sales]


class SaleLineSerializer(serializers.ModelSerializer):
    item_id = serializers.CharField()
    final_grams = serializers.DecimalField(**GRAMS, allow_null=True)
    effective_final_grams = serializers.DecimalField(**GRAMS)
    price_per_gram_centavos = serializers.IntegerField()
    item = serializers.SerializerMethodField()

    class Meta:
        model = SaleLineItem
        fields = ["item_id", "negotiated_price_centavos", "final_grams", "effective_final_grams",
                  "price_per_gram_centavos", "item"]

    def get_item(self, line):
        """A completed sale shows the piece as it was sold; an open one, as it is."""
        if line.sale.verification_status == VerificationStatus.VERIFIED and line.item_snapshot:
            snap = line.item_snapshot
            return {"id": snap.get("id"), "description": snap.get("description"), "type": snap.get("type"),
                    "karat": snap.get("karat"), "purity": karat_text(snap.get("karat") or 0),
                    "weight_grams": f"{snap.get('weight', 0):.3f}", "as_sold": True}
        return {**ItemSerializer(line.item, context=self.context).data, "as_sold": False}


class SaleSerializer(serializers.ModelSerializer):
    customer = CustomerSnapshotField()
    submitted_by = PersonSerializer(allow_null=True)
    received_by = PersonSerializer(allow_null=True)
    lines = serializers.SerializerMethodField()
    total_centavos = serializers.SerializerMethodField()
    payment = serializers.SerializerMethodField()
    cash_entry_ids = serializers.SerializerMethodField()

    class Meta:
        model = Sale
        fields = [
            "id", "customer", "note", "branch", "date", "submitted_by_role", "verification_status",
            "verification_note", "submitted_by", "received_by", "total_centavos", "payment", "cash_entry_ids",
            "lines",
        ]

    def get_lines(self, sale):
        lines = sale.lines.select_related("item", "sale").order_by("position")
        return SaleLineSerializer(lines, many=True, context=self.context).data

    def get_total_centavos(self, sale) -> int:
        return sale.total_centavos

    def get_payment(self, sale) -> dict:
        cash, bank = sale.cash_centavos, sale.bank_centavos
        label = "Cash + Bank" if cash > 0 and bank > 0 else ("Bank Transfer" if bank > 0 and cash == 0 else "Cash")
        return {"cash_centavos": cash, "bank_centavos": bank, "total_centavos": cash + bank, "label": label}

    def get_cash_entry_ids(self, sale) -> list[str]:
        return list(CashEntry.objects.filter(linked_record_id=sale.id).values_list("id", flat=True))


class CashEntrySerializer(serializers.ModelSerializer):
    recorded_by = PersonSerializer(allow_null=True)
    signed_amount_centavos = serializers.IntegerField()
    is_manual = serializers.BooleanField()
    locked_reason = serializers.SerializerMethodField()

    class Meta:
        model = CashEntry
        fields = ["id", "branch", "type", "account", "amount_centavos", "signed_amount_centavos", "note",
                  "category", "date", "recorded_by_role", "recorded_by", "source_type", "linked_record_id",
                  "transfer_pair_id", "is_manual", "locked_reason"]

    def get_locked_reason(self, entry):
        from ..services.cash import lock_reason

        return lock_reason(entry)


class CommitmentSerializer(serializers.ModelSerializer):
    received_proof_photo_url = PhotoUrlField(source="received_proof_photo")
    ledger = serializers.SerializerMethodField()

    class Meta:
        model = Commitment
        fields = ["id", "lender", "amount_centavos", "rate_per_gram_centavos", "branch", "date_approved",
                  "date_received", "received_proof_photo_url", "ledger"]

    def get_ledger(self, commitment):
        from ..services.commitments import ledger

        return ledger(commitment).as_dict()


class DisposalBatchSerializer(serializers.ModelSerializer):
    gross_grams = serializers.DecimalField(**GRAMS)
    net_centavos = serializers.IntegerField()
    photo_url = PhotoUrlField(source="photo")
    commitment_id = serializers.CharField()
    lender = serializers.CharField(source="commitment.lender")
    item_ids = serializers.SerializerMethodField()

    class Meta:
        model = DisposalBatch
        fields = ["id", "branch", "item_ids", "capital_centavos", "gross_grams", "gross_amount_centavos",
                  "net_centavos", "commitment_id", "lender", "date", "photo_url"]

    def get_item_ids(self, batch):
        return list(batch.links.order_by("position").values_list("item_id", flat=True))


class DisposalDetailSerializer(DisposalBatchSerializer):
    items = serializers.SerializerMethodField()
    karat_breakdown = serializers.SerializerMethodField()

    class Meta(DisposalBatchSerializer.Meta):
        fields = DisposalBatchSerializer.Meta.fields + ["items", "karat_breakdown"]

    def get_items(self, batch):
        return ItemSerializer(batch.ordered_items(), many=True, context=self.context).data

    def get_karat_breakdown(self, batch):
        from ..services.disposal import karat_breakdown

        return [{"karat": k, "purity": karat_text(k), "grams": f"{g:.3f}"} for k, g in karat_breakdown(batch)]


class RateChangeSerializer(serializers.ModelSerializer):
    user = PersonSerializer(allow_null=True)
    delta_centavos = serializers.SerializerMethodField()
    is_initial = serializers.SerializerMethodField()
    metal = serializers.SerializerMethodField()

    class Meta:
        model = RateChange
        fields = ["id", "karat", "metal", "before_centavos", "after_centavos", "delta_centavos", "is_initial",
                  "at", "user", "user_name", "restored_from"]

    def get_delta_centavos(self, c) -> int:
        return 0 if c.before_centavos is None else c.after_centavos - c.before_centavos

    def get_is_initial(self, c) -> bool:
        return c.before_centavos is None

    def get_metal(self, c) -> str:
        return ItemType.SILVER.value if c.karat >= 100 else "gold"


class StoredReceiptSerializer(serializers.ModelSerializer):
    pdf_url = serializers.SerializerMethodField()
    filename = serializers.CharField()

    class Meta:
        model = StoredReceipt
        fields = ["id", "record_id", "kind", "branch", "counterparty", "total_centavos", "issued_at",
                  "filename", "pdf_url", "text"]

    def get_pdf_url(self, receipt):
        request = self.context.get("request")
        path = f"/api/v1/receipts/{receipt.id}/pdf"
        return request.build_absolute_uri(path) if request else path


class TransactionLogSerializer(serializers.ModelSerializer):
    action_label = serializers.SerializerMethodField()

    class Meta:
        model = TransactionLog
        fields = ["id", "at", "received_at", "action", "action_label", "category", "user_id", "user_name", "role",
                  "summary", "branch", "record_id", "record_kind", "amount_centavos", "changes"]

    def get_action_label(self, log) -> str:
        from ..enums import LogAction

        return LogAction(log.action).label
