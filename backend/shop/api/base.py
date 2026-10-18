"""What every shop endpoint shares.

For a write (POST/PUT/PATCH/DELETE) the view:

1. opens one transaction and takes the shop's write lock;
2. signs the request in (JWT) and builds the `Ctx` — the actor from the token,
   never from the body, and the clock (`X-Recorded-At` for an offline change);
3. honours `Idempotency-Key`: a replay gets the first response back;
4. runs the service, which refuses with 422 or writes the change plus exactly
   one log row; a refusal rolls the whole transaction back.
"""

from datetime import datetime, time, timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_date, parse_datetime
from rest_framework import exceptions
from rest_framework.permissions import SAFE_METHODS
from rest_framework.response import Response

from .. import idempotency
from ..enums import BranchId, oversees_both
from ..errors import Forbidden, Refusal
from ..services.base import Ctx, acquire_write_lock

RECORDED_AT_HEADER = "X-Recorded-At"


class _Replay(Exception):
    def __init__(self, record):
        self.record = record


def parse_when(value: str, *, field: str = "date") -> datetime:
    """An ISO date or datetime. Times without an offset are Manila time,
    which is what the phone's `toIso8601String()` sends."""
    dt = parse_datetime(value) if value else None
    if dt is None:
        d = parse_date(value) if value else None
        if d is None:
            raise exceptions.ValidationError({field: [f'"{value}" is not an ISO-8601 date or time']})
        dt = datetime.combine(d, time.min)
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt)
    return dt


class ShopView:
    """Mixin for APIView / ViewSet classes; see the module docstring."""

    ctx: Ctx

    # --- the transaction around a write ----------------------------------
    def dispatch(self, request, *args, **kwargs):
        if request.method in SAFE_METHODS:
            return super().dispatch(request, *args, **kwargs)
        self._idem = None
        self._replayed = False
        with transaction.atomic():
            acquire_write_lock()
            response = super().dispatch(request, *args, **kwargs)
            if self._idem and not self._replayed and response.status_code < 400:
                idempotency.store(response=response, **self._idem)
        if self._idem and not self._replayed and 400 <= response.status_code < 500:
            # The refusal rolled its transaction back; remember it on its own.
            with transaction.atomic():
                acquire_write_lock()
                idempotency.store(response=response, **self._idem)
        return response

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        received = timezone.now()
        self.ctx = Ctx(actor=request.user, now=self._recorded_at(request, received), received_at=received)
        if request.method not in SAFE_METHODS and request.user is not None:
            self._check_idempotency(request)

    def handle_exception(self, exc):
        if isinstance(exc, _Replay):
            self._replayed = True
            record = exc.record
            return Response(record.body, status=record.status_code, headers={"Idempotent-Replayed": "true"})
        return super().handle_exception(exc)

    def _check_idempotency(self, request) -> None:
        key = request.headers.get(idempotency.HEADER)
        if not key:
            return
        if len(key) > idempotency.MAX_KEY_LENGTH:
            raise Refusal("An Idempotency-Key is at most 128 characters", code="idempotency_key_invalid")
        path = request.path
        fp = idempotency.fingerprint(request.method, path, request._request.body, request.user.pk)
        existing = idempotency.find(request.user, key)
        if existing is not None:
            if existing.fingerprint != fp:
                raise Refusal(
                    "That Idempotency-Key was already used for a different request",
                    code="idempotency_key_reused",
                )
            raise _Replay(existing)
        self._idem = {"user": request.user, "key": key, "method": request.method, "path": path, "fp": fp}

    @staticmethod
    def _recorded_at(request, received: datetime) -> datetime:
        raw = request.headers.get(RECORDED_AT_HEADER)
        if not raw or request.method in SAFE_METHODS:
            return received
        when = parse_when(raw, field=RECORDED_AT_HEADER)
        if when > received + timedelta(seconds=settings.SYNC_MAX_CLOCK_SKEW_SECONDS):
            raise Refusal("This change is dated in the future — check the phone's clock", code="recorded_at_future")
        if when < received - timedelta(days=settings.SYNC_MAX_BACKDATE_DAYS):
            raise Refusal(
                f"This change was made more than {settings.SYNC_MAX_BACKDATE_DAYS} days ago and is too old to "
                f"apply — ask an Admin to enter it by hand",
                code="recorded_at_too_old",
            )
        return when


# --- reading -----------------------------------------------------------------

def read_branch(request) -> str | None:
    """The branch a list is scoped to. Branch staff see their own branch;
    Admin sees both (None) unless `?branch=` narrows it."""
    asked = request.query_params.get("branch") or None
    if asked is not None and asked not in BranchId.values:
        raise exceptions.ValidationError({"branch": [f'"{asked}" is not a branch — use kidapawan or davao']})
    user = request.user
    if oversees_both(user.role):
        return asked
    if asked is not None and asked != user.home_branch:
        raise Forbidden(f"You work from {BranchId(user.home_branch).label} — you can only see its records",
                        code="branch")
    return user.home_branch


def date_range(request) -> tuple[datetime | None, datetime | None]:
    """`?from=` and `?to=` as an inclusive day range (or exact times)."""
    start = end = None
    raw_from = request.query_params.get("from")
    raw_to = request.query_params.get("to")
    if raw_from:
        start = parse_when(raw_from, field="from")
    if raw_to:
        end = parse_when(raw_to, field="to")
        # A bare date covers the whole day; an exact time is included itself.
        end = end + (timedelta(days=1) if parse_datetime(raw_to) is None else timedelta(microseconds=1))
    return start, end


def filter_dates(queryset, request, field: str):
    start, end = date_range(request)
    if start is not None:
        queryset = queryset.filter(**{f"{field}__gte": start})
    if end is not None:
        queryset = queryset.filter(**{f"{field}__lt": end})
    return queryset


def query_bool(request, name: str) -> bool | None:
    raw = request.query_params.get(name)
    if raw is None or raw == "":
        return None
    return raw.lower() in {"1", "true", "yes", "on"}
