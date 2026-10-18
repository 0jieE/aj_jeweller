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

from ..enums import BranchId, LogAction, Role, category_for, oversees_both
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
        """Oversees both branches: an Admin, or a Superuser (an Admin everywhere in the shop)."""
        return oversees_both(self.actor.role)

    @property
    def is_supervisor(self) -> bool:
        return self.actor.role == Role.SUPERVISOR


# --- who may do what ---------------------------------------------------------

# A Superuser is an Admin everywhere in the shop, so every set an Admin is in
# holds the Superuser too. A Supervisor's sets are additionally scoped to their
# home_branch by require_branch / branch_for_write wherever they are used.
_BOTH = {Role.ADMIN, Role.SUPERUSER}

# Counter work is shared by everybody. When the Cashier is out, the Appraiser
# or the Sales Rep carries on: a role says what someone is normally
# responsible for and who is notified, not what they may do. Every record
# names whoever actually did the work, so covering for a colleague shows in
# the log. Branch scoping still applies: anyone may do counter work, but only
# at their own branch (an Admin or Superuser at either).
COUNTER_STAFF = frozenset(Role)
# The three counter jobs keep their own names, so each call site says what the
# action is — and narrowing one again is a one-line change here.
ENCODE_PURCHASES = COUNTER_STAFF  # encode, correct and resubmit a purchase
BUILD_SALES = COUNTER_STAFF  # build, resubmit and hold pieces for an order
MOVE_CASH = COUNTER_STAFF  # release cash to a customer, receive payment, return either for correction

# Running a branch is not shared: the cash ledger (the shop's own money moved
# and accounted for), corrections, partition returns, disposal, the branch's
# loans and its counter staff. A Supervisor at their own branch; an Admin or
# Superuser at both.
BRANCH_MANAGERS = frozenset({Role.SUPERVISOR, *_BOTH})
ADMIN_ONLY = frozenset(_BOTH)

# What a refusal says. A set that admits every role never refuses, so it has
# no sentence here.
_ROLE_WORDS = {
    BRANCH_MANAGERS: "a Supervisor or Admin",
    ADMIN_ONLY: "an Admin",
}


def require_role(ctx: Ctx, roles: frozenset, doing: str) -> None:
    """Refuses with 403 unless the actor holds one of `roles`.

    `doing` completes the sentence "Only a Supervisor or Admin can ...".
    Against COUNTER_STAFF this always passes; the call stays so the action
    is labelled at its call site.
    """
    if ctx.actor.role in roles:
        return
    words = _ROLE_WORDS.get(roles)
    if words is None:  # a narrowed set without its own sentence yet
        raise Forbidden(f"You can't {doing}", code="role")
    raise Forbidden(f"Only {words} can {doing}", code="role")


def require_branch(ctx: Ctx, branch_id: str | None) -> None:
    """Branch staff and Supervisors act on their own branch; Admin acts on both."""
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
