"""Input serializers: the shape of each request. They check types; the
services check the shop's rules (and say no with 422)."""

from rest_framework import serializers

from ..enums import BranchId, CashAccount, CashEntryType, ItemType, ReceiptKind
from .fields import PhotoField, grams_field, money_field


class CustomerInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    name = serializers.CharField(allow_blank=True)
    contact_number = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    address = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    photo = PhotoField(required=False, allow_null=True)


class CustomerUpdateInput(serializers.Serializer):
    name = serializers.CharField(required=False, allow_blank=True)
    contact_number = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    address = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class PhotoInput(serializers.Serializer):
    photo = PhotoField()


class PurchaseLineInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    description = serializers.CharField(allow_blank=True)
    weight_grams = grams_field()
    gross_weight_grams = grams_field(required=False, allow_null=True)
    karat = serializers.IntegerField(min_value=0)
    type = serializers.ChoiceField(choices=ItemType.choices)
    amount_centavos = money_field()
    photo = PhotoField(required=False, allow_null=True)


class PurchaseInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    date = serializers.DateTimeField(required=False, allow_null=True)
    customer = CustomerInput()
    lines = PurchaseLineInput(many=True, allow_empty=True)


class ReleaseInput(serializers.Serializer):
    proof_photo = PhotoField(required=False, allow_null=True)
    cash_entry_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class NoteInput(serializers.Serializer):
    note = serializers.CharField(allow_blank=True, required=False, default="")


class ResubmitLineInput(serializers.Serializer):
    id = serializers.CharField()
    description = serializers.CharField(required=False, allow_blank=True)
    weight_grams = grams_field(required=False)
    gross_weight_grams = grams_field(required=False, allow_null=True)
    karat = serializers.IntegerField(required=False, min_value=0)
    type = serializers.ChoiceField(choices=ItemType.choices, required=False)
    amount_centavos = money_field(required=False)
    photo = PhotoField(required=False, allow_null=True)


class PurchaseResubmitInput(serializers.Serializer):
    lines = ResubmitLineInput(many=True, required=False, default=list)


class ItemResubmitInput(ResubmitLineInput):
    id = serializers.CharField(required=False)


class ItemCorrectionInput(serializers.Serializer):
    description = serializers.CharField(required=False, allow_blank=True)
    type = serializers.ChoiceField(choices=ItemType.choices, required=False)
    karat = serializers.IntegerField(required=False, min_value=0)
    weight_grams = grams_field(required=False)
    gross_weight_grams = grams_field(required=False, allow_null=True)
    amount_centavos = money_field(required=False)


class PartitionInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    description = serializers.CharField(allow_blank=True)
    type = serializers.ChoiceField(choices=ItemType.choices)
    grams = grams_field()
    amount_centavos = money_field()
    photo = PhotoField(required=False, allow_null=True)


class SaleLineInput(serializers.Serializer):
    item_id = serializers.CharField()
    negotiated_price_centavos = money_field()
    final_grams = grams_field(required=False, allow_null=True)


class PaymentInput(serializers.Serializer):
    cash_centavos = money_field(required=False, default=0)
    bank_centavos = money_field(required=False, default=0)


class SaleInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    customer = CustomerInput()
    note = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    lines = SaleLineInput(many=True, allow_empty=True)
    payment = PaymentInput(required=False)


class SaleResubmitInput(serializers.Serializer):
    customer = CustomerInput(required=False)
    note = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    lines = SaleLineInput(many=True, allow_empty=True)
    payment = PaymentInput(required=False)


class CompleteSaleInput(serializers.Serializer):
    cash_centavos = money_field()
    bank_centavos = money_field()
    cash_entry_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    bank_entry_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class CommitmentInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    lender = serializers.CharField(allow_blank=True)
    amount_centavos = money_field()
    rate_per_gram_centavos = money_field()
    branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    date_approved = serializers.DateTimeField(required=False, allow_null=True)


class ReceiveCommitmentInput(serializers.Serializer):
    proof_photo = PhotoField(required=False, allow_null=True)
    cash_entry_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class DisposalInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    item_ids = serializers.ListField(child=serializers.CharField(), allow_empty=True)
    capital_centavos = money_field(required=False, allow_null=True)
    gross_grams = grams_field()
    gross_amount_centavos = money_field()
    commitment_id = serializers.CharField(allow_blank=True)
    date = serializers.DateTimeField(required=False, allow_null=True)
    photo = PhotoField(required=False, allow_null=True)


class CashEntryInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    type = serializers.ChoiceField(choices=CashEntryType.choices)
    account = serializers.ChoiceField(choices=CashAccount.choices, required=False, default=CashAccount.PURCHASE)
    amount_centavos = money_field()
    note = serializers.CharField(allow_blank=True)
    category = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    date = serializers.DateTimeField(required=False, allow_null=True)


class CashEntryUpdateInput(serializers.Serializer):
    type = serializers.ChoiceField(choices=CashEntryType.choices, required=False)
    account = serializers.ChoiceField(choices=CashAccount.choices, required=False)
    destination_account = serializers.ChoiceField(choices=CashAccount.choices, required=False)
    amount_centavos = money_field(required=False)
    note = serializers.CharField(required=False, allow_blank=True)
    category = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    date = serializers.DateTimeField(required=False)


class TransferInput(serializers.Serializer):
    from_branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    from_account = serializers.ChoiceField(choices=CashAccount.choices, required=False, default=CashAccount.PURCHASE)
    to_branch = serializers.ChoiceField(choices=BranchId.choices)
    to_account = serializers.ChoiceField(choices=CashAccount.choices, required=False, default=CashAccount.PURCHASE)
    amount_centavos = money_field()
    note = serializers.CharField(allow_blank=True)
    date = serializers.DateTimeField(required=False, allow_null=True)
    out_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    in_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    pair_id = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class DeleteEntryInput(serializers.Serializer):
    reason = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class RateAddInput(serializers.Serializer):
    karat = serializers.IntegerField()
    price_per_gram_centavos = money_field()
    silver = serializers.BooleanField(required=False, allow_null=True, default=None)


class RateUpdateInput(serializers.Serializer):
    price_per_gram_centavos = money_field()


class RateApplyInput(serializers.Serializer):
    date = serializers.DateField()
    silver = serializers.BooleanField(default=False)


class ReceiptInput(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    record_id = serializers.CharField()
    kind = serializers.ChoiceField(choices=ReceiptKind.choices, required=False, allow_null=True)
