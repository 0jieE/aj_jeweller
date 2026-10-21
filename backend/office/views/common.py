"""What the office's pages share: the filters, the pages of a table, and the
one way a page writes.

Writes: every change a page makes is one call into shop/services, run by
`attempt` under the shop's write lock — the same functions the API calls, so
the same rules, the same log entry naming the Superuser, and the same
SyncChange rows that tell the phones something moved. No page writes a model
directly.
"""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from django.core.paginator import Paginator
from django.utils import timezone
from django.utils.dateparse import parse_date

from shop.admin_tools import run
from shop.enums import BranchId
from shop.errors import ShopError
from shop.models import TransactionLog
from shop.services.base import Ctx

PER_PAGE = 50


def ctx(request) -> Ctx:
    return Ctx.for_user(request.user)


def attempt(fn):
    """Runs one service call for real. Returns (result, None), or (None, the
    service's own refusal sentence) with nothing saved."""
    try:
        return run(fn), None
    except ShopError as error:
        return None, error.message


def day_start(day: date) -> datetime:
    """Midnight in Manila, as an aware time."""
    return timezone.make_aware(datetime.combine(day, time.min))


@dataclass
class Filters:
    """The filters the app's lists have: branch, date range, status, type,
    search. A value that isn't one of the choices is ignored, not an error."""

    branch: str | None
    date_from: date | None
    date_to: date | None
    status: str
    type: str
    q: str

    @property
    def start(self) -> datetime | None:
        return day_start(self.date_from) if self.date_from else None

    @property
    def end(self) -> datetime | None:
        """Exclusive: the midnight after `date_to`, so the last day is whole."""
        return day_start(self.date_to + timedelta(days=1)) if self.date_to else None

    def dated(self, queryset, field: str):
        if self.start:
            queryset = queryset.filter(**{f"{field}__gte": self.start})
        if self.end:
            queryset = queryset.filter(**{f"{field}__lt": self.end})
        return queryset

    def branched(self, queryset, field: str = "branch_id"):
        return queryset.filter(**{field: self.branch}) if self.branch else queryset


def _day(raw: str | None) -> date | None:
    try:
        return parse_date(raw) if raw else None
    except ValueError:
        return None


def read_filters(request, *, statuses=(), types=()) -> Filters:
    get = request.GET
    branch = get.get("branch") or None
    status = get.get("status") or ""
    kind = get.get("type") or ""
    return Filters(
        branch=branch if branch in BranchId.values else None,
        date_from=_day(get.get("from")),
        date_to=_day(get.get("to")),
        status=status if status in statuses else "",
        type=kind if kind in types else "",
        q=(get.get("q") or "").strip(),
    )


def paged(request, queryset):
    return Paginator(queryset, PER_PAGE).get_page(request.GET.get("page"))


def history(*record_ids):
    """The log entries about these records, newest first."""
    return TransactionLog.objects.filter(record_id__in=[r for r in record_ids if r]).select_related("branch")


def page_context(**extra) -> dict:
    return {"branch_choices": BranchId.choices, **extra}
