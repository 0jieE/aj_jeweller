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
PER_PAGE_CHOICES = (25, 50, 100)


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


class Pages:
    """One page of a table, and everything its pager shows: which rows these
    are, numbered links around the current page, and the rows-per-page choice.

    Only the page's rows are fetched (a LIMIT/OFFSET query, plus one COUNT),
    so a table loads as fast with ten thousand records as with ten. Iterating
    it gives the rows; `.rows` is a list, so a view can annotate them.
    """

    WINDOW = 2  # page numbers shown either side of the current one

    def __init__(self, request, items, *, param="page", per=PER_PAGE, choices=PER_PAGE_CHOICES):
        self.request, self.param = request, param
        self.per_param = f"{param}_size" if param != "page" else "per"
        if choices:
            asked = request.GET.get(self.per_param, "")
            per = int(asked) if asked.isdigit() and int(asked) in choices else per
        self.per, self.choices = per, choices
        self.page = Paginator(items, per).get_page(request.GET.get(param))
        self.rows = list(self.page.object_list)
        self.paginator = self.page.paginator

    def __iter__(self):
        return iter(self.rows)

    def __len__(self):
        return len(self.rows)

    @property
    def count(self) -> int:
        return self.paginator.count

    @property
    def start(self) -> int:
        return self.page.start_index()

    @property
    def end(self) -> int:
        return self.page.end_index()

    @property
    def number(self) -> int:
        return self.page.number

    @property
    def last(self) -> int:
        return self.paginator.num_pages

    def url(self, number=None, *, per=None) -> str:
        query = self.request.GET.copy()
        if per is not None:
            query[self.per_param] = per
            query.pop(self.param, None)  # a new page size starts again at page one
        elif number is not None:
            query[self.param] = number
        return f"{self.request.path}?{query.urlencode()}"

    def links(self) -> list[dict]:
        """1 … 4 5 [6] 7 8 … 20: the first, the last, and the current page's neighbours."""
        shown = {1, self.last, *range(self.number - self.WINDOW, self.number + self.WINDOW + 1)}
        out, previous = [], 0
        for n in sorted(x for x in shown if 1 <= x <= self.last):
            if n - previous > 1:
                out.append({"gap": True})
            out.append({"number": n, "url": self.url(n), "current": n == self.number})
            previous = n
        return out

    def sizes(self) -> list[dict]:
        if not self.choices or self.count <= min(self.choices):
            return []
        return [{"size": n, "url": self.url(per=n), "current": n == self.per} for n in self.choices]

    def first_url(self):
        return self.url(1) if self.number > 1 else None

    def previous_url(self):
        return self.url(self.number - 1) if self.page.has_previous() else None

    def next_url(self):
        return self.url(self.number + 1) if self.page.has_next() else None

    def last_url(self):
        return self.url(self.last) if self.number < self.last else None


def paged(request, items, **options) -> Pages:
    return Pages(request, items, **options)


def history(request, *record_ids) -> Pages:
    """The log entries about these records, newest first, a page at a time."""
    entries = TransactionLog.objects.filter(record_id__in=[r for r in record_ids if r]).select_related("branch")
    return paged(request, entries, param="hpage", per=20, choices=())


def page_context(**extra) -> dict:
    return {"branch_choices": BranchId.choices, **extra}
