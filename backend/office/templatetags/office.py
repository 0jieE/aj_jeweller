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


# Line icons, 24x24, drawn with the text colour (stroke="currentColor").
_ICONS = {
    "today": '<path d="m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M9 22V12h6v10"/>',
    "purchases": '<path d="M6 2 3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4Z"/><path d="M3 6h18"/>'
                 '<path d="M16 10a4 4 0 0 1-8 0"/>',
    "sales": '<path d="M12.6 2.6A2 2 0 0 0 11.2 2H4a2 2 0 0 0-2 2v7.2a2 2 0 0 0 .6 1.4l8.7 8.7a2.4 2.4 0 0 0 3.4 0'
             'l6.6-6.6a2.4 2.4 0 0 0 0-3.4z"/><circle cx="7.5" cy="7.5" r="1"/>',
    "items": '<path d="M6 3h12l4 6-10 13L2 9Z"/><path d="M11 3 8 9l4 13 4-13-3-6"/><path d="M2 9h20"/>',
    "cash": '<rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/>'
            '<path d="M6 12h.01M18 12h.01"/>',
    "customers": '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/>'
                 '<path d="M22 21v-2a4 4 0 0 0-3-3.9"/><path d="M16 3.1a4 4 0 0 1 0 7.8"/>',
    "loans": '<path d="M3 22h18"/><path d="M6 18v-7M10 18v-7M14 18v-7M18 18v-7"/><path d="M12 2 20 7H4z"/>',
    "disposal": '<path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.4-.5-2-1-3-1.1-2.1-.2-4.1 2-6 .5 2.5 2 4.9 4 6.5'
                ' 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.2.4-2.3 1-3a2.5 2.5 0 0 0 2.5 2.5z"/>',
    "reports": '<path d="M3 3v18h18"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
    "log": '<path d="M8 6h13M8 12h13M8 18h13"/><path d="M3 6h.01M3 12h.01M3 18h.01"/>',
    "staff": '<rect x="2" y="4" width="20" height="16" rx="2"/><circle cx="9" cy="11" r="2"/>'
             '<path d="M15 9h3M15 13h3"/><path d="M6 16c.6-1.2 1.7-2 3-2s2.4.8 3 2"/>',
    "rates": '<path d="m22 7-8.5 8.5-5-5L2 17"/><path d="M16 7h6v6"/>',
    "sign-out": '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>',
    "sidebar": '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 3v18"/>',
    "first": '<path d="m11 17-5-5 5-5"/><path d="m18 17-5-5 5-5"/>',
    "previous": '<path d="m15 18-6-6 6-6"/>',
    "next": '<path d="m9 18 6-6-6-6"/>',
    "last": '<path d="m6 17 5-5-5-5"/><path d="m13 17 5-5-5-5"/>',
}


@register.simple_tag
def icon(name):
    return mark_safe(
        '<svg class="icon" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" '
        f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{_ICONS[name]}</svg>')


@register.simple_tag(takes_context=True)
def nav_link(context, name, text, glyph):
    """A sidebar link: its icon and label, marked current on its page and the
    pages under it. In the mini sidebar only the icon shows; `data-tip` names it."""
    url = reverse(name)
    path = context["request"].path
    home = reverse("office:today")
    current = path == url if url == home else path.startswith(url)
    return format_html('<a href="{}" data-tip="{}"{}>{}<span class="nav-label">{}</span></a>', url, text,
                       mark_safe(' class="is-current" aria-current="page"') if current else "", icon(glyph), text)


@register.filter
def initials(name):
    """'Sam Superuser' -> 'SS', for the mini sidebar's avatar."""
    parts = [p for p in (name or "").split() if p]
    return ("".join(p[0] for p in parts[:2]) or "?").upper()


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
