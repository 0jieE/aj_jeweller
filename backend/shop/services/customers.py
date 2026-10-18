"""The customer book.

The same person sells scrap in March and buys a ring in December, so they are
one record that both sides of the counter reach. Matching ignores case and
spacing. A transaction that omits a detail never blanks the one on file — a
rushed entry with no address must not erase the address captured last month —
but a detail it does supply updates the record.
"""

from dataclasses import dataclass

from django.core.files.base import ContentFile

from accounts.models import name_key

from ..enums import LogAction, LogRecordKind
from ..errors import NotFound, Refusal
from ..ids import claim
from ..models import Customer
from .base import Ctx, blank_to_none, change, write_log


@dataclass
class CustomerDetails:
    """The customer as given on a transaction."""

    name: str
    contact_number: str | None = None
    address: str | None = None
    customer_id: str | None = None
    photo: ContentFile | None = None

    @classmethod
    def from_input(cls, data: dict) -> "CustomerDetails":
        return cls(
            name=(data.get("name") or "").strip(),
            contact_number=data.get("contact_number"),
            address=data.get("address"),
            customer_id=data.get("id") or None,
            photo=data.get("photo"),
        )


def get_customer(customer_id: str) -> Customer:
    try:
        return Customer.objects.get(pk=customer_id)
    except Customer.DoesNotExist:
        raise NotFound("Customer not found") from None


def by_name(name: str) -> Customer | None:
    key = name_key(name or "")
    if not key:
        return None
    return Customer.objects.filter(name_key=key).order_by("first_seen").first()


def file_on_transaction(ctx: Ctx, details: CustomerDetails) -> Customer:
    """Files the counterparty of a purchase or sale, reusing the record when
    the id — or failing that, the name — matches one.

    Part of the purchase or sale it belongs to, so it writes no log row of its
    own; that transaction's row covers it.
    """
    if not details.name:
        raise Refusal("A transaction needs the customer's name", code="customer_name_required")
    existing = None
    if details.customer_id:
        existing = Customer.objects.filter(pk=details.customer_id).first()
    if existing is None and not details.customer_id:
        existing = by_name(details.name)

    if existing is None:
        # A phone working offline may already have given the person an id.
        customer = Customer(
            id=claim(details.customer_id, "customer"),
            name=details.name,
            contact_number=blank_to_none(details.contact_number),
            address=blank_to_none(details.address),
            first_seen=ctx.now,
        )
        if details.photo is not None:
            customer.photo.save(details.photo.name, details.photo, save=False)
        customer.save()
        return customer

    existing.name = details.name or existing.name
    existing.contact_number = blank_to_none(details.contact_number) or existing.contact_number
    existing.address = blank_to_none(details.address) or existing.address
    if details.photo is not None:
        # A newly taken photo replaces the old one; no photo leaves it alone.
        existing.photo.save(details.photo.name, details.photo, save=False)
    existing.save()
    return existing


def create_customer(ctx: Ctx, *, name: str, contact_number=None, address=None, customer_id=None,
                    photo=None) -> Customer:
    name = (name or "").strip()
    if not name:
        raise Refusal("A customer needs a name", code="customer_name_required")
    clash = by_name(name)
    if clash is not None:
        raise Refusal(f"{clash.name} is already in the customer book", code="customer_exists", customer_id=clash.id)
    customer = Customer(
        id=claim(customer_id, "customer"),
        name=name,
        contact_number=blank_to_none(contact_number),
        address=blank_to_none(address),
        first_seen=ctx.now,
    )
    if photo is not None:
        customer.photo.save(photo.name, photo, save=False)
    customer.save()
    write_log(ctx, LogAction.CUSTOMER_ADDED, f"Added {customer.name} to the customer book",
              record_id=customer.id, record_kind=LogRecordKind.CUSTOMER)
    return customer


_UNSET = object()


def update_customer(ctx: Ctx, customer_id: str, *, name=_UNSET, contact_number=_UNSET,
                    address=_UNSET) -> list[dict]:
    """A deliberate edit from the customer book — unlike a transaction, this
    may clear a detail (send null or "")."""
    customer = get_customer(customer_id)
    changes = []
    if name is not _UNSET:
        new_name = (name or "").strip()
        if not new_name:
            raise Refusal("A customer needs a name", code="customer_name_required")
        clash = by_name(new_name)
        if clash is not None and clash.id != customer.id:
            raise Refusal(f"{clash.name} is already in the customer book", code="customer_exists",
                          customer_id=clash.id)
        if new_name != customer.name:
            changes.append(change("Name", customer.name, new_name))
            customer.name = new_name
    for field, label, value in (("contact_number", "Contact", contact_number), ("address", "Address", address)):
        if value is _UNSET:
            continue
        new = blank_to_none(value)
        old = getattr(customer, field)
        if new != old:
            changes.append(change(label, old or "—", new or "—"))
            setattr(customer, field, new)
    if not changes:
        return changes
    customer.save()
    write_log(ctx, LogAction.CUSTOMER_UPDATED,
              f"Edited {customer.name} — {', '.join(c['field'].lower() for c in changes)}",
              record_id=customer.id, record_kind=LogRecordKind.CUSTOMER, changes=changes)
    return changes


def set_photo(ctx: Ctx, customer_id: str, photo: ContentFile) -> Customer:
    """Files or replaces a customer's photo from their record."""
    customer = get_customer(customer_id)
    had = bool(customer.photo)
    customer.photo.save(photo.name, photo, save=False)
    customer.save()
    write_log(ctx, LogAction.CUSTOMER_PHOTO_UPDATED,
              f"{'Replaced' if had else 'Added'} the photo of {customer.name}",
              record_id=customer.id, record_kind=LogRecordKind.CUSTOMER)
    return customer
