"""Who is told what. Called by the shop's services, inside their transaction.

A notification only ever reaches someone allowed to act on it, scoped to the
record's branch (Admin oversees both), and never the person who caused it.

| Event                              | Who                         | kind       |
| ---------------------------------- | --------------------------- | ---------- |
| purchase submitted for release     | the branch's Cashiers and   | purchase   |
|                                    | Supervisor                  |            |
| purchase returned for correction   | the Appraiser who encoded it| purchase   |
| order submitted for payment        | the branch's Cashiers and   | sale       |
|                                    | Supervisor                  |            |
| order returned to the rep          | the Sales Rep who sold it   | sale       |
| commitment cash received           | Admins, Superusers, and the | commitment |
|                                    | loan's branch Supervisor    |            |
| commitment fully paid              | (same)                      | commitment |

A branch's Supervisor can release cash and receive payment there too, so they
are told about that branch's cash queue alongside its Cashiers.

"Submitted" includes a resubmission after a return: the record is back in the
Cashier's queue. A branch with no active Cashier or Supervisor has that work done by an
Admin (as in the app's StaffDirectory.forRole), so its Admins are told.

A replayed write (same Idempotency-Key, e.g. a /sync/push resend) returns its
stored first response without running the service at all, so it can never
notify twice.
"""

from accounts.models import User
from shop.enums import BOTH_BRANCH_ROLES, Role
from shop.text import peso

from .outbox import enqueue

PURCHASE, SALE, COMMITMENT, ITEM = "purchase", "sale", "commitment", "item"


def _admins():
    """Everyone who oversees both branches."""
    return User.objects.filter(active=True, role__in=BOTH_BRANCH_ROLES)


def _supervisors(branch_id: str | None):
    if branch_id is None:
        return User.objects.none()  # a company-wide loan is the Admin's
    return User.objects.filter(active=True, role=Role.SUPERVISOR, home_branch=branch_id)


def _cash_queue(branch_id: str):
    """Who can release cash or take payment at this branch: its Cashiers and
    its Supervisor. With neither active, the Admins do that work."""
    people = list(User.objects.filter(active=True, home_branch=branch_id, role__in=[Role.CASHIER, Role.SUPERVISOR]))
    return people or list(_admins())


def _loan_people(branch_id: str | None):
    return list(_admins()) + list(_supervisors(branch_id))


def purchase_awaiting_release(ctx, batch, *, item_count: int, total_centavos: int) -> None:
    enqueue(_cash_queue(batch.branch_id), kind=PURCHASE, record_id=batch.id, branch=batch.branch_id,
            title="Cash to release",
            body=f"{batch.customer_name} · {item_count} item(s) · {peso(total_centavos)}",
            exclude_user_id=ctx.actor.pk)


def purchase_returned(ctx, batch, note: str) -> None:
    enqueue([batch.submitted_by], kind=PURCHASE, record_id=batch.id, branch=batch.branch_id,
            title="Purchase returned", body=f"{batch.customer_name} · {note}", exclude_user_id=ctx.actor.pk)


def sale_awaiting_payment(ctx, sale) -> None:
    enqueue(_cash_queue(sale.branch_id), kind=SALE, record_id=sale.id, branch=sale.branch_id,
            title="Payment to receive", body=f"{sale.customer_name} · {peso(sale.total_centavos)}",
            exclude_user_id=ctx.actor.pk)


def sale_returned(ctx, sale, note: str) -> None:
    enqueue([sale.submitted_by], kind=SALE, record_id=sale.id, branch=sale.branch_id,
            title="Order returned", body=f"{sale.customer_name} · {note}", exclude_user_id=ctx.actor.pk)


def commitment_received(ctx, commitment) -> None:
    enqueue(_loan_people(commitment.branch_id), kind=COMMITMENT, record_id=commitment.id,
            branch=commitment.branch_id, title="Loan received",
            body=f"{commitment.lender} · {peso(commitment.amount_centavos)}", exclude_user_id=ctx.actor.pk)


def commitment_cleared(ctx, commitment) -> None:
    enqueue(_loan_people(commitment.branch_id), kind=COMMITMENT, record_id=commitment.id,
            branch=commitment.branch_id, title="Loan cleared", body=commitment.lender, exclude_user_id=ctx.actor.pk)
