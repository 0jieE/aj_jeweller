"""Buying rates per purity (gold karat or silver fineness) and their history.

One rate per purity: a second "18K" would leave the purchase form two setup
prices for the same gold.

Every role may set a rate — Cashier, Appraiser and Sales Rep included. The
counter quotes from them all day, and a rate nobody present can correct is
worse than one anybody can. Rates are shop-wide, so a change applies to both
branches; every change is logged under the name of whoever made it. Every price set is kept in RateChange, which is
never edited or deleted — it is the price history the counter asks about
("what was 18K a week ago?").
"""

from datetime import date, datetime, time, timedelta

from django.utils import timezone

from ..enums import LogAction, is_silver_purity
from ..errors import NotFound, Refusal
from ..models import GoldRate, RateChange
from ..text import date_short, peso, purity_text
from .base import Ctx, change, write_log


def _close_of(day: date) -> datetime:
    """The first instant after `day` ends, in Manila."""
    return timezone.make_aware(datetime.combine(day + timedelta(days=1), time.min))


def get_rate(karat: int) -> GoldRate:
    try:
        return GoldRate.objects.get(pk=karat)
    except GoldRate.DoesNotExist:
        raise NotFound(f"{purity_text(karat)} has no rate") from None


def add_problem(karat: int, silver: bool) -> str | None:
    if silver:
        if not 100 <= karat <= 999:
            return "Silver fineness is 100 to 999 (e.g. 925)"
    elif not 1 <= karat <= 24:
        return "Gold karat is 1 to 24"
    if GoldRate.objects.filter(pk=karat).exists():
        return f"{purity_text(karat)} already has a rate — edit its price instead"
    return None


def add_rate(ctx: Ctx, karat: int, price_per_gram_centavos: int, silver: bool | None = None) -> GoldRate:
    silver = is_silver_purity(karat) if silver is None else silver
    problem = add_problem(karat, silver)
    if problem:
        raise Refusal(problem, code="rate_exists" if "already" in problem else "purity_out_of_range")
    if price_per_gram_centavos <= 0:
        raise Refusal("A rate must be above zero", code="rate_not_positive")
    rate = GoldRate.objects.create(karat=karat, price_per_gram_centavos=price_per_gram_centavos, updated_at=ctx.now)
    RateChange.objects.create(karat=karat, before_centavos=None, after_centavos=price_per_gram_centavos, at=ctx.now,
                              user=ctx.actor, user_name=ctx.actor.name)
    name = purity_text(karat)
    write_log(ctx, LogAction.GOLD_RATE_ADDED, f"Added a {name} rate at {peso(price_per_gram_centavos)} per gram",
              changes=[change(f"{name} per gram", "—", peso(price_per_gram_centavos))])
    return rate


def _set_price(ctx: Ctx, rate: GoldRate, price: int, restored_from: date | None) -> dict:
    before = rate.price_per_gram_centavos
    RateChange.objects.create(karat=rate.karat, before_centavos=before, after_centavos=price, at=ctx.now,
                              user=ctx.actor, user_name=ctx.actor.name, restored_from=restored_from)
    rate.price_per_gram_centavos = price
    rate.updated_at = ctx.now
    rate.save()
    return change(f"{purity_text(rate.karat)} per gram", peso(before), peso(price))


def update_rate(ctx: Ctx, karat: int, price_per_gram_centavos: int) -> tuple[GoldRate, bool]:
    """Sets one purity's price. Saving the same figure again is not a change and
    adds nothing to the history. Returns (rate, changed)."""
    rate = get_rate(karat)
    if price_per_gram_centavos <= 0:
        raise Refusal("A rate must be above zero", code="rate_not_positive")
    before = rate.price_per_gram_centavos
    if before == price_per_gram_centavos:
        return rate, False
    entry = _set_price(ctx, rate, price_per_gram_centavos, None)
    write_log(ctx, LogAction.GOLD_RATE_UPDATED,
              f"{purity_text(karat)} rate changed from {peso(before)} to {peso(price_per_gram_centavos)} per gram",
              changes=[entry])
    return rate, True


def rate_on(karat: int, day: date) -> int | None:
    """The price in force for `karat` at the close of `day` — the last change
    made on or before it — or None if it hadn't been set yet."""
    change_row = (RateChange.objects.filter(karat=karat, at__lt=_close_of(day)).order_by("-at", "-id").first())
    return change_row.after_centavos if change_row else None


def rates_on(day: date) -> list[dict]:
    """Every purity's price at the close of `day`."""
    out = []
    for rate in GoldRate.objects.order_by("-karat"):
        out.append({"karat": rate.karat, "silver": is_silver_purity(rate.karat),
                    "price_per_gram_centavos": rate_on(rate.karat, day)})
    return out


def apply_from(ctx: Ctx, day: date, *, silver: bool) -> int:
    """Makes every gold (or every silver) rate what it was at the close of
    `day`, in one go — that day's table is one set of quotes. Rates not yet set
    on that day, or already at that price, are left alone. One history row per
    changed rate; one log row for the whole table. Returns how many changed."""
    changes = []
    for rate in GoldRate.objects.order_by("-karat"):
        if is_silver_purity(rate.karat) != silver:
            continue
        price = rate_on(rate.karat, day)
        if price is None or price == rate.price_per_gram_centavos:
            continue
        changes.append(_set_price(ctx, rate, price, day))
    if changes:
        metal = "silver" if silver else "gold"
        write_log(ctx, LogAction.GOLD_RATE_UPDATED,
                  f"Set {len(changes)} {metal} rate(s) back to the prices of {date_short(day)}", changes=changes)
    return len(changes)
