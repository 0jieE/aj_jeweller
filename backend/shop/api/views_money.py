"""Sales and the cash ledger."""

from django.db.models import Q
from rest_framework import status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from ..models import CashEntry, Sale
from ..services import cash as cash_service
from ..services import sales as sale_service
from ..services.base import require_branch
from ..services.customers import CustomerDetails
from . import inputs
from .base import ShopView, filter_dates, read_branch
from .serializers import CashEntrySerializer, SaleSerializer
from .views_stock import ShopViewSet, provided, validated


def _lines(raw: list[dict]) -> list[sale_service.LineInput]:
    return [sale_service.LineInput(item_id=line["item_id"], negotiated_price_centavos=line["negotiated_price_centavos"],
                                   final_grams=line.get("final_grams")) for line in raw]


class SaleViewSet(ShopViewSet):
    queryset = Sale.objects.all()

    def list(self, request):
        queryset = Sale.objects.select_related("submitted_by", "received_by", "customer").order_by("-date")
        branch = read_branch(request)
        if branch:
            queryset = queryset.filter(branch_id=branch)
        params = request.query_params
        if params.get("status"):
            queryset = queryset.filter(verification_status=params["status"])
        if params.get("customer"):
            queryset = queryset.filter(customer_id=params["customer"])
        if params.get("q"):
            q = params["q"]
            queryset = queryset.filter(Q(customer_name__icontains=q) | Q(id__iexact=q) | Q(lines__item_id__iexact=q)
                                       | Q(lines__item__description__icontains=q)).distinct()
        queryset = filter_dates(queryset, request, "date")
        return self.page(queryset, SaleSerializer)

    def retrieve(self, request, pk=None):
        sale = sale_service.get_sale(pk)
        require_branch(self.ctx, sale.branch_id)
        return self.out(SaleSerializer, sale)

    def create(self, request):
        """Checkout. Pieces become reserved; no cash moves."""
        v = validated(inputs.SaleInput, request)
        payment = v.get("payment") or {}
        sale = sale_service.checkout(
            self.ctx, branch_id=v.get("branch"), customer=CustomerDetails.from_input(v["customer"]),
            lines=_lines(v["lines"]), cash_centavos=payment.get("cash_centavos", 0),
            bank_centavos=payment.get("bank_centavos", 0), note=v.get("note"), sale_id=v.get("id") or None,
        )
        return self.out(SaleSerializer, sale, status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def complete(self, request, pk=None):
        v = validated(inputs.CompleteSaleInput, request)
        sale = sale_service.complete(
            self.ctx, pk, cash_centavos=v["cash_centavos"], bank_centavos=v["bank_centavos"],
            cash_entry_id=v.get("cash_entry_id") or None, bank_entry_id=v.get("bank_entry_id") or None,
        )
        return self.out(SaleSerializer, sale)

    @action(detail=True, methods=["post"], url_path="return")
    def return_for_correction(self, request, pk=None):
        v = validated(inputs.NoteInput, request)
        return self.out(SaleSerializer, sale_service.return_for_correction(self.ctx, pk, v["note"]))

    @action(detail=True, methods=["post"])
    def resubmit(self, request, pk=None):
        v = validated(inputs.SaleResubmitInput, request)
        payment = v.get("payment") or {}
        sale = sale_service.resubmit(
            self.ctx, pk, lines=_lines(v["lines"]),
            customer=CustomerDetails.from_input(v["customer"]) if v.get("customer") else None,
            note=v.get("note"), cash_centavos=payment.get("cash_centavos"), bank_centavos=payment.get("bank_centavos"),
        )
        return self.out(SaleSerializer, sale)


class CashEntryViewSet(ShopViewSet):
    """GET/POST /cash/entries, GET/PATCH/DELETE /cash/entries/{id}."""

    queryset = CashEntry.objects.all()

    def list(self, request):
        queryset = CashEntry.objects.select_related("recorded_by").order_by("-date", "id")
        branch = read_branch(request)
        if branch:
            queryset = queryset.filter(branch_id=branch)
        params = request.query_params
        for param, column in (("account", "account"), ("type", "type"), ("source", "source_type"),
                              ("linked", "linked_record_id"), ("category", "category")):
            if params.get(param):
                queryset = queryset.filter(**{column: params[param]})
        if params.get("q"):
            q = params["q"]
            queryset = queryset.filter(Q(note__icontains=q) | Q(id__iexact=q) | Q(linked_record_id__iexact=q))
        queryset = filter_dates(queryset, request, "date")
        return self.page(queryset, CashEntrySerializer)

    def retrieve(self, request, pk=None):
        entry = cash_service.get_entry(pk)
        require_branch(self.ctx, entry.branch_id)
        return self.out(CashEntrySerializer, entry)

    def create(self, request):
        v = validated(inputs.CashEntryInput, request)
        entry = cash_service.record_entry(
            self.ctx, branch_id=v.get("branch"), type=v["type"], account=v["account"],
            amount_centavos=v["amount_centavos"], note=v["note"], category=v.get("category"), when=v.get("date"),
            entry_id=v.get("id") or None,
        )
        return self.out(CashEntrySerializer, entry, status.HTTP_201_CREATED)

    def partial_update(self, request, pk=None):
        v = validated(inputs.CashEntryUpdateInput, request, partial=True)
        fields = provided(v, "type", "account", "destination_account", "amount_centavos", "note", "category")
        if "date" in v:
            fields["when"] = v["date"]
        changes = cash_service.update_entry(self.ctx, pk, **fields)
        entry = cash_service.get_entry(pk)
        group = [CashEntrySerializer(e).data for e in cash_service.group_of(entry)]
        return Response({"entries": group, "changes": changes})

    def destroy(self, request, pk=None):
        reason = None
        if isinstance(request.data, dict):
            reason = request.data.get("reason")
        reason = reason or request.query_params.get("reason")
        cash_service.delete_entry(self.ctx, pk, reason)
        return Response(status=status.HTTP_204_NO_CONTENT)


class TransferView(ShopView, APIView):
    """POST /cash/transfers — writes the matched transferOut/transferIn pair."""

    def post(self, request):
        v = validated(inputs.TransferInput, request)
        out, inn = cash_service.record_transfer(
            self.ctx, from_branch=v.get("from_branch"), to_branch=v["to_branch"], from_account=v["from_account"],
            to_account=v["to_account"], amount_centavos=v["amount_centavos"], note=v["note"], when=v.get("date"),
            out_id=v.get("out_id") or None, in_id=v.get("in_id") or None, pair_id=v.get("pair_id") or None,
        )
        return Response({"out": CashEntrySerializer(out).data, "in": CashEntrySerializer(inn).data},
                        status=status.HTTP_201_CREATED)
