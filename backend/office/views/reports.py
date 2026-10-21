"""Reports: the exports the app already offers (shop/services/exports.py) with a
date range and a preview, and the transaction log."""

from urllib.parse import urlencode

from django.http import HttpResponse
from django.shortcuts import render
from django.utils import timezone

from accounts.models import User
from shop.enums import LogAction, LogCategory, LogRecordKind
from shop.models import TransactionLog
from shop.services import exports

from .common import page_context, paged, read_filters

PREVIEW_ROWS = 50
FORMATS = {
    "csv": "text/csv; charset=utf-8",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pdf": "application/pdf",
}


def _report(request):
    kind = request.GET.get("kind")
    kind = kind if kind in exports.KINDS else exports.KINDS[0]
    f = read_filters(request)
    if "from" not in request.GET and "to" not in request.GET:
        # Opened fresh: this month so far, not every record the shop has. Clearing
        # both dates (the fields sent empty) still asks for all dates.
        today = timezone.localdate()
        f.date_from, f.date_to = today.replace(day=1), today
    return kind, f, exports.build(kind, f.branch, f.start, f.end)


def _query(kind, f) -> str:
    """The report's own query, with the dates actually used, for its downloads."""
    return urlencode({"kind": kind, "branch": f.branch or "",
                      "from": f.date_from.isoformat() if f.date_from else "",
                      "to": f.date_to.isoformat() if f.date_to else ""})


def reports(request):
    kind, f, table = _report(request)
    return render(request, "office/reports.html", page_context(
        title="Reports", kind=kind, f=f, table=table, query=_query(kind, f),
        preview=paged(request, table.rows, per=PREVIEW_ROWS),
        kinds=[(k, exports.TITLES[k]) for k in exports.KINDS], formats=FORMATS,
        report_title=exports.TITLES[kind],
        scope="Both branches" if f.branch is None else f.branch.capitalize()))


def download(request, fmt):
    kind, f, table = _report(request)
    if fmt not in FORMATS:
        fmt = "csv"
    title = f"{exports.TITLES[kind]} export"
    raw_from = f.date_from.isoformat() if f.date_from else None
    raw_to = f.date_to.isoformat() if f.date_to else None
    if fmt == "csv":
        body = exports.to_csv(table)
    elif fmt == "xlsx":
        body = exports.to_xlsx(table, title)
    else:
        body = exports.to_pdf(table, title, "Both branches" if f.branch is None else f.branch.capitalize())
    response = HttpResponse(body, content_type=FORMATS[fmt])
    response["Content-Disposition"] = f'attachment; filename="{exports.filename(kind, f.branch, raw_from, raw_to, fmt)}"'
    return response


def log(request):
    """The whole audit trail: who did what, when, to which record."""
    f = read_filters(request, types=LogCategory.values)
    get = request.GET
    person = get.get("person") or ""
    action = get.get("action") if get.get("action") in LogAction.values else ""
    record = (get.get("record") or "").strip()
    queryset = TransactionLog.objects.select_related("branch")
    queryset = f.dated(f.branched(queryset), "at")
    if person:
        queryset = queryset.filter(user_id=person)
    if action:
        queryset = queryset.filter(action=action)
    if f.type:
        queryset = queryset.filter(category=f.type)
    if record:
        queryset = queryset.filter(record_id__iexact=record)
    if f.q:
        queryset = queryset.filter(summary__icontains=f.q)
    return render(request, "office/log.html", page_context(
        title="Transaction log", f=f, page=paged(request, queryset), person=person, action=action, record=record,
        people=User.objects.order_by("name_key"), action_choices=LogAction.choices,
        category_choices=LogCategory.choices, record_kinds=LogRecordKind))
