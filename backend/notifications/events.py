"""Who is told what. Called by the shop's services, inside their transaction.

A notification only ever reaches someone allowed to act on it, scoped to the
record's branch (Admin oversees both), and never the person who caused it.

| Event                              | Who                         | kind       |
| ---------------------------------- | --------------------------- | ---------- |
| purchase submitted for release     | that branch's Cashiers      | purchase   |
| purchase returned for correction   | the Appraiser who encoded it| purchase   |
| order submitted for payment        | that branch's Cashiers      | sale       |
| order returned to the rep          | the Sales Rep who sold it   | sale       |
| commitment cash received           | Admins                      | commitment |
| commitment fully paid              | Admins                      | commitment |

"Submitted" includes a resubmission after a return: the record is back in the
Cashier's queue. A branch with no active Cashier has its Cashier work done by
an Admin (as in the app's StaffDirectory.forRole), so its Admins are told.

A replayed write (same Idempotency-Key, e.g. a /sync/push resend) returns its
stored first response without running the service at all, so it can never
notify twice.
"""

from accounts.models import User
from shop.enums import Role
from shop.text import peso

from .outbox import enqueue

PURCHASE, SALE, COMMITMENT, ITEM = "purchase", "sale", "commitment", "item"


def _admins():
    return User.objects.filter(active=True, role=Role.ADMIN)


def _cashiers(branch_id: str):
    cashiers = User.objects.filter(active=True, role=Role.CASHIER, home_branch=branch_id)
    return cashiers if cashiers.exists() else _admins()


def purchase_awaiting_release(ctx, batch, *, item_count: int, total_centavos: int) -> None:
    enqueue(_cashiers(batch.branch_id), kind=PURCHASE, record_id=batch.id, branch=batch.branch_id,
            title="Cash to release",
            body=f"{batch.customer_name} · {item_count} item(s) · {peso(total_centavos)}",
            exclude_user_id=ctx.actor.pk)


def purchase_returned(ctx, batch, note: str) -> None:
    enqueue([batch.submitted_by], kind=PURCHASE, record_id=batch.id, branch=batch.branch_id,
            title="Purchase returned", body=f"{batch.customer_name} · {note}", exclude_user_id=ctx.actor.pk)


def sale_awaiting_payment(ctx, sale) -> None:
    enqueue(_cashiers(sale.branch_id), kind=SALE, record_id=sale.id, branch=sale.branch_id,
            title="Payment to receive", body=f"{sale.customer_name} · {peso(sale.total_centavos)}",
            exclude_user_id=ctx.actor.pk)


def sale_returned(ctx, sale, note: str) -> None:
    enqueue([sale.submitted_by], kind=SALE, record_id=sale.id, branch=sale.branch_id,
            title="Order returned", body=f"{sale.customer_name} · {note}", exclude_user_id=ctx.actor.pk)


def commitment_received(ctx, commitment) -> None:
    enqueue(_admins(), kind=COMMITMENT, record_id=commitment.id, branch=commitment.branch_id,
            title="Loan received", body=f"{commitment.lender} · {peso(commitment.amount_centavos)}",
            exclude_user_id=ctx.actor.pk)


def commitment_cleared(ctx, commitment) -> None:
    enqueue(_admins(), kind=COMMITMENT, record_id=commitment.id, branch=commitment.branch_id,
            title="Loan cleared", body=commitment.lender, exclude_user_id=ctx.actor.pk)
