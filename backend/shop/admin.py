"""Shop records in the admin site — view-only: browse, search, filter, open.

Changes go through the API (or the phone), where the rules run and the log is
written. Balances and loan status shown here are computed, as everywhere.
"""

from django.contrib import admin
from django.utils.html import format_html, format_html_join

from .admin_tools import ReadOnlyAdmin, ReadOnlyInline, grams, money, photo_link
from .enums import CashAccount, LogAction, Role
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
    TransactionLog,
)
from .services import cash
from .services.commitments import ledger
from .services.purchases import batch_total
from .text import karat_text


def _person(user):
    return user.name if user else "—"


# --- branches and money ----------------------------------------------------------

@admin.register(Branch)
class BranchAdmin(ReadOnlyAdmin):
    list_display = ["label", "purchase_cash", "sales_cash", "bank"]
    fields = ["id", "starting_purchase_cash", "starting_sales_cash", "starting_bank", "purchase_cash", "sales_cash",
              "bank"]
    readonly_fields = fields

    @admin.display(description="Branch")
    def label(self, obj):
        return obj.label

    @admin.display(description="Opening purchase cash")
    def starting_purchase_cash(self, obj):
        return money(obj.starting_purchase_cash_centavos)

    @admin.display(description="Opening sales cash")
    def starting_sales_cash(self, obj):
        return money(obj.starting_sales_cash_centavos)

    @admin.display(description="Opening bank")
    def starting_bank(self, obj):
        return money(obj.starting_bank_centavos)

    @admin.display(description="Purchase cash now")
    def purchase_cash(self, obj):
        return money(cash.account_balance(obj, CashAccount.PURCHASE))

    @admin.display(description="Sales cash now")
    def sales_cash(self, obj):
        return money(cash.account_balance(obj, CashAccount.SALES))

    @admin.display(description="Cash in bank now")
    def bank(self, obj):
        return money(cash.account_balance(obj, CashAccount.BANK))


@admin.register(CashEntry)
class CashEntryAdmin(ReadOnlyAdmin):
    list_display = ["date", "id", "branch", "account", "type", "signed", "note", "source_type", "linked_record_id",
                    "recorded"]
    list_filter = ["branch", "account", "type", "source_type"]
    search_fields = ["id", "note", "linked_record_id", "transfer_pair_id", "category"]
    date_hierarchy = "date"
    list_select_related = ["recorded_by"]

    @admin.display(description="Amount", ordering="amount_centavos")
    def signed(self, obj):
        return money(obj.signed_amount_centavos)

    @admin.display(description="Recorded by")
    def recorded(self, obj):
        return _person(obj.recorded_by)


# --- customers and purchases -----------------------------------------------------

@admin.register(Customer)
class CustomerAdmin(ReadOnlyAdmin):
    list_display = ["name", "id", "contact_number", "address", "first_seen"]
    search_fields = ["name", "id", "contact_number", "address"]
    date_hierarchy = "first_seen"
    readonly_fields = ["picture"]

    @admin.display(description="Photo")
    def picture(self, obj):
        return photo_link(obj.photo)


class BatchItemInline(ReadOnlyInline):
    model = Item
    fk_name = "batch"
    fields = ["id", "description", "type", "karat", "weight_grams", "capital_amount_centavos", "item_status",
              "parent_lot"]
    readonly_fields = fields
    verbose_name_plural = "Pieces (including partitions drawn from them)"


@admin.register(PurchaseBatch)
class PurchaseBatchAdmin(ReadOnlyAdmin):
    list_display = ["date", "id", "customer_name", "branch", "verification_status", "total", "submitted", "released"]
    list_filter = ["branch", "verification_status"]
    search_fields = ["id", "customer_name", "items__id", "items__description"]
    date_hierarchy = "date"
    list_select_related = ["submitted_by", "released_by"]
    readonly_fields = ["proof"]
    inlines = [BatchItemInline]

    @admin.display(description="Total")
    def total(self, obj):
        return money(batch_total(obj))

    @admin.display(description="Encoded by")
    def submitted(self, obj):
        return _person(obj.submitted_by)

    @admin.display(description="Released by")
    def released(self, obj):
        return _person(obj.released_by)

    @admin.display(description="Proof of cash released")
    def proof(self, obj):
        return photo_link(obj.release_proof_photo)


@admin.register(Item)
class ItemAdmin(ReadOnlyAdmin):
    list_display = ["id", "description", "type", "purity", "net", "capital", "branch", "item_status",
                    "verification_status", "batch"]
    list_filter = ["branch", "type", "item_status", "verification_status", "karat"]
    search_fields = ["id", "description", "origin", "batch__id"]
    date_hierarchy = "purchase_date"
    readonly_fields = ["picture"]

    @admin.display(description="Purity", ordering="karat")
    def purity(self, obj):
        return karat_text(obj.karat)

    @admin.display(description="Net weight", ordering="weight_grams")
    def net(self, obj):
        return grams(obj.weight_grams)

    @admin.display(description="Capital", ordering="capital_amount_centavos")
    def capital(self, obj):
        return money(obj.capital_amount_centavos)

    @admin.display(description="Photo")
    def picture(self, obj):
        return photo_link(obj.photo)


# --- sales -----------------------------------------------------------------------

class SaleLineInline(ReadOnlyInline):
    model = SaleLineItem
    fields = ["item", "negotiated_price_centavos", "final_grams"]
    readonly_fields = fields
    show_change_link = False


@admin.register(Sale)
class SaleAdmin(ReadOnlyAdmin):
    list_display = ["date", "id", "customer_name", "branch", "verification_status", "total", "cash", "bank",
                    "submitted", "received"]
    list_filter = ["branch", "verification_status"]
    search_fields = ["id", "customer_name", "lines__item__id", "lines__item__description"]
    date_hierarchy = "date"
    list_select_related = ["submitted_by", "received_by"]
    inlines = [SaleLineInline]

    @admin.display(description="Total")
    def total(self, obj):
        return money(obj.total_centavos)

    @admin.display(description="Cash", ordering="cash_centavos")
    def cash(self, obj):
        return money(obj.cash_centavos)

    @admin.display(description="Bank", ordering="bank_centavos")
    def bank(self, obj):
        return money(obj.bank_centavos)

    @admin.display(description="Sales rep")
    def submitted(self, obj):
        return _person(obj.submitted_by)

    @admin.display(description="Received by")
    def received(self, obj):
        return _person(obj.received_by)


# --- loans and disposal ------------------------------------------------------------

@admin.register(Commitment)
class CommitmentAdmin(ReadOnlyAdmin):
    list_display = ["lender", "id", "branch", "amount", "status", "repaid", "remaining", "date_approved",
                    "date_received"]
    list_filter = ["branch"]
    search_fields = ["id", "lender"]
    readonly_fields = ["status", "repaid", "remaining", "proof"]

    @admin.display(description="Amount", ordering="amount_centavos")
    def amount(self, obj):
        return money(obj.amount_centavos)

    @admin.display(description="Status")
    def status(self, obj):
        return ledger(obj).as_dict()["status_label"]

    @admin.display(description="Repaid")
    def repaid(self, obj):
        return money(ledger(obj).repaid_centavos)

    @admin.display(description="Left to pay")
    def remaining(self, obj):
        return money(ledger(obj).remaining_centavos)

    @admin.display(description="Proof of cash received")
    def proof(self, obj):
        return photo_link(obj.received_proof_photo)


class DisposalItemInline(ReadOnlyInline):
    model = DisposalItem
    fields = ["item", "position"]
    readonly_fields = fields
    show_change_link = False


@admin.register(DisposalBatch)
class DisposalBatchAdmin(ReadOnlyAdmin):
    list_display = ["date", "id", "branch", "lender", "gross_weight", "gross", "capital", "net"]
    list_filter = ["branch"]
    search_fields = ["id", "commitment__lender", "links__item__id"]
    date_hierarchy = "date"
    list_select_related = ["commitment"]
    inlines = [DisposalItemInline]

    @admin.display(description="Applied to")
    def lender(self, obj):
        return obj.commitment.lender

    @admin.display(description="Gross weight")
    def gross_weight(self, obj):
        return grams(obj.gross_grams)

    @admin.display(description="Gross amount", ordering="gross_amount_centavos")
    def gross(self, obj):
        return money(obj.gross_amount_centavos)

    @admin.display(description="Capital")
    def capital(self, obj):
        return money(obj.capital_centavos)

    @admin.display(description="Net")
    def net(self, obj):
        return money(obj.net_centavos)


# --- rates, receipts, the log ------------------------------------------------------

@admin.register(GoldRate)
class GoldRateAdmin(ReadOnlyAdmin):
    list_display = ["purity", "price", "updated_at"]

    @admin.display(description="Purity", ordering="karat")
    def purity(self, obj):
        return karat_text(obj.karat)

    @admin.display(description="Per gram", ordering="price_per_gram_centavos")
    def price(self, obj):
        return money(obj.price_per_gram_centavos)


@admin.register(RateChange)
class RateChangeAdmin(ReadOnlyAdmin):
    list_display = ["at", "purity", "before", "after", "user_name", "restored_from"]
    list_filter = ["karat"]
    date_hierarchy = "at"

    @admin.display(description="Purity", ordering="karat")
    def purity(self, obj):
        return karat_text(obj.karat)

    @admin.display(description="Before")
    def before(self, obj):
        return money(obj.before_centavos)

    @admin.display(description="After")
    def after(self, obj):
        return money(obj.after_centavos)


@admin.register(StoredReceipt)
class StoredReceiptAdmin(ReadOnlyAdmin):
    list_display = ["issued_at", "id", "kind", "record_id", "branch", "counterparty", "total", "document"]
    list_filter = ["kind", "branch"]
    search_fields = ["id", "record_id", "counterparty"]
    date_hierarchy = "issued_at"
    readonly_fields = ["document"]

    @admin.display(description="Total", ordering="total_centavos")
    def total(self, obj):
        return money(obj.total_centavos)

    @admin.display(description="PDF")
    def document(self, obj):
        return format_html('<a href="{}" target="_blank">{}</a>', obj.pdf.url, obj.filename) if obj.pdf else "—"


@admin.register(TransactionLog)
class TransactionLogAdmin(ReadOnlyAdmin):
    """The shop's evidence: who did what, when. Append-only."""

    list_display = ["at", "action_label", "user_name", "role_label", "branch", "short_summary", "record_id", "amount"]
    list_filter = ["category", "action", "branch", "role"]
    search_fields = ["summary", "record_id", "user_name", "id"]
    date_hierarchy = "at"
    readonly_fields = ["change_table"]

    @admin.display(description="Action", ordering="action")
    def action_label(self, obj):
        return LogAction(obj.action).label

    @admin.display(description="Role", ordering="role")
    def role_label(self, obj):
        return Role(obj.role).label

    @admin.display(description="Summary")
    def short_summary(self, obj):
        return obj.summary if len(obj.summary) <= 90 else obj.summary[:87] + "…"

    @admin.display(description="Amount", ordering="amount_centavos")
    def amount(self, obj):
        return money(obj.amount_centavos)

    @admin.display(description="What changed")
    def change_table(self, obj):
        if not obj.changes:
            return "—"
        rows = format_html_join("", "<tr><td>{}</td><td>{}</td><td>{}</td></tr>",
                                ((c.get("field"), c.get("before"), c.get("after")) for c in obj.changes))
        return format_html("<table><tr><th>Field</th><th>Before</th><th>After</th></tr>{}</table>", rows)
