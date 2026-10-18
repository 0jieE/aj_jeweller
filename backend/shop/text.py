"""Plain-text formatting in the app's exact words and number styles.

Log summaries, refusal messages and receipts are read by the same people who
read the app, so they are written the way the app writes them:
money_text.dart (`pesoText`), formatters.dart (`AppFormat`) and the
repository's `_purityText` / `_karatText` helpers.
"""

from datetime import datetime
from decimal import Decimal

from django.utils import timezone

from .enums import is_silver_purity


def peso(centavos: int) -> str:
    """Always two decimals and grouped: 103790300 -> '₱1,037,903.00'."""
    sign = "-" if centavos < 0 else ""
    whole, cents = divmod(abs(int(centavos)), 100)
    return f"{sign}₱{whole:,}.{cents:02d}"


def peso_plain(centavos: int) -> str:
    """Pesos for a spreadsheet cell: no symbol, no grouping, two decimals."""
    sign = "-" if centavos < 0 else ""
    whole, cents = divmod(abs(int(centavos)), 100)
    return f"{sign}{whole}.{cents:02d}"


def fixed3(grams: Decimal | float | int) -> str:
    """Dart's toStringAsFixed(3): '20.000' — no grouping."""
    return f"{Decimal(grams):.3f}"


def grams(value: Decimal | float | int) -> str:
    """AppFormat.grams: '1,234.500g'."""
    return f"{Decimal(value):,.3f}g"


def karat_text(karat: int) -> str:
    """'18K' for gold; silver fineness stays bare: '925'."""
    return f"{karat}" if is_silver_purity(karat) else f"{karat}K"


def purity_text(karat: int) -> str:
    """'18K' for gold, '925 silver' for silver — the repository's _purityText."""
    return f"{karat} silver" if is_silver_purity(karat) else f"{karat}K"


def _local(dt: datetime) -> datetime:
    return timezone.localtime(dt) if timezone.is_aware(dt) else dt


def date_time_short(dt: datetime) -> str:
    """AppFormat.dateTimeShort: 'Oct 18, 2026 · 9:05 AM'."""
    d = _local(dt)
    hour = d.hour % 12 or 12
    return f"{d:%b} {d.day}, {d.year} · {hour}:{d.minute:02d} {'AM' if d.hour < 12 else 'PM'}"


def date_short(dt) -> str:
    """AppFormat.dateShort: 'Oct 18, 2026'."""
    d = _local(dt) if isinstance(dt, datetime) else dt
    return f"{d:%b} {d.day}, {d.year}"
