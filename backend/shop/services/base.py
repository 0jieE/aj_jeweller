"""What every service needs: who is acting, when, and how to write the log.

Services are the only code that changes records. Each public service function
is one mutation: it checks the rules, makes the change, and writes exactly one
TransactionLog row naming the actor. Views call services; nothing else does.
"""

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING

from django.db import connection
from django.utils import timezone

from ..enums import BranchId, LogAction, Role, category_for
from ..errors import Forbidden, NotFound
from ..ids import new_id
from ..models import Branch, TransactionLog

if TYPE_CHECKING:
    from accounts.models import User

# Arbitrary constant identifying the shop's single write lock.
_WRITE_LOCK_KEY = 70_61_2026


def acquire_write_lock() -> None:
    """Serialises every write for the rest of the current transaction.

    The shop is two branches and a handful of staff, so writes are rare enough
    to take one at a time. In exchange no rule can race another (two cashiers
    releasing one purchase), and the sync feed's sequence order is exactly
    commit order. Must be called inside a transaction.
    """
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_advisory_xact_lock(%s)", [_WRITE_LOCK_KEY])


@dataclass(frozen=True)
class Ctx:
    """One request's actor and clock.

    `now` is when the action happened. For a change queued on a phone while it
    was offline that is the time it was made there (X-Recorded-At), which can
    be earlier than `received_at`, when the server got it.
    """

    actor: "User"
    now: datetime
    received_at: datetime

    @classmethod
    def for_user(cls, actor, now: datetime | None = None) -> "Ctx":
        received = timezone.now()
        return cls(actor=actor, now=now or received, received_at=received)

    @property
    def is_admin(self) -> bool:
        return self.actor.role == Role.ADMIN


# --- who may do what ---------------------------------------------------------

ENCODE_PURCHASES = frozenset({Role.ASSISTANT_APPRAISER, Role.ADMIN})
BUILD_SALES = frozenset({Role.SALES_REP, Role.ADMIN})
MOVE_CASH = frozenset({Role.CASHIER, Role.ADMIN})
ADMIN_ONLY = frozenset({Role.ADMIN})

_ROLE_WORDS = {
    ENCODE_PURCHASES: "an Assistant Appraiser or Admin",
    BUILD_SALES: "a Sales Rep or Admin",
    MOVE_CASH: "a Cashier or Admin",
    ADMIN_ONLY: "an Admin",
}


def require_role(ctx: Ctx, roles: frozenset, doing: str) -> None:
    """Refuses with 403 unless the actor holds one of `roles`.

    `doing` completes the sentence "Only a Cashier or Admin can ...".
    """
    if ctx.actor.role not in roles:
        raise Forbidden(f"Only {_ROLE_WORDS[roles]} can {doing}", code="role")


def require_branch(ctx: Ctx, branch_id: str | None) -> None:
    """Branch staff act on their own branch; Admin acts on both."""
    if ctx.is_admin or branch_id is None:
        return
    if ctx.actor.home_branch != branch_id:
        raise Forbidden(
            f"You work from {BranchId(ctx.actor.home_branch).label} — this belongs to {BranchId(branch_id).label}",
            code="branch",
        )


def get_branch(branch_id: str | None) -> Branch:
    if branch_id is None:
        raise NotFound("A branch is required")
    try:
        return Branch.objects.get(pk=branch_id)
    except Branch.DoesNotExist:
        raise NotFound(f'"{branch_id}" is not a branch — use kidapawan or davao') from None


def branch_for_write(ctx: Ctx, branch_id: str | None) -> Branch:
    """The branch a new record goes to: the one asked for, else the actor's own."""
    chosen = branch_id or ctx.actor.home_branch
    if chosen is None:
        raise NotFound("Pick a branch — an Admin works across both")
    require_branch(ctx, chosen)
    return get_branch(chosen)


# --- the log -----------------------------------------------------------------

def change(field: str, before, after) -> dict:
    """One field's before/after, as the strings the app writes."""
    return {"field": field, "before": str(before), "after": str(after)}


def write_log(
    ctx: Ctx,
    action: LogAction,
    summary: str,
    *,
    branch: str | None = None,
    record_id: str | None = None,
    record_kind: str | None = None,
    amount_centavos: int | None = None,
    changes: list[dict] | tuple = (),
) -> TransactionLog:
    return TransactionLog.objects.create(
        id=new_id("log"),
        at=ctx.now,
        received_at=ctx.received_at,
        action=action,
        category=category_for(action),
        user=ctx.actor,
        user_name=ctx.actor.name,
        role=ctx.actor.role,
        summary=summary,
        branch_id=branch,
        record_id=record_id,
        record_kind=record_kind,
        amount_centavos=amount_centavos,
        changes=list(changes),
    )


def blank_to_none(value: str | None) -> str | None:
    if value is None:
        return None
    trimmed = value.strip()
    return trimmed or None
