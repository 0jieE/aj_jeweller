"""Writes that belong at a desk: corrections, cash entries and transfers,
commitments, disposal. Each is one call into its service (see common.attempt)."""

from django.contrib import messages
from django.shortcuts import redirect, render
from django.utils import timezone
from rest_framework import serializers

from shop.api.fields import decode_photo
from shop.enums import CashEntryType, ItemType
from shop.models import Branch, CashEntry, Commitment, Item
from shop.services import cash, commitments, disposal, items
from shop.text import peso

from ..forms import (CashCorrectionForm, CashEntryForm, CommitmentForm, DeleteEntryForm, DisposalForm,
                     ItemCorrectionForm, ProofForm, TransferForm)
from .auth import not_found
from .common import attempt, ctx


def _form(request, template, context, error=None):
    """A form page; after a refused or invalid submit, 422 with the reason."""
    status = 422 if request.method == "POST" else 200
    return render(request, template, {**context, "error": error}, status=status)


def _photo(upload):
    """An uploaded photo as the service takes it, or (None, why not)."""
    if not upload:
        return None, None
    try:
        return decode_photo(upload.read()), None
    except serializers.ValidationError as error:
        return None, str(error.detail[0])


def _minute(dt):
    """A time as a datetime-local field shows it, so an untouched field compares equal."""
    return timezone.localtime(dt).replace(second=0, microsecond=0)


# --- cash ----------------------------------------------------------------------

def cash_new(request):
    form = CashEntryForm(request.POST or None, initial={"branch": request.GET.get("branch")})
    error = None
    if request.method == "POST" and form.is_valid():
        d = form.cleaned_data
        entry, error = attempt(lambda: cash.record_entry(
            ctx(request), branch_id=d["branch"], type=d["type"], account=d["account"], amount_centavos=d["amount"],
            note=d["note"], category=d["category"], when=d["date"]))
        if entry is not None:
            messages.success(request, f"Recorded {CashEntryType(entry.type).label.lower()} of {peso(entry.amount_centavos)}.")
            return redirect("office:cash-entry", entry.id)
    return _form(request, "office/form.html", {"title": "Record a cash entry", "form": form,
                                               "back": "office:cash-entries"}, error)


def cash_transfer(request):
    form = TransferForm(request.POST or None)
    error = None
    if request.method == "POST" and form.is_valid():
        d = form.cleaned_data
        pair, error = attempt(lambda: cash.record_transfer(
            ctx(request), from_branch=d["from_branch"], to_branch=d["to_branch"], from_account=d["from_account"],
            to_account=d["to_account"], amount_centavos=d["amount"], note=d["note"], when=d["date"]))
        if pair is not None:
            messages.success(request, f"Moved {peso(pair[0].amount_centavos)}.")
            return redirect("office:cash-entry", pair[0].id)
    return _form(request, "office/form.html", {"title": "Move cash", "form": form,
                                               "back": "office:cash-entries"}, error)


def _editable_entry(request, pk):
    entry = CashEntry.objects.filter(pk=pk).first()
    if entry is None:
        return None, not_found(request)
    lock = cash.lock_reason(entry)
    if lock:
        messages.error(request, lock)
        return None, redirect("office:cash-entry", entry.id)
    return entry, None


def cash_edit(request, pk):
    entry, response = _editable_entry(request, pk)
    if response:
        return response
    group = cash.group_of(entry)
    first = group[0]
    initial = {"type": first.type, "account": first.account, "amount": first.amount_centavos, "note": first.note,
               "category": first.category or "", "date": _minute(first.date)}
    if entry.is_transfer:
        initial["destination_account"] = group[-1].account
    form = CashCorrectionForm(request.POST or None, initial=initial, transfer=entry.is_transfer)
    error = None
    if request.method == "POST" and form.is_valid():
        changes, error = attempt(lambda: cash.update_entry(ctx(request), first.id, **form.service_fields()))
        if error is None:
            messages.success(request, "Corrected." if changes else "Nothing was changed.")
            return redirect("office:cash-entry", first.id)
    return _form(request, "office/form.html", {"title": f"Correct cash entry {first.id}", "form": form,
                                               "back_url": first.id, "back": "office:cash-entry"}, error)


def cash_delete(request, pk):
    entry, response = _editable_entry(request, pk)
    if response:
        return response
    form = DeleteEntryForm(request.POST or None)
    error = None
    if request.method == "POST" and form.is_valid():
        _, error = attempt(lambda: cash.delete_entry(ctx(request), entry.id, form.cleaned_data["reason"]))
        if error is None:
            messages.success(request, f"Deleted cash entry {entry.id}. The log keeps what it was.")
            return redirect("office:cash-entries")
    return _form(request, "office/cash_delete.html", {"title": f"Delete cash entry {entry.id}", "form": form,
                                                      "group": cash.group_of(entry), "entry": entry}, error)


# --- item corrections ----------------------------------------------------------

def item_correct(request, pk):
    piece = Item.objects.filter(pk=pk).first()
    if piece is None:
        return not_found(request)
    figures = items.snapshot_figures(piece)
    initial = {"description": figures["description"], "type": figures["type"], "karat": figures["karat"],
               "weight_grams": figures["weight"], "gross_weight_grams": figures["gross"], "amount": figures["amount"]}
    form = ItemCorrectionForm(request.POST or None, initial=initial)
    error = None
    if request.method == "POST" and form.is_valid():
        result, error = attempt(lambda: items.correct(ctx(request), piece.id, **form.service_fields()))
        if error is None:
            _, changes, cash_note = result
            messages.success(request, ("Corrected. Corrections never move cash." if changes else "Nothing was changed.")
                             + (f" {cash_note}" if cash_note else ""))
            return redirect("office:item", piece.id)
    return _form(request, "office/form.html", {
        "title": f"Correct {piece.description}", "form": form, "back": "office:item", "back_url": piece.id,
        "note": "A correction changes the record, never the cash ledger. Sold, disposed and reserved pieces "
                "are corrected on the sale or batch instead.",
    }, error)


# --- commitments ---------------------------------------------------------------

def commitment_new(request):
    form = CommitmentForm(request.POST or None)
    error = None
    if request.method == "POST" and form.is_valid():
        d = form.cleaned_data
        loan, error = attempt(lambda: commitments.add(
            ctx(request), lender=d["lender"], amount_centavos=d["amount"], rate_per_gram_centavos=d["rate"],
            branch_id=d["branch"] or None, date_approved=d["date_approved"]))
        if loan is not None:
            messages.success(request, f"Added a {peso(loan.amount_centavos)} commitment with {loan.lender}.")
            return redirect("office:commitment", loan.id)
    return _form(request, "office/form.html", {"title": "Add a commitment", "form": form,
                                               "back": "office:commitments"}, error)


def commitment_receive(request, pk):
    loan = Commitment.objects.filter(pk=pk).first()
    if loan is None:
        return not_found(request)
    form = ProofForm(request.POST or None, request.FILES or None)
    error = None
    if request.method == "POST" and form.is_valid():
        photo, error = _photo(form.cleaned_data["photo"])
        if error is None:
            _, error = attempt(lambda: commitments.receive(ctx(request), loan.id, photo))
        if error is None:
            messages.success(request, f"Recorded {peso(loan.amount_centavos)} received from {loan.lender}.")
            return redirect("office:commitment", loan.id)
    return _form(request, "office/form.html", {
        "title": f"Cash received for {loan.lender}", "form": form, "multipart": True,
        "back": "office:commitment", "back_url": loan.id,
        "note": ("A branch loan credits that branch's Purchase Cash." if loan.branch_id
                 else "A company-wide loan credits no single branch."),
    }, error)


# --- disposal ------------------------------------------------------------------

def disposal_new(request):
    """Pick the branch and metal (the page's query string), then the pieces."""
    branch_id = request.GET.get("branch") or ""
    silver = request.GET.get("metal") == "silver"
    branch = Branch.objects.filter(pk=branch_id).first()
    pool = disposal.pool(branch.id, silver=silver) if branch else []
    loans = []
    if branch:
        for loan in Commitment.objects.filter(date_received__isnull=False).order_by("date_approved"):
            ledger = commitments.ledger(loan)
            if ledger.remaining_centavos > 0 and loan.branch_id in (None, branch.id):
                loans.append(loan)
    form = DisposalForm(request.POST or None, request.FILES or None, pool=pool, commitments=loans)
    error = None
    if request.method == "POST" and form.is_valid():
        d = form.cleaned_data
        photo, error = _photo(d["photo"])
        if error is None:
            batch, error = attempt(lambda: disposal.complete(
                ctx(request), branch_id=branch.id if branch else None, item_ids=d["items"],
                gross_grams=d["gross_grams"], gross_amount_centavos=d["gross_amount"],
                commitment_id=d["commitment"], photo=photo))
            if error is None:
                messages.success(request, f"Disposed {len(d['items'])} piece(s).")
                return redirect("office:disposal", batch.id)
    return _form(request, "office/disposal_new.html", {
        "title": "Run a disposal", "form": form, "branch": branch, "silver": silver, "pool": pool,
        "branches": Branch.objects.order_by("id"), "metal": "silver" if silver else "gold",
        "loans": [commitments.ledger(loan) for loan in loans], "silver_type": ItemType.SILVER,
    }, error)
