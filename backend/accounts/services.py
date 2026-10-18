"""Staff management — the rules of AppRepository's staff section, server-side.

* Names are unique ignoring case and spacing.
* Branch staff work from one branch; Admin works across both.
* At least one active Admin must always exist.
* Anyone who appears on a record is deactivated, never deleted.
* You can't deactivate or delete yourself.
"""

import re
from datetime import timedelta

from django.conf import settings
from django.db.models import Q
from django.utils import timezone

from shop.enums import BranchId, LogAction, LogRecordKind, Role
from shop.errors import NotFound, Refusal
from shop.ids import claim_user_id
from shop.services.base import ADMIN_ONLY, Ctx, blank_to_none, change, require_role, write_log

from .models import User, name_key

PIN_RE = re.compile(r"^\d{4,6}$")


def _branch_label(branch: str | None) -> str:
    return BranchId(branch).label if branch else "Both branches"


def get_user(user_id: str) -> User:
    try:
        return User.objects.get(pk=user_id)
    except User.DoesNotExist:
        raise NotFound("User not found") from None


def name_problem(name: str, except_id: str | None = None) -> str | None:
    """Why `name` can't be used for a new or renamed user, or None if it can."""
    trimmed = (name or "").strip()
    if not trimmed:
        return "A user needs a name"
    clash = User.objects.filter(name_key=name_key(trimmed)).exclude(pk=except_id).first()
    if clash is not None:
        return f"{clash.name} is already on file{'' if clash.active else ' (deactivated)'}"
    return None


def _check_branch_for_role(role: str, branch: str | None) -> None:
    if role != Role.ADMIN and branch is None:
        raise Refusal(f"A {Role(role).label} works from one branch — pick it", code="branch_required")


def _active_admin_count() -> int:
    return User.objects.filter(active=True, role=Role.ADMIN).count()


def check_pin(pin: str) -> str:
    if not isinstance(pin, str) or not PIN_RE.match(pin):
        raise Refusal("A PIN is 4 to 6 digits", code="invalid_pin")
    return pin


def activity_count(user_id: str) -> int:
    """How many records name this person — purchases, sales, cash, rates, logs."""
    from shop.models import CashEntry, Item, PurchaseBatch, RateChange, Sale, TransactionLog

    return (
        TransactionLog.objects.filter(user_id=user_id).count()
        + Item.objects.filter(encoded_by_id=user_id).count()
        + PurchaseBatch.objects.filter(Q(submitted_by_id=user_id) | Q(released_by_id=user_id)).count()
        + Sale.objects.filter(Q(submitted_by_id=user_id) | Q(received_by_id=user_id)).count()
        + CashEntry.objects.filter(recorded_by_id=user_id).count()
        + RateChange.objects.filter(user_id=user_id).count()
    )


def add_user(ctx: Ctx, *, name: str, role: str, home_branch: str | None = None,
             contact_number: str | None = None, pin: str, user_id: str | None = None) -> User:
    require_role(ctx, ADMIN_ONLY, "manage staff")
    problem = name_problem(name)
    if problem:
        raise Refusal(problem, code="name_taken" if name.strip() else "name_required")
    _check_branch_for_role(role, home_branch)
    check_pin(pin)
    user = User(
        id=claim_user_id(user_id),
        name=name.strip(),
        role=role,
        home_branch=None if role == Role.ADMIN else home_branch,
        contact_number=blank_to_none(contact_number),
        created_at=ctx.now,
    )
    user.set_password(pin)
    user.save()
    write_log(
        ctx, LogAction.USER_ADDED,
        f"Added {user.name} as {Role(role).label}"
        f"{'' if user.home_branch is None else ' at ' + BranchId(user.home_branch).label}",
        branch=user.home_branch, record_id=user.id, record_kind=LogRecordKind.USER,
    )
    return user


_UNSET = object()


def update_user(ctx: Ctx, user_id: str, *, name=_UNSET, role=_UNSET, home_branch=_UNSET,
                contact_number=_UNSET) -> list[dict]:
    """Edits a staff member. Past records keep their id, so they now show the
    corrected name — the person didn't change, only how they're written."""
    require_role(ctx, ADMIN_ONLY, "manage staff")
    old = get_user(user_id)
    new_name = old.name if name is _UNSET else (name or "").strip()
    new_role = old.role if role is _UNSET else role
    if new_role == Role.ADMIN:
        new_branch = None
    else:
        new_branch = old.home_branch if home_branch is _UNSET or home_branch is None else home_branch
    new_contact = old.contact_number if contact_number is _UNSET else blank_to_none(contact_number)

    if new_name != old.name:
        problem = name_problem(new_name, except_id=old.id)
        if problem:
            raise Refusal(problem, code="name_taken" if new_name else "name_required")
    _check_branch_for_role(new_role, new_branch)
    if old.active and old.role == Role.ADMIN and new_role != Role.ADMIN and _active_admin_count() <= 1:
        raise Refusal(f"{old.name} is the only active Admin — make someone else Admin first", code="last_admin")

    changes = []
    if new_name != old.name:
        changes.append(change("Name", old.name, new_name))
    if new_role != old.role:
        changes.append(change("Role", Role(old.role).label, Role(new_role).label))
    if new_branch != old.home_branch:
        changes.append(change("Branch", _branch_label(old.home_branch), _branch_label(new_branch)))
    if new_contact != old.contact_number:
        changes.append(change("Contact", old.contact_number or "—", new_contact or "—"))
    if not changes:
        return changes

    old.name, old.role, old.home_branch, old.contact_number = new_name, new_role, new_branch, new_contact
    old.save()
    write_log(
        ctx, LogAction.USER_UPDATED,
        f"Edited {new_name} — {', '.join(c['field'].lower() for c in changes)}",
        branch=new_branch, record_id=old.id, record_kind=LogRecordKind.USER, changes=changes,
    )
    return changes


def set_active(ctx: Ctx, user_id: str, active: bool) -> User:
    """Turns a staff member off or back on. A deactivated person can't sign in,
    but every record they made still names them."""
    require_role(ctx, ADMIN_ONLY, "manage staff")
    user = get_user(user_id)
    if user.active == active:
        return user  # already so: nothing changes, nothing to log
    if not active:
        if ctx.actor.id == user.id:
            raise Refusal("You can't deactivate yourself — switch to another Admin first", code="self")
        if user.role == Role.ADMIN and _active_admin_count() <= 1:
            raise Refusal(f"{user.name} is the only active Admin — the shop needs at least one", code="last_admin")
    user.active = active
    user.save()
    write_log(
        ctx, LogAction.USER_REACTIVATED if active else LogAction.USER_DEACTIVATED,
        f"{'Reactivated' if active else 'Deactivated'} {user.name} ({user.role_label})",
        branch=user.home_branch, record_id=user.id, record_kind=LogRecordKind.USER,
    )
    return user


def delete_problem(ctx: Ctx, user: User) -> tuple[str, int] | None:
    """Why `user` can't be deleted outright, with the record count, or None."""
    if ctx.actor.id == user.id:
        return "You can't delete yourself", 0
    if user.active and user.role == Role.ADMIN and _active_admin_count() <= 1:
        return f"{user.name} is the only active Admin", 0
    count = activity_count(user.id)
    if count > 0:
        return (f"{user.name} appears on {count} record(s). Deactivate them instead, "
                f"so those records keep their name."), count
    return None


def delete_user(ctx: Ctx, user_id: str) -> None:
    """Removes someone added by mistake who never did anything."""
    require_role(ctx, ADMIN_ONLY, "manage staff")
    user = get_user(user_id)
    problem = delete_problem(ctx, user)
    if problem:
        message, count = problem
        raise Refusal(message, code="user_has_records" if count else "cannot_delete", record_count=count)
    summary = f"Deleted {user.name} ({user.role_label}) — added by mistake, never used"
    branch, uid = user.home_branch, user.id
    user.delete()
    write_log(ctx, LogAction.USER_DELETED, summary, branch=branch, record_id=uid, record_kind=LogRecordKind.USER)


def set_pin(ctx: Ctx, user_id: str, pin: str) -> User:
    """Admin sets or resets someone's PIN. Signs them out everywhere."""
    require_role(ctx, ADMIN_ONLY, "set someone else's PIN")
    user = get_user(user_id)
    check_pin(pin)
    had_pin = user.has_pin
    user.set_password(pin)
    user.failed_pin_attempts = 0
    user.locked_until = None
    user.save()
    write_log(
        ctx, LogAction.USER_UPDATED, f"{'Reset' if had_pin else 'Set'} the PIN of {user.name}",
        branch=user.home_branch, record_id=user.id, record_kind=LogRecordKind.USER,
        changes=[change("PIN", "set" if had_pin else "—", "reset" if had_pin else "set")],
    )
    return user


def change_own_pin(ctx: Ctx, current_pin: str, new_pin: str) -> User:
    user = ctx.actor
    if not user.check_password(current_pin or ""):
        raise Refusal("Your current PIN is not right", code="wrong_pin")
    check_pin(new_pin)
    user.set_password(new_pin)
    user.save()
    write_log(
        ctx, LogAction.USER_UPDATED, f"{user.name} changed their PIN",
        branch=user.home_branch, record_id=user.id, record_kind=LogRecordKind.USER,
        changes=[change("PIN", "set", "changed")],
    )
    return user


# --- signing in --------------------------------------------------------------

class SignInRefused(Exception):
    def __init__(self, message: str, code: str, status: int = 401):
        super().__init__(message)
        self.message, self.code, self.status = message, code, status


def authenticate_pin(*, user_id: str | None, name: str | None, pin: str) -> User:
    """Checks a name (or id) and PIN, counting wrong tries towards a lockout.

    Not a logged mutation: signing in changes no shop record, only the
    attempt counter on the person.
    """
    query = User.objects.all()
    if user_id:
        user = query.filter(pk=user_id).first()
    else:
        user = query.filter(name_key=name_key(name or "")).first()
    mismatch = SignInRefused("That name and PIN don't match", "bad_credentials")
    if user is None:
        raise mismatch
    if not user.active:
        raise SignInRefused(f"{user.name} has been deactivated — ask an Admin", "inactive", 403)
    now = timezone.now()
    if user.locked_until and user.locked_until > now:
        minutes = max(1, int((user.locked_until - now).total_seconds() // 60) + 1)
        raise SignInRefused(f"Too many wrong PINs — try again in {minutes} minute(s)", "locked", 403)
    if not user.has_pin:
        raise SignInRefused(f"No PIN has been set for {user.name} yet — ask an Admin", "no_pin", 403)
    if not user.check_password(pin or ""):
        user.failed_pin_attempts += 1
        if user.failed_pin_attempts >= settings.PIN_MAX_ATTEMPTS:
            user.failed_pin_attempts = 0
            user.locked_until = now + timedelta(minutes=settings.PIN_LOCKOUT_MINUTES)
        user.save(update_fields=["failed_pin_attempts", "locked_until"])
        raise mismatch
    user.failed_pin_attempts = 0
    user.locked_until = None
    user.last_login = now
    user.save(update_fields=["failed_pin_attempts", "locked_until", "last_login"])
    return user
