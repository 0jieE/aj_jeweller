"""How the office writes figures: the app's own formats (shop/text.py)."""

from django import template
from django.urls import reverse

from shop import enums, text

register = template.Library()


@register.filter
def peso(centavos):
    return "—" if centavos is None or centavos == "" else text.peso(centavos)


@register.filter
def grams(value):
    return "—" if value is None or value == "" else text.grams(value)


@register.filter
def when(dt):
    return "—" if not dt else text.date_time_short(dt)


@register.filter
def purity(karat):
    return "—" if karat is None else text.purity_text(karat)


@register.filter
def label(value, enum_name):
    """{{ entry.role|label:"Role" }} -> 'Cashier'."""
    if value in (None, ""):
        return "—"
    try:
        return getattr(enums, enum_name)(value).label
    except ValueError:
        return value


@register.filter
def flow(entry):
    """The colour of a cash entry: green coming in, red going out."""
    return "money--in" if entry.type in enums.CREDIT_TYPES else "money--out"


# Where a record id in the log leads.
_RECORD_PAGES = {
    enums.LogRecordKind.PURCHASE_BATCH: "office:purchase",
    enums.LogRecordKind.ITEM: "office:item",
    enums.LogRecordKind.SALE: "office:sale",
    enums.LogRecordKind.DISPOSAL: "office:disposal",
    enums.LogRecordKind.COMMITMENT: "office:commitment",
    enums.LogRecordKind.CASH_ENTRY: "office:cash-entry",
    enums.LogRecordKind.CUSTOMER: "office:customer",
    enums.LogRecordKind.USER: "office:staff-member",
}


@register.simple_tag
def record_url(kind, record_id):
    name = _RECORD_PAGES.get(kind)
    if not name or not record_id:
        return ""
    return reverse(name, args=[record_id])
