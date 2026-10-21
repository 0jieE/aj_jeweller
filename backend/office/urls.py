"""Every address under /administrator/.

`pages` is everything past the sign-in, and every one of them is wrapped in
`superuser_only` below — in one place, so no page can be added without the
check. The last pattern catches any other address, so an unknown path here is
the office's own 404 and never the Flutter app's index.html.
"""

from django.urls import path, re_path

from .access import superuser_only
from .views import auth, desk, rates, records, reports, staff, today

app_name = "office"

public = [
    path("login/", auth.login, name="login"),
    path("logout/", auth.logout, name="logout"),
]

pages = [
    path("", today.today, name="today"),
    # Records
    path("purchases/", records.purchases, name="purchases"),
    path("purchases/<str:pk>/", records.purchase, name="purchase"),
    path("sales/", records.sales, name="sales"),
    path("sales/<str:pk>/", records.sale, name="sale"),
    path("items/", records.items_list, name="items"),
    path("items/<str:pk>/", records.item, name="item"),
    path("items/<str:pk>/correct/", desk.item_correct, name="item-correct"),
    path("cash/", records.cash_entries, name="cash-entries"),
    path("cash/new/", desk.cash_new, name="cash-new"),
    path("cash/transfer/", desk.cash_transfer, name="cash-transfer"),
    path("cash/<str:pk>/", records.cash_entry, name="cash-entry"),
    path("cash/<str:pk>/correct/", desk.cash_edit, name="cash-edit"),
    path("cash/<str:pk>/delete/", desk.cash_delete, name="cash-delete"),
    path("customers/", records.customers, name="customers"),
    path("customers/<str:pk>/", records.customer, name="customer"),
    path("commitments/", records.commitments_list, name="commitments"),
    path("commitments/new/", desk.commitment_new, name="commitment-new"),
    path("commitments/<str:pk>/", records.commitment, name="commitment"),
    path("commitments/<str:pk>/receive/", desk.commitment_receive, name="commitment-receive"),
    path("disposal/", records.disposals, name="disposals"),
    path("disposal/new/", desk.disposal_new, name="disposal-new"),
    path("disposal/<str:pk>/", records.disposal_batch, name="disposal"),
    # Reports and the log
    path("reports/", reports.reports, name="reports"),
    path("reports/download.<str:fmt>", reports.download, name="report-download"),
    path("log/", reports.log, name="log"),
    # Staff
    path("staff/", staff.staff, name="staff"),
    path("staff/new/", staff.staff_new, name="staff-new"),
    path("staff/<str:pk>/", staff.staff_member, name="staff-member"),
    path("staff/<str:pk>/edit/", staff.staff_edit, name="staff-edit"),
    path("staff/<str:pk>/pin/", staff.staff_pin, name="staff-pin"),
    path("staff/<str:pk>/active/", staff.staff_active, name="staff-active"),
    path("staff/<str:pk>/delete/", staff.staff_delete, name="staff-delete"),
    # Rates
    path("rates/", rates.rates, name="rates"),
    path("rates/add/", rates.rate_add, name="rate-add"),
    path("rates/apply/", rates.rates_apply, name="rates-apply"),
    path("rates/<int:karat>/", rates.rate_update, name="rate-update"),
    # Anything else under /administrator/
    re_path(r"^(?P<path>.*)$", auth.not_found, name="not-found"),
]

for page in pages:
    page.callback = superuser_only(page.callback)

urlpatterns = public + pages
