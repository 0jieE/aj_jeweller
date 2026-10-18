"""GET /branches and GET /cash/balances — balances are computed, never read
from a column."""

from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from ..models import Branch
from ..services import cash
from .base import ShopView, read_branch


def present_branch(branch: Branch) -> dict:
    return {
        "id": branch.id,
        "label": branch.label,
        "starting_purchase_cash_centavos": branch.starting_purchase_cash_centavos,
        "starting_sales_cash_centavos": branch.starting_sales_cash_centavos,
        "starting_bank_centavos": branch.starting_bank_centavos,
        "accounts": cash.balances(branch, timezone.localdate()),
    }


def _branches_for(request):
    scope = read_branch(request)
    queryset = Branch.objects.all().order_by("id")
    return queryset.filter(pk=scope) if scope else queryset


class BranchListView(ShopView, APIView):
    """Both branches (Admin) or your own, each with its three balances and
    today's money in and out per account."""

    def get(self, request):
        return Response([present_branch(b) for b in _branches_for(request)])


class BranchDetailView(ShopView, APIView):
    def get(self, request, pk):
        from ..services.base import get_branch, require_branch

        branch = get_branch(pk)
        require_branch(self.ctx, branch.id)
        return Response(present_branch(branch))


class CashBalancesView(ShopView, APIView):
    """GET /cash/balances?branch= — per account: opening, current, today in/out."""

    def get(self, request):
        return Response({b.id: cash.balances(b, timezone.localdate()) for b in _branches_for(request)})
