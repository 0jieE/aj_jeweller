"""Customers, purchases, items and partitions."""

from django.db.models import Case, IntegerField, Q, Value, When
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from ..enums import ItemType, VerificationStatus
from ..models import Customer, Item, PurchaseBatch
from ..services import customers as customer_service
from ..services import items as item_service
from ..services import purchases as purchase_service
from ..services.base import require_branch
from . import inputs
from .base import ShopView, filter_dates, query_bool, read_branch
from .serializers import (
    CashEntrySerializer,
    CustomerDetailSerializer,
    CustomerSerializer,
    ItemDetailSerializer,
    ItemSerializer,
    PurchaseBatchSerializer,
)


def validated(serializer_class, request, **kwargs) -> dict:
    serializer = serializer_class(data=request.data, **kwargs)
    serializer.is_valid(raise_exception=True)
    return serializer.validated_data


def provided(data: dict, *names) -> dict:
    """Only the fields the client actually sent — PATCH semantics."""
    return {name: data[name] for name in names if name in data}


class ShopViewSet(ShopView, viewsets.GenericViewSet):
    lookup_value_regex = "[^/]+"

    def page(self, queryset, serializer_class, **context):
        page = self.paginate_queryset(queryset)
        ctx = {"request": self.request, **context}
        if page is not None:
            return self.get_paginated_response(serializer_class(page, many=True, context=ctx).data)
        return Response(serializer_class(queryset, many=True, context=ctx).data)

    def out(self, serializer_class, instance, status_code=status.HTTP_200_OK, **context):
        return Response(serializer_class(instance, context={"request": self.request, **context}).data,
                        status=status_code)


# --- customers ---------------------------------------------------------------

class CustomerViewSet(ShopViewSet):
    """The customer book is shared by both branches."""

    queryset = Customer.objects.all()

    def list(self, request):
        queryset = Customer.objects.all().order_by("name_key")
        q = (request.query_params.get("q") or "").strip()
        if q:
            # Someone keying "ma" is far more often reaching for Maria than for
            # Norma: names starting with the query rank first.
            queryset = queryset.filter(
                Q(name__icontains=q) | Q(contact_number__icontains=q) | Q(id__iexact=q)
            ).annotate(
                rank=Case(When(name__istartswith=q, then=Value(0)), default=Value(1), output_field=IntegerField())
            ).order_by("rank", "name_key")
        queryset = filter_dates(queryset, request, "first_seen")
        return self.page(queryset, CustomerSerializer)

    def retrieve(self, request, pk=None):
        customer = customer_service.get_customer(pk)
        return self.out(CustomerDetailSerializer, customer, branch=read_branch(request))

    def create(self, request):
        v = validated(inputs.CustomerInput, request)
        customer = customer_service.create_customer(
            self.ctx, name=v["name"], contact_number=v.get("contact_number"), address=v.get("address"),
            customer_id=v.get("id") or None, photo=v.get("photo"),
        )
        return self.out(CustomerSerializer, customer, status.HTTP_201_CREATED)

    def partial_update(self, request, pk=None):
        v = validated(inputs.CustomerUpdateInput, request, partial=True)
        changes = customer_service.update_customer(self.ctx, pk, **provided(v, "name", "contact_number", "address"))
        data = CustomerSerializer(customer_service.get_customer(pk), context={"request": request}).data
        return Response({"customer": data, "changes": changes})

    @action(detail=True, methods=["put"])
    def photo(self, request, pk=None):
        v = validated(inputs.PhotoInput, request)
        return self.out(CustomerSerializer, customer_service.set_photo(self.ctx, pk, v["photo"]))


# --- purchases ---------------------------------------------------------------

class PurchaseViewSet(ShopViewSet):
    queryset = PurchaseBatch.objects.all()

    def list(self, request):
        queryset = PurchaseBatch.objects.select_related("submitted_by", "released_by", "customer").order_by("-date")
        branch = read_branch(request)
        if branch:
            queryset = queryset.filter(branch_id=branch)
        params = request.query_params
        if params.get("status"):
            queryset = queryset.filter(verification_status=params["status"])
        if params.get("customer"):
            queryset = queryset.filter(customer_id=params["customer"])
        if params.get("submitted_by_role"):
            queryset = queryset.filter(submitted_by_role=params["submitted_by_role"])
        if params.get("q"):
            q = params["q"]
            queryset = queryset.filter(Q(customer_name__icontains=q) | Q(id__iexact=q) | Q(items__id__iexact=q)
                                       | Q(items__description__icontains=q)).distinct()
        queryset = filter_dates(queryset, request, "date")
        return self.page(queryset, PurchaseBatchSerializer)

    def retrieve(self, request, pk=None):
        batch = purchase_service.get_batch(pk)
        require_branch(self.ctx, batch.branch_id)
        return self.out(PurchaseBatchSerializer, batch)

    def create(self, request):
        v = validated(inputs.PurchaseInput, request)
        batch = purchase_service.record_batch(self.ctx, purchase_service.BatchInput(
            customer=customer_service.CustomerDetails.from_input(v["customer"]),
            lines=[purchase_service.DraftLine.from_input(line) for line in v["lines"]],
            branch_id=v.get("branch"),
            date=v.get("date"),
            batch_id=v.get("id") or None,
        ))
        return self.out(PurchaseBatchSerializer, batch, status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def release(self, request, pk=None):
        """Multipart (proof_photo file) or JSON (proof_photo base64)."""
        v = validated(inputs.ReleaseInput, request)
        batch, entry = purchase_service.release(self.ctx, pk, v.get("proof_photo"), v.get("cash_entry_id") or None)
        data = PurchaseBatchSerializer(batch, context={"request": request}).data
        return Response({**data, "cash_entry": CashEntrySerializer(entry).data})

    @action(detail=True, methods=["post"], url_path="return")
    def return_for_correction(self, request, pk=None):
        v = validated(inputs.NoteInput, request)
        return self.out(PurchaseBatchSerializer, purchase_service.return_for_correction(self.ctx, pk, v["note"]))

    @action(detail=True, methods=["post"])
    def resubmit(self, request, pk=None):
        v = validated(inputs.PurchaseResubmitInput, request)
        return self.out(PurchaseBatchSerializer, purchase_service.resubmit(self.ctx, pk, v["lines"]))


# --- items -------------------------------------------------------------------

class ItemViewSet(ShopViewSet):
    queryset = Item.objects.all()

    def _scoped(self, request):
        queryset = Item.objects.select_related("encoded_by", "batch").order_by("-purchase_date", "id")
        branch = read_branch(request)
        return queryset.filter(branch_id=branch) if branch else queryset

    def list(self, request):
        queryset = self._scoped(request)
        params = request.query_params
        for param, column in (("status", "item_status"), ("type", "type"), ("verification", "verification_status"),
                              ("batch", "batch_id"), ("parent", "parent_lot_id"), ("karat", "karat")):
            if params.get(param):
                queryset = queryset.filter(**{column: params[param]})
        silver = query_bool(request, "silver")
        if silver is not None:
            queryset = queryset.filter(type=ItemType.SILVER) if silver else queryset.exclude(type=ItemType.SILVER)
        if params.get("q"):
            q = params["q"]
            queryset = queryset.filter(Q(description__icontains=q) | Q(id__iexact=q) | Q(origin__icontains=q))
        queryset = filter_dates(queryset, request, "purchase_date")
        return self.page(queryset, ItemSerializer)

    def retrieve(self, request, pk=None):
        item = item_service.get_item(pk)
        require_branch(self.ctx, item.branch_id)
        return self.out(ItemDetailSerializer, item)

    @action(detail=False, methods=["get"])
    def sellable(self, request):
        """Verified, listed, not scrap — what the Sell tab offers."""
        queryset = self._scoped(request).filter(
            item_status="listed", verification_status=VerificationStatus.VERIFIED,
        ).exclude(type=ItemType.SCRAP)
        silver = query_bool(request, "silver")
        if silver is not None:
            queryset = queryset.filter(type=ItemType.SILVER) if silver else queryset.exclude(type=ItemType.SILVER)
        if request.query_params.get("q"):
            q = request.query_params["q"]
            queryset = queryset.filter(Q(description__icontains=q) | Q(id__iexact=q))
        return self.page(queryset, ItemSerializer)

    def partial_update(self, request, pk=None):
        """Admin correction. Never moves cash — the response says so."""
        v = validated(inputs.ItemCorrectionInput, request, partial=True)
        fields = provided(v, "description", "type", "karat", "weight_grams", "gross_weight_grams")
        if "amount_centavos" in v:
            fields["amount_centavos"] = v["amount_centavos"]
        item, changes, cash_note = item_service.correct(self.ctx, pk, **fields)
        return Response({
            "item": ItemDetailSerializer(item, context={"request": request}).data,
            "changes": changes,
            "cash_moved": False,
            "cash_note": cash_note or "Corrections never move cash.",
        })

    @action(detail=True, methods=["put"])
    def photo(self, request, pk=None):
        v = validated(inputs.PhotoInput, request)
        return self.out(ItemSerializer, item_service.set_photo(self.ctx, pk, v["photo"]))

    @action(detail=True, methods=["post"])
    def partitions(self, request, pk=None):
        v = validated(inputs.PartitionInput, request)
        child = item_service.create_partition(
            self.ctx, pk, description=v["description"], type=v["type"], grams_drawn=v["grams"],
            amount_centavos=v["amount_centavos"], photo=v.get("photo"), partition_id=v.get("id") or None,
        )
        return self.out(ItemDetailSerializer, child, status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def resubmit(self, request, pk=None):
        v = validated(inputs.ItemResubmitInput, request, partial=True)
        line = provided(v, "description", "type", "karat", "weight_grams", "gross_weight_grams",
                        "amount_centavos", "photo")
        return self.out(PurchaseBatchSerializer, purchase_service.resubmit_item(self.ctx, pk, line))

    @action(detail=True, methods=["post"])
    def reserve(self, request, pk=None):
        from ..services import sales

        return self.out(ItemSerializer, sales.reserve(self.ctx, pk))

    @action(detail=True, methods=["post"], url_path="release-reservation")
    def release_reservation(self, request, pk=None):
        from ..services import sales

        return self.out(ItemSerializer, sales.release_reservation(self.ctx, pk))


class PartitionView(ShopView, APIView):
    """DELETE /partitions/{id} — returns its grams and amount to the lot."""

    def delete(self, request, pk):
        lot = item_service.delete_partition(self.ctx, pk)
        return Response({"lot": ItemDetailSerializer(lot, context={"request": request}).data})
