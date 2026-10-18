"""The cash ledger — the single source of truth for every balance.

Three pots of money per branch, kept apart because they are spent differently:

* purchase — the float customers are paid out of;
* sales    — what came in over the counter;
* bank     — money that never sat in a drawer.

A balance is the branch's opening figure plus every signed entry for that
branch and account. There is no balance column to drift; nothing but a
CashEntry moves money.
"""

from datetime import date, datetime

from django.db.models import Case, F, Q, Sum, Value, When
from django.db.models.functions import Coalesce
from django.utils import timezone

from ..enums import (
    CREDIT_TYPES,
    MANUAL_TYPES,
    BranchId,
    CashAccount,
    CashEntrySourceType,
    CashEntryType,
    LogAction,
    LogRecordKind,
)
from ..errors import NotFound, Refusal
from ..ids import claim, new_id
from ..models import Branch, CashEntry
from ..text import peso
from .base import BRANCH_MANAGERS, Ctx, branch_for_write, change, get_branch, require_branch, require_role, write_log

_SIGNED = Case(
    When(type__in=list(CREDIT_TYPES), then=F("amount_centavos")),
    default=-F("amount_centavos"),
)


def _net(queryset) -> int:
    return queryset.aggregate(net=Coalesce(Sum(_SIGNED), Value(0)))["net"]


def account_balance(branch: Branch | str, account: str) -> int:
    """Opening figure plus every signed ledger entry for this branch and account."""
    branch = branch if isinstance(branch, Branch) else get_branch(branch)
    entries = CashEntry.objects.filter(branch=branch, account=account)
    return branch.starting_balance(account) + _net(entries)


def flow_on(branch_id: str, account: str, day: date) -> tuple[int, int]:
    """Money into and out of one account on one (Manila) day."""
    totals = CashEntry.objects.filter(branch_id=branch_id, account=account, date__date=day).aggregate(
        inflow=Coalesce(Sum("amount_centavos", filter=Q(type__in=list(CREDIT_TYPES))), Value(0)),
        outflow=Coalesce(Sum("amount_centavos", filter=~Q(type__in=list(CREDIT_TYPES))), Value(0)),
    )
    return totals["inflow"], totals["outflow"]


def balances(branch: Branch, day: date | None = None) -> dict:
    """Per account: opening, current, and today's money in and out."""
    day = day or timezone.localdate()
    out = {}
    for account in CashAccount:
        inflow, outflow = flow_on(branch.id, account, day)
        out[account.value] = {
            "label": account.label,
            "opening_centavos": branch.starting_balance(account),
            "current_centavos": account_balance(branch, account),
            "today_in_centavos": inflow,
            "today_out_centavos": outflow,
        }
    return out


# --- writing entries ---------------------------------------------------------

def write_entry(
    ctx: Ctx,
    *,
    branch_id: str,
    type: str,
    amount_centavos: int,
    note: str,
    account: str = CashAccount.PURCHASE,
    category: str | None = None,
    when: datetime | None = None,
    source_type: str = CashEntrySourceType.MANUAL,
    linked_record_id: str | None = None,
    transfer_pair_id: str | None = None,
    entry_id: str | None = None,
) -> CashEntry:
    """The only way money moves. Callers check the rules; this writes the row."""
    return CashEntry.objects.create(
        id=claim(entry_id, "cashEntry") if entry_id else new_id("cashEntry"),
        branch_id=branch_id,
        type=type,
        account=account,
        amount_centavos=amount_centavos,
        note=note,
        category=category,
        date=when or ctx.now,
        recorded_by_role=ctx.actor.role,
        recorded_by=ctx.actor,
        source_type=source_type,
        linked_record_id=linked_record_id,
        transfer_pair_id=transfer_pair_id,
    )


def _check_amount(amount: int) -> None:
    if amount is None or amount <= 0:
        raise Refusal("Amount must be above zero", code="amount_not_positive")


def _check_note(note: str | None) -> str:
    if note is None or not note.strip():
        raise Refusal("An entry needs a note", code="note_required")
    return note.strip()


def record_entry(ctx: Ctx, *, branch_id: str | None, type: str, account: str, amount_centavos: int, note: str,
                 category: str | None = None, when: datetime | None = None, entry_id: str | None = None) -> CashEntry:
    """A hand-typed cash in, expense or withdrawal. Transfers go through
    `record_transfer` so both halves stay matched."""
    require_role(ctx, BRANCH_MANAGERS, "record cash entries")
    branch = branch_for_write(ctx, branch_id)
    if type not in MANUAL_TYPES:
        raise Refusal("Transfers must go through a transfer so both sides stay matched", code="use_transfer")
    _check_amount(amount_centavos)
    note = _check_note(note)
    if type == CashEntryType.EXPENSE:
        if not category or not category.strip():
            raise Refusal("An expense needs a category", code="category_required")
        category = category.strip()
    else:
        category = None
    entry = write_entry(ctx, branch_id=branch.id, type=type, account=account, amount_centavos=amount_centavos,
                        note=note, category=category, when=when, entry_id=entry_id)
    write_log(
        ctx, LogAction.CASH_ENTRY_RECORDED,
        f"{CashEntryType(type).label} of {peso(amount_centavos)} ({CashAccount(account).label}) — {note}",
        branch=branch.id, record_id=entry.id, record_kind=LogRecordKind.CASH_ENTRY, amount_centavos=amount_centavos,
    )
    return entry


def record_transfer(ctx: Ctx, *, from_branch: str | None, to_branch: str, from_account: str, to_account: str,
                    amount_centavos: int, note: str, when: datetime | None = None,
                    out_id: str | None = None, in_id: str | None = None,
                    pair_id: str | None = None) -> tuple[CashEntry, CashEntry]:
    """Moves money as one matched pair: a transferOut and a transferIn sharing
    a pair id, so the two sides can never drift apart."""
    require_role(ctx, BRANCH_MANAGERS, "move cash between accounts or branches")
    if ctx.is_supervisor:
        # A Supervisor moves money where their own branch is one end — into it
        # or out of it — and nowhere else.
        source = get_branch(from_branch or ctx.actor.home_branch)
        destination = get_branch(to_branch)
        if ctx.actor.home_branch not in (source.id, destination.id):
            require_branch(ctx, source.id)
    else:
        source = branch_for_write(ctx, from_branch)
        destination = get_branch(to_branch)
    if source.id == destination.id and from_account == to_account:
        raise Refusal("A transfer needs a different branch or a different cash source", code="transfer_to_itself")
    _check_amount(amount_centavos)
    note = _check_note(note)
    pair = claim(pair_id, "transferPair") if pair_id else new_id("transferPair")
    out = write_entry(ctx, branch_id=source.id, type=CashEntryType.TRANSFER_OUT, account=from_account,
                      amount_centavos=amount_centavos, note=note, when=when, transfer_pair_id=pair, entry_id=out_id)
    inn = write_entry(ctx, branch_id=destination.id, type=CashEntryType.TRANSFER_IN, account=to_account,
                      amount_centavos=amount_centavos, note=note, when=when, transfer_pair_id=pair, entry_id=in_id)
    write_log(
        ctx, LogAction.CASH_TRANSFERRED,
        f"Moved {peso(amount_centavos)} from {source.label} {CashAccount(from_account).label} "
        f"to {destination.label} {CashAccount(to_account).label} — {note}",
        branch=source.id, record_id=out.id, record_kind=LogRecordKind.CASH_ENTRY, amount_centavos=amount_centavos,
    )
    return out, inn


# --- correcting hand-typed entries -------------------------------------------

def get_entry(entry_id: str) -> CashEntry:
    try:
        return CashEntry.objects.get(pk=entry_id)
    except CashEntry.DoesNotExist:
        raise NotFound("Cash entry not found") from None


def lock_reason(entry: CashEntry) -> str | None:
    """Why `entry` can't be changed by hand. Linked entries are the cash side of
    a purchase, sale or loan — they are corrected on that record instead."""
    if entry.is_manual:
        return None
    return (f"This entry was written by a {entry.source_type} ({entry.linked_record_id or 'record'}). "
            f"Correct it on that record, not in the cash history.")


def group_of(entry: CashEntry) -> list[CashEntry]:
    """Both halves of a transfer, out first — or just the entry."""
    if entry.transfer_pair_id is None:
        return [entry]
    group = list(CashEntry.objects.filter(transfer_pair_id=entry.transfer_pair_id))
    return sorted(group, key=lambda e: 0 if e.type == CashEntryType.TRANSFER_OUT else 1)


def _check_editable(ctx: Ctx, entry: CashEntry, doing: str) -> list[CashEntry]:
    require_role(ctx, BRANCH_MANAGERS, doing)
    lock = lock_reason(entry)
    if lock:
        raise Refusal(lock, code="linked_entry", linked_record_id=entry.linked_record_id,
                      source_type=entry.source_type)
    group = group_of(entry)
    if not ctx.is_admin and all(e.branch_id != ctx.actor.home_branch for e in group):
        require_branch(ctx, entry.branch_id)
    return group


def _day(d: datetime) -> str:
    local = timezone.localtime(d)
    return f"{local.year}-{local.month}-{local.day}"


_UNSET = object()


def update_entry(ctx: Ctx, entry_id: str, *, type=_UNSET, account=_UNSET, destination_account=_UNSET,
                 amount_centavos=_UNSET, note=_UNSET, category=_UNSET, when=_UNSET) -> list[dict]:
    """Corrects a hand-typed entry. A transfer changes amount, note and date on
    both halves together, and each half can change its source."""
    entry = get_entry(entry_id)
    group = _check_editable(ctx, entry, "correct cash entries")
    if amount_centavos is not _UNSET:
        _check_amount(amount_centavos)
    if note is not _UNSET:
        _check_note(note)
    first = group[0]
    changes: list[dict] = []

    if entry.is_transfer:
        if type is not _UNSET and type != first.type:
            raise Refusal("A transfer stays a transfer — delete it and record a new entry instead",
                          code="transfer_type_fixed")
        out = next((e for e in group if e.type == CashEntryType.TRANSFER_OUT), first)
        inn = next((e for e in group if e.type == CashEntryType.TRANSFER_IN), first)
        new_from = out.account if account is _UNSET else account
        new_to = inn.account if destination_account is _UNSET else destination_account
        if out.branch_id == inn.branch_id and new_from == new_to:
            raise Refusal("A transfer needs a different branch or a different cash source", code="transfer_to_itself")
        if new_from != out.account:
            changes.append(change("From source", CashAccount(out.account).label, CashAccount(new_from).label))
        if new_to != inn.account:
            changes.append(change("To source", CashAccount(inn.account).label, CashAccount(new_to).label))
    else:
        new_type = entry.type if type is _UNSET else type
        if new_type != entry.type:
            if new_type not in MANUAL_TYPES:
                raise Refusal("Only cash in, expense, or withdrawal", code="invalid_type")
            changes.append(change("Type", CashEntryType(entry.type).label, CashEntryType(new_type).label))
        if account is not _UNSET and account != entry.account:
            changes.append(change("Cash source", CashAccount(entry.account).label, CashAccount(account).label))
        if new_type == CashEntryType.EXPENSE:
            new_category = entry.category if category is _UNSET else (category or "").strip() or None
            if not new_category:
                raise Refusal("An expense needs a category", code="category_required")
        else:
            new_category = None
        if new_category != entry.category:
            changes.append(change("Category", entry.category or "—", new_category or "—"))

    if amount_centavos is not _UNSET and amount_centavos != first.amount_centavos:
        changes.append(change("Amount", peso(first.amount_centavos), peso(amount_centavos)))
    if note is not _UNSET and note.strip() != first.note:
        changes.append(change("Note", first.note, note.strip()))
    if when is not _UNSET and when != first.date:
        changes.append(change("Date", _day(first.date), _day(when)))
    if not changes:
        return changes

    for e in group:
        if amount_centavos is not _UNSET:
            e.amount_centavos = amount_centavos
        if note is not _UNSET:
            e.note = note.strip()
        if when is not _UNSET:
            e.date = when
        if entry.is_transfer:
            if e.type == CashEntryType.TRANSFER_OUT and account is not _UNSET:
                e.account = account
            if e.type == CashEntryType.TRANSFER_IN and destination_account is not _UNSET:
                e.account = destination_account
        else:
            if type is not _UNSET:
                e.type = type
            if account is not _UNSET:
                e.account = account
            e.category = new_category
        e.save()

    write_log(
        ctx, LogAction.CASH_ENTRY_EDITED,
        f"Corrected {CashEntryType(first.type).label} {first.id} — {', '.join(c['field'].lower() for c in changes)}",
        branch=entry.branch_id, record_id=entry.id, record_kind=LogRecordKind.CASH_ENTRY,
        amount_centavos=first.amount_centavos, changes=changes,
    )
    return changes


def delete_entry(ctx: Ctx, entry_id: str, reason: str | None = None) -> None:
    """Removes a hand-typed entry recorded by mistake — both halves, for a
    transfer. One of the few permitted hard deletes; the log keeps what the
    entry was, who removed it, and why."""
    entry = get_entry(entry_id)
    group = _check_editable(ctx, entry, "delete cash entries")
    first = group[0]
    if entry.is_transfer:
        where = (f"{BranchId(group[0].branch_id).label} {CashAccount(group[0].account).label} → "
                 f"{BranchId(group[-1].branch_id).label} {CashAccount(group[-1].account).label}")
    else:
        where = f"{BranchId(entry.branch_id).label} {CashAccount(entry.account).label}"
    changes = [
        change("Type", CashEntryType(first.type).label, "—"),
        change("Amount", peso(first.amount_centavos), "—"),
        change("Source", where, "—"),
        change("Note", first.note, "—"),
    ]
    if first.category is not None:
        changes.append(change("Category", first.category, "—"))
    reason_text = "" if not reason or not reason.strip() else f". Reason: {reason.strip()}"
    summary = (f"Deleted {CashEntryType(first.type).label} {first.id} of {peso(first.amount_centavos)} "
               f"({where}) — {first.note}{reason_text}")
    for e in group:
        e.delete()
    write_log(ctx, LogAction.CASH_ENTRY_DELETED, summary, branch=entry.branch_id, record_id=first.id,
              record_kind=LogRecordKind.CASH_ENTRY, amount_centavos=first.amount_centavos, changes=changes)
