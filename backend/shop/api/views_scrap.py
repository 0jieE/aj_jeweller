"""Disposal batches and commitments."""

from django.db.models import Q
from rest_framework import status
from rest_framework.decorators import action
from rest_framework.response import Response

from ..errors import NotFound
from ..models import Commitment, DisposalBatch
from ..services import commitments as commitment_service
from ..services import disposal as disposal_service
from ..services.base import require_branch
from . import inputs
from .base import filter_dates, query_bool, read_branch
from .serializers import (
    CashEntrySerializer,
    CommitmentSerializer,
    DisposalBatchSerializer,
    DisposalDetailSerializer,
    ItemSerializer,
)
from .views_stock import ShopViewSet, validated


class DisposalViewSet(ShopViewSet):
    queryset = DisposalBatch.objects.all()

    def list(self, request):
        queryset = DisposalBatch.objects.select_related("commitment").order_by("-date")
        branch = read_branch(request)
        if branch:
            queryset = queryset.filter(branch_id=branch)
        if request.query_params.get("commitment"):
            queryset = queryset.filter(commitment_id=request.query_params["commitment"])
        if request.query_params.get("q"):
            q = request.query_params["q"]
            queryset = queryset.filter(Q(id__iexact=q) | Q(commitment__lender__icontains=q) | Q(links__item_id__iexact=q)
                                       | Q(links__item__description__icontains=q)).distinct()
        queryset = filter_dates(queryset, request, "date")
        return self.page(queryset, DisposalBatchSerializer)

    def retrieve(self, request, pk=None):
        batch = DisposalBatch.objects.filter(pk=pk).first()
        if batch is None:
            raise NotFound("Disposal batch not found")
        require_branch(self.ctx, batch.branch_id)
        return self.out(DisposalDetailSerializer, batch)

    def create(self, request):
        v = validated(inputs.DisposalInput, request)
        batch = disposal_service.complete(
            self.ctx, branch_id=v.get("branch"), item_ids=v["item_ids"], gross_grams=v["gross_grams"],
            gross_amount_centavos=v["gross_amount_centavos"], commitment_id=v["commitment_id"],
            capital_centavos=v.get("capital_centavos"), date=v.get("date"), photo=v.get("photo"),
            batch_id=v.get("id") or None,
        )
        return self.out(DisposalDetailSerializer, batch, status.HTTP_201_CREATED)

    @action(detail=False, methods=["get"])
    def pool(self, request):
        """Gold scrap awaiting disposal, or (?silver=true) silver stock on hand."""
        items = disposal_service.pool(read_branch(request), silver=bool(query_bool(request, "silver")))
        data = ItemSerializer(items, many=True, context={"request": request}).data
        return Response({
            "count": len(items),
            "total_grams": f"{sum(i.effective_remaining_grams for i in items):.3f}",
            "total_capital_centavos": sum(i.effective_remaining_amount for i in items),
            "results": data,
        })


class CommitmentViewSet(ShopViewSet):
    queryset = Commitment.objects.all()

    def list(self, request):
        queryset = Commitment.objects.all().order_by("-date_approved")
        branch = read_branch(request)
        if branch:
            # A branch sees its own loans and the company-wide ones.
            queryset = queryset.filter(Q(branch_id=branch) | Q(branch__isnull=True))
        if request.query_params.get("q"):
            queryset = queryset.filter(lender__icontains=request.query_params["q"])
        queryset = filter_dates(queryset, request, "date_approved")
        wanted = request.query_params.get("status")
        if wanted:
            queryset = [c for c in queryset if commitment_service.ledger(c).status == wanted]
        return self.page(queryset, CommitmentSerializer)

    def retrieve(self, request, pk=None):
        commitment = commitment_service.get_commitment(pk)
        if commitment.branch_id:
            require_branch(self.ctx, commitment.branch_id)
        data = CommitmentSerializer(commitment, context={"request": request}).data
        batches = commitment.disposals.order_by("date")
        data["applied_batches"] = DisposalBatchSerializer(batches, many=True, context={"request": request}).data
        return Response(data)

    def create(self, request):
        v = validated(inputs.CommitmentInput, request)
        commitment = commitment_service.add(
            self.ctx, lender=v["lender"], amount_centavos=v["amount_centavos"],
            rate_per_gram_centavos=v["rate_per_gram_centavos"], branch_id=v.get("branch"),
            date_approved=v.get("date_approved"), commitment_id=v.get("id") or None,
        )
        return self.out(CommitmentSerializer, commitment, status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def receive(self, request, pk=None):
        """Multipart (proof_photo file) or JSON (proof_photo base64)."""
        v = validated(inputs.ReceiveCommitmentInput, request)
        commitment, entry = commitment_service.receive(self.ctx, pk, v.get("proof_photo"),
                                                       v.get("cash_entry_id") or None)
        data = CommitmentSerializer(commitment, context={"request": request}).data
        return Response({**data, "cash_entry": CashEntrySerializer(entry).data if entry else None})
