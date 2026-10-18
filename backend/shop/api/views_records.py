"""Rates and rate history, receipts, the transaction log, and exports."""

from django.db.models import Q
from django.http import FileResponse, HttpResponse
from django.utils.dateparse import parse_date
from rest_framework import exceptions, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from ..enums import is_silver_purity
from ..errors import NotFound
from ..models import GoldRate, RateChange, StoredReceipt, TransactionLog
from ..services import exports as export_service
from ..services import rates as rate_service
from ..services import receipts as receipt_service
from ..services.base import require_branch
from . import inputs
from .base import ShopView, date_range, filter_dates, read_branch
from .serializers import RateChangeSerializer, StoredReceiptSerializer, TransactionLogSerializer
from .views_stock import ShopViewSet, validated


def _rate(rate: GoldRate) -> dict:
    from ..text import karat_text, purity_text

    return {"karat": rate.karat, "silver": is_silver_purity(rate.karat), "label": karat_text(rate.karat),
            "purity": purity_text(rate.karat), "price_per_gram_centavos": rate.price_per_gram_centavos,
            "updated_at": rate.updated_at}


class RatesView(ShopView, APIView):
    """GET /rates (gold and silver, highest first), POST /rates (add a purity)."""

    def get(self, request):
        rates = GoldRate.objects.order_by("-karat")
        return Response({"gold": [_rate(r) for r in rates if not is_silver_purity(r.karat)],
                         "silver": [_rate(r) for r in rates if is_silver_purity(r.karat)]})

    def post(self, request):
        v = validated(inputs.RateAddInput, request)
        rate = rate_service.add_rate(self.ctx, v["karat"], v["price_per_gram_centavos"], v.get("silver"))
        return Response(_rate(rate), status=status.HTTP_201_CREATED)


class RateDetailView(ShopView, APIView):
    """PATCH /rates/{karat} {price_per_gram_centavos}."""

    def get(self, request, karat):
        return Response(_rate(rate_service.get_rate(int(karat))))

    def patch(self, request, karat):
        v = validated(inputs.RateUpdateInput, request)
        rate, changed = rate_service.update_rate(self.ctx, int(karat), v["price_per_gram_centavos"])
        return Response({**_rate(rate), "changed": changed})


class RateHistoryView(ShopView, APIView):
    """GET /rates/history?karat=&from=&to= — newest first."""

    def get(self, request):
        queryset = RateChange.objects.select_related("user").order_by("-at", "-id")
        karat = request.query_params.get("karat")
        if karat:
            queryset = queryset.filter(karat=int(karat))
        metal = request.query_params.get("metal")
        if metal == "silver":
            queryset = queryset.filter(karat__gte=100)
        elif metal == "gold":
            queryset = queryset.filter(karat__lt=100)
        queryset = filter_dates(queryset, request, "at")
        from .pagination import Pagination

        paginator = Pagination()
        page = paginator.paginate_queryset(queryset, request, view=self)
        return paginator.get_paginated_response(RateChangeSerializer(page, many=True).data)


class RatesOnView(ShopView, APIView):
    """GET /rates/on/{date} — every purity's price at the close of that day."""

    def get(self, request, day):
        parsed = parse_date(day)
        if parsed is None:
            raise exceptions.ValidationError({"date": [f'"{day}" is not a date (YYYY-MM-DD)']})
        return Response({"date": parsed, "rates": rate_service.rates_on(parsed)})


class RatesApplyView(ShopView, APIView):
    """POST /rates/apply {date, silver} — re-applies that day's whole table for one metal."""

    def post(self, request):
        v = validated(inputs.RateApplyInput, request)
        changed = rate_service.apply_from(self.ctx, v["date"], silver=v["silver"])
        return Response({"changed": changed, "date": v["date"], "silver": v["silver"]})


class ReceiptViewSet(ShopViewSet):
    queryset = StoredReceipt.objects.all()

    def list(self, request):
        queryset = StoredReceipt.objects.order_by("-issued_at")
        branch = read_branch(request)
        if branch:
            queryset = queryset.filter(branch_id=branch)
        params = request.query_params
        if params.get("kind"):
            queryset = queryset.filter(kind=params["kind"])
        if params.get("record"):
            queryset = queryset.filter(record_id=params["record"])
        if params.get("q"):
            q = params["q"]
            queryset = queryset.filter(Q(counterparty__icontains=q) | Q(record_id__iexact=q) | Q(id__iexact=q))
        queryset = filter_dates(queryset, request, "issued_at")
        return self.page(queryset, StoredReceiptSerializer)

    def _get(self, pk) -> StoredReceipt:
        receipt = StoredReceipt.objects.filter(Q(pk=pk) | Q(record_id=pk)).first()
        if receipt is None:
            raise NotFound("Receipt not found")
        require_branch(self.ctx, receipt.branch_id)
        return receipt

    def retrieve(self, request, pk=None):
        return self.out(StoredReceiptSerializer, self._get(pk))

    def create(self, request):
        v = validated(inputs.ReceiptInput, request)
        receipt = receipt_service.issue(self.ctx, v["record_id"], v.get("kind"), v.get("id") or None)
        return self.out(StoredReceiptSerializer, receipt, status.HTTP_201_CREATED)

    @action(detail=True, methods=["get"])
    def pdf(self, request, pk=None):
        receipt = self._get(pk)
        return FileResponse(receipt.pdf.open("rb"), content_type="application/pdf", filename=receipt.filename)

    @action(detail=True, methods=["get"])
    def text(self, request, pk=None):
        return HttpResponse(self._get(pk).text, content_type="text/plain; charset=utf-8")


class LogViewSet(ShopViewSet):
    """GET /logs?branch=&category=&user=&action=&record=&from=&to=&q= — newest first.
    A branch view keeps company-wide entries (a rate change applies everywhere)."""

    queryset = TransactionLog.objects.all()

    def list(self, request):
        queryset = TransactionLog.objects.order_by("-at", "-id")
        branch = read_branch(request)
        if branch:
            queryset = queryset.filter(Q(branch_id=branch) | Q(branch__isnull=True))
        params = request.query_params
        for param, column in (("category", "category"), ("user", "user_id"), ("action", "action"),
                              ("record", "record_id"), ("record_kind", "record_kind"), ("role", "role")):
            if params.get(param):
                queryset = queryset.filter(**{column: params[param]})
        if params.get("q"):
            q = params["q"]
            queryset = queryset.filter(Q(summary__icontains=q) | Q(record_id__iexact=q) | Q(user_name__icontains=q))
        queryset = filter_dates(queryset, request, "at")
        return self.page(queryset, TransactionLogSerializer)

    def retrieve(self, request, pk=None):
        log = TransactionLog.objects.filter(pk=pk).first()
        if log is None:
            raise NotFound("Log entry not found")
        if log.branch_id:
            require_branch(self.ctx, log.branch_id)
        return self.out(TransactionLogSerializer, log)


class ExportView(ShopView, APIView):
    """GET /exports/{purchases|sales|expenses|withdrawals}?format=csv|xlsx|pdf&branch=&from=&to="""

    def get(self, request, kind):
        if kind not in export_service.KINDS:
            raise NotFound(f'"{kind}" is not an export — use purchases, sales, expenses or withdrawals')
        fmt = request.query_params.get("format", "csv")
        if fmt not in ("csv", "xlsx", "pdf"):
            raise exceptions.ValidationError({"format": ["Use csv, xlsx or pdf"]})
        branch = read_branch(request)
        start, end = date_range(request)
        table = export_service.build(kind, branch, start, end)
        title = f"{export_service.TITLES[kind]} export"
        name = export_service.filename(kind, branch, request.query_params.get("from"),
                                       request.query_params.get("to"), fmt)
        if fmt == "csv":
            body, mime = export_service.to_csv(table), "text/csv; charset=utf-8"
        elif fmt == "xlsx":
            body = export_service.to_xlsx(table, title)
            mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        else:
            scope = "Both branches" if branch is None else branch.capitalize()
            body, mime = export_service.to_pdf(table, title, scope), "application/pdf"
        response = HttpResponse(body, content_type=mime)
        response["Content-Disposition"] = f'attachment; filename="{name}"'
        response["X-Total-Centavos"] = str(table.total_centavos)
        return response
