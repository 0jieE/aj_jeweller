"""Rates: today's gold and silver prices, changed through shop/services/rates.py,
and the history every change leaves."""

from django.contrib import messages
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST

from shop.enums import is_silver_purity
from shop.models import GoldRate, RateChange
from shop.services import rates as rate_service
from shop.text import date_short, purity_text

from ..forms import ApplyRatesForm, NewRateForm, RateForm
from .common import attempt, ctx, paged


def rates(request, *, new=None, apply=None, error=None, status=200):
    current = list(GoldRate.objects.order_by("-karat"))
    for rate in current:
        rate.form = RateForm(initial={"price": rate.price_per_gram_centavos}, auto_id=f"rate{rate.karat}_%s")
    karat = request.GET.get("karat") or ""
    changes = RateChange.objects.all()
    if karat.isdigit():
        changes = changes.filter(karat=int(karat))
    return render(request, "office/rates.html", {
        "title": "Rates",
        "gold": [r for r in current if not is_silver_purity(r.karat)],
        "silver": [r for r in current if is_silver_purity(r.karat)],
        "new": new or NewRateForm(), "apply": apply or ApplyRatesForm(),
        "page": paged(request, changes), "karat": karat, "purities": [(r.karat, purity_text(r.karat)) for r in current],
        "error": error,
    }, status=status)


@require_POST
def rate_update(request, karat):
    form = RateForm(request.POST)
    if not form.is_valid():
        return rates(request, error=form.errors["price"][0], status=422)
    result, error = attempt(lambda: rate_service.update_rate(ctx(request), karat, form.cleaned_data["price"]))
    if error:
        return rates(request, error=error, status=422)
    _, changed = result
    messages.success(request, f"{purity_text(karat)} is updated." if changed else f"{purity_text(karat)} was already that price.")
    return redirect("office:rates")


@require_POST
def rate_add(request):
    form = NewRateForm(request.POST)
    if not form.is_valid():
        return rates(request, new=form, status=422)
    karat = form.cleaned_data["karat"]
    _, error = attempt(lambda: rate_service.add_rate(ctx(request), karat, form.cleaned_data["price"]))
    if error:
        return rates(request, new=form, error=error, status=422)
    messages.success(request, f"Added a {purity_text(karat)} rate.")
    return redirect("office:rates")


@require_POST
def rates_apply(request):
    form = ApplyRatesForm(request.POST)
    if not form.is_valid():
        return rates(request, apply=form, status=422)
    day, metal = form.cleaned_data["day"], form.cleaned_data["metal"]
    count, error = attempt(lambda: rate_service.apply_from(ctx(request), day, silver=metal == "silver"))
    if error:
        return rates(request, apply=form, error=error, status=422)
    messages.success(request, f"Set {count} {metal} rate(s) back to the prices of {date_short(day)}."
                     if count else f"Every {metal} rate already matched {date_short(day)}.")
    return redirect("office:rates")
