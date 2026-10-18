"""Every endpoint under /api/v1/. Trailing slashes are optional."""

from django.urls import re_path
from rest_framework.routers import SimpleRouter

from accounts import api as accounts
from notifications import api as devices

from . import branches, views_money, views_records, views_scrap, views_stock, views_sync


class Router(SimpleRouter):
    def __init__(self):
        super().__init__()
        self.trailing_slash = "/?"  # the spec's paths have none; accept either


router = Router()
router.register("users", accounts.UserViewSet, basename="user")
router.register("customers", views_stock.CustomerViewSet, basename="customer")
router.register("purchases", views_stock.PurchaseViewSet, basename="purchase")
router.register("items", views_stock.ItemViewSet, basename="item")
router.register("sales", views_money.SaleViewSet, basename="sale")
router.register("cash/entries", views_money.CashEntryViewSet, basename="cash-entry")
router.register("disposal", views_scrap.DisposalViewSet, basename="disposal")
router.register("commitments", views_scrap.CommitmentViewSet, basename="commitment")
router.register("receipts", views_records.ReceiptViewSet, basename="receipt")
router.register("logs", views_records.LogViewSet, basename="log")

urlpatterns = [
    # Session and staff
    re_path(r"^auth/login/?$", accounts.LoginView.as_view(), name="login"),
    re_path(r"^auth/refresh/?$", accounts.RefreshView.as_view(), name="refresh"),
    re_path(r"^auth/staff/?$", accounts.StaffDirectoryView.as_view(), name="staff"),
    re_path(r"^me/?$", accounts.MeView.as_view(), name="me"),
    re_path(r"^me/pin/?$", accounts.MyPinView.as_view(), name="me-pin"),
    re_path(r"^devices/?$", devices.DeviceListView.as_view(), name="devices"),
    re_path(r"^devices/(?P<token>[^/]+)/?$", devices.DeviceDetailView.as_view(), name="device"),
    # Reference
    re_path(r"^branches/?$", branches.BranchListView.as_view(), name="branches"),
    re_path(r"^branches/(?P<pk>[a-z]+)/?$", branches.BranchDetailView.as_view(), name="branch"),
    re_path(r"^cash/balances/?$", branches.CashBalancesView.as_view(), name="cash-balances"),
    re_path(r"^cash/transfers/?$", views_money.TransferView.as_view(), name="cash-transfers"),
    re_path(r"^rates/?$", views_records.RatesView.as_view(), name="rates"),
    re_path(r"^rates/history/?$", views_records.RateHistoryView.as_view(), name="rate-history"),
    re_path(r"^rates/on/(?P<day>[^/]+)/?$", views_records.RatesOnView.as_view(), name="rates-on"),
    re_path(r"^rates/apply/?$", views_records.RatesApplyView.as_view(), name="rates-apply"),
    re_path(r"^rates/(?P<karat>\d+)/?$", views_records.RateDetailView.as_view(), name="rate"),
    # Purchases
    re_path(r"^partitions/(?P<pk>[^/]+)/?$", views_stock.PartitionView.as_view(), name="partition"),
    # Exports
    re_path(r"^exports/(?P<kind>[a-z]+)/?$", views_records.ExportView.as_view(), name="export"),
    # Sync: the one-time import and the offline outbox
    re_path(r"^sync/import/?$", views_sync.ImportView.as_view(), name="sync-import"),
    re_path(r"^sync/snapshot/?$", views_sync.SnapshotView.as_view(), name="sync-snapshot"),
    re_path(r"^sync/changes/?$", views_sync.ChangesView.as_view(), name="sync-changes"),
    re_path(r"^sync/push/?$", views_sync.PushView.as_view(), name="sync-push"),
]

urlpatterns += router.urls
