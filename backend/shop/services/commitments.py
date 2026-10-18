"""Commitments: cash loans repaid in scrap.

A commitment stores no balance, no repaid amount and no status. All three are
derived from the disposal batches applied to it — `loanPaid` is never a button
someone presses, it is what the arithmetic says once the balance reaches zero.
"""

from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal

from django.core.files.base import ContentFile
from django.db.models import Sum

from notifications import events as notify

from ..enums import (
    CashAccount,
    CashEntrySourceType,
    CashEntryType,
    CommitmentStatus,
    LogAction,
    LogRecordKind,
)
from ..errors import Forbidden, NotFound, Refusal
from ..ids import claim
from ..models import Commitment
from ..text import peso
from . import cash
from .base import BRANCH_MANAGERS, Ctx, get_branch, require_branch, require_role, write_log

THREE = Decimal("0.001")


def _grams(centavos: int, rate: int) -> Decimal:
    return (Decimal(centavos) / Decimal(rate)).quantize(THREE, rounding=ROUND_HALF_UP)


@dataclass
class Ledger:
    commitment: Commitment
    repaid_centavos: int

    @property
    def remaining_centavos(self) -> int:
        # Never negative, even if a batch overshoots the loan.
        return max(0, self.commitment.amount_centavos - self.repaid_centavos)

    @property
    def progress(self) -> float:
        if self.commitment.amount_centavos == 0:
            return 0.0
        return min(1.0, max(0.0, self.repaid_centavos / self.commitment.amount_centavos))

    @property
    def status(self) -> str:
        if self.commitment.date_received is None:
            return CommitmentStatus.LOAN_PENDING
        if self.remaining_centavos <= 0:
            return CommitmentStatus.LOAN_PAID
        return CommitmentStatus.LOAN_RECEIVED

    def as_dict(self) -> dict:
        rate = self.commitment.rate_per_gram_centavos
        return {
            "status": self.status,
            "status_label": CommitmentStatus(self.status).label,
            "repaid_centavos": self.repaid_centavos,
            "remaining_centavos": self.remaining_centavos,
            "progress": round(self.progress, 4),
            "total_grams_owed": f"{_grams(self.commitment.amount_centavos, rate):.3f}",
            "repaid_grams": f"{_grams(self.repaid_centavos, rate):.3f}",
            "remaining_grams": f"{_grams(self.remaining_centavos, rate):.3f}",
            "applied_disposal_ids": list(
                self.commitment.disposals.order_by("date").values_list("id", flat=True)
            ),
        }


def ledger(commitment: Commitment) -> Ledger:
    """The one place the commitment formula lives: repaid is the sum of the
    gross amounts of every disposal batch applied to it."""
    repaid = commitment.disposals.aggregate(total=Sum("gross_amount_centavos"))["total"] or 0
    return Ledger(commitment=commitment, repaid_centavos=repaid)


def get_commitment(commitment_id: str) -> Commitment:
    try:
        return Commitment.objects.get(pk=commitment_id)
    except Commitment.DoesNotExist:
        raise NotFound("Commitment not found") from None


def require_loan_power(ctx: Ctx, branch_id: str | None) -> None:
    """Admin manages every loan; a Supervisor only their own branch's. A
    company-wide loan (no branch) stays the Admin's."""
    require_role(ctx, BRANCH_MANAGERS, "manage commitments")
    if ctx.is_supervisor:
        if branch_id is None:
            raise Forbidden("A company-wide loan is the Admin's — only an Admin can manage it", code="company_loan")
        require_branch(ctx, branch_id)


def add(ctx: Ctx, *, lender: str, amount_centavos: int, rate_per_gram_centavos: int, branch_id: str | None,
        date_approved=None, commitment_id: str | None = None) -> Commitment:
    """A new loan always starts loanPending — there is no status to set."""
    require_loan_power(ctx, branch_id or None)
    lender = (lender or "").strip()
    if not lender:
        raise Refusal("A commitment needs the lender's name", code="lender_required")
    if amount_centavos is None or amount_centavos <= 0:
        raise Refusal("The loan amount must be above zero", code="amount_not_positive")
    if rate_per_gram_centavos is None or rate_per_gram_centavos <= 0:
        raise Refusal("The rate per gram must be above zero", code="rate_not_positive")
    branch = get_branch(branch_id) if branch_id else None
    commitment = Commitment.objects.create(
        id=claim(commitment_id, "commitment"), lender=lender, amount_centavos=amount_centavos,
        rate_per_gram_centavos=rate_per_gram_centavos, branch=branch, date_approved=date_approved or ctx.now,
    )
    write_log(ctx, LogAction.COMMITMENT_ADDED, f"Added a {peso(amount_centavos)} commitment with {lender}",
              branch=commitment.branch_id, record_id=commitment.id, record_kind=LogRecordKind.COMMITMENT,
              amount_centavos=amount_centavos)
    return commitment


def receive(ctx: Ctx, commitment_id: str, proof_photo: ContentFile | None, cash_entry_id: str | None = None):
    """loanPending -> loanReceived: records when the cash arrived and, for a
    branch loan, credits that branch's Purchase Cash. A company-wide loan
    credits no single branch. Returns (commitment, cash entry or None)."""
    commitment = get_commitment(commitment_id)
    require_loan_power(ctx, commitment.branch_id)
    if commitment.date_received is not None:
        raise Refusal("Cash for this loan was already recorded as received", code="already_received")
    if proof_photo is None:
        raise Refusal("A photo of the cash received (or the lender's slip) is required", code="proof_photo_required")
    commitment.date_received = ctx.now
    commitment.received_proof_photo.save(proof_photo.name, proof_photo, save=False)
    commitment.save()
    entry = None
    if commitment.branch_id is not None:
        entry = cash.write_entry(
            ctx, branch_id=commitment.branch_id, type=CashEntryType.CASH_IN, account=CashAccount.PURCHASE,
            amount_centavos=commitment.amount_centavos, note=f"Loan proceeds received — {commitment.lender}",
            source_type=CashEntrySourceType.COMMITMENT, linked_record_id=commitment.id, entry_id=cash_entry_id,
        )
    write_log(ctx, LogAction.COMMITMENT_RECEIVED,
              f"Recorded {peso(commitment.amount_centavos)} received from {commitment.lender}",
              branch=commitment.branch_id, record_id=commitment.id, record_kind=LogRecordKind.COMMITMENT,
              amount_centavos=commitment.amount_centavos)
    notify.commitment_received(ctx, commitment)
    return commitment, entry
