"""How the office writes figures: the app's own formats (shop/text.py)."""

from django import template
from django.urls import reverse
from django.utils.html import format_html
from django.utils.safestring import mark_safe

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


@register.simple_tag(takes_context=True)
def nav_link(context, name, text):
    """A sidebar link, marked current on its page and the pages under it."""
    url = reverse(name)
    path = context["request"].path
    home = reverse("office:today")
    current = path == url if url == home else path.startswith(url)
    return format_html('<a href="{}"{}>{}</a>', url,
                       mark_safe(' class="is-current" aria-current="page"') if current else "", text)


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
