"""The office's forms. They only read what was typed into the shapes the
services take — pesos into centavos, a date into a Manila time. Every rule
(amount above zero, a note on every entry, who may do what) is the
service's, and so is the sentence that says no."""

from decimal import Decimal, InvalidOperation

from django import forms

from accounts.services import check_pin
from shop.enums import MANUAL_TYPES, BranchId, CashAccount, CashEntryType, ItemType, Role
from shop.errors import ShopError

BRANCHES = list(BranchId.choices)
NO_BRANCH = [("", "Both branches (company-wide)")]
DATE_TIME = forms.DateTimeInput(attrs={"type": "datetime-local"}, format="%Y-%m-%dT%H:%M")
MANUAL_CHOICES = [(t.value, t.label) for t in CashEntryType if t in MANUAL_TYPES]


class PesoField(forms.CharField):
    """Pesos as typed ('1,500' or '₱1,500.50'), cleaned to integer centavos."""

    def __init__(self, **kwargs):
        kwargs.setdefault("widget", forms.TextInput(attrs={"inputmode": "decimal", "class": "money"}))
        super().__init__(**kwargs)

    def prepare_value(self, value):
        if isinstance(value, int):
            whole, cents = divmod(value, 100)
            return f"{whole}.{cents:02d}"
        return value

    def to_python(self, value):
        raw = super().to_python(value)
        if raw in (None, ""):
            return None
        text = raw.replace(",", "").replace("₱", "").replace("PHP", "").strip()
        try:
            pesos = Decimal(text)
        except InvalidOperation:
            raise forms.ValidationError("Type an amount in pesos, like 1500 or 1,500.50") from None
        if not pesos.is_finite() or pesos != pesos.quantize(Decimal("0.01")):
            raise forms.ValidationError("Pesos go to two decimals (centavos)")
        return int(pesos * 100)

    def has_changed(self, initial, data):
        try:
            return self.to_python(data) != initial
        except forms.ValidationError:
            return True


def grams_field(**kwargs):
    return forms.DecimalField(max_digits=10, decimal_places=3, widget=forms.TextInput(
        attrs={"inputmode": "decimal", "class": "grams"}), **kwargs)


def _changed(form, names: dict) -> dict:
    """The fields that were actually changed, under the service's names."""
    return {names.get(f, f): form.cleaned_data[f] for f in form.changed_data}


# --- cash ---------------------------------------------------------------------

class CashEntryForm(forms.Form):
    branch = forms.ChoiceField(choices=BRANCHES)
    type = forms.ChoiceField(choices=MANUAL_CHOICES)
    account = forms.ChoiceField(choices=CashAccount.choices, label="Cash source")
    amount = PesoField(label="Amount (₱)")
    note = forms.CharField(required=False, widget=forms.Textarea(attrs={"rows": 2}))
    category = forms.CharField(required=False, help_text="Expenses only: what the money was spent on.")
    date = forms.DateTimeField(required=False, widget=DATE_TIME, help_text="Leave empty for now.")


class TransferForm(forms.Form):
    from_branch = forms.ChoiceField(choices=BRANCHES, label="From branch")
    from_account = forms.ChoiceField(choices=CashAccount.choices, label="From cash source")
    to_branch = forms.ChoiceField(choices=BRANCHES, label="To branch")
    to_account = forms.ChoiceField(choices=CashAccount.choices, label="To cash source")
    amount = PesoField(label="Amount (₱)")
    note = forms.CharField(required=False, widget=forms.Textarea(attrs={"rows": 2}))
    date = forms.DateTimeField(required=False, widget=DATE_TIME, help_text="Leave empty for now.")


class CashCorrectionForm(forms.Form):
    """A hand-typed entry's figures. Only the fields actually changed go to the
    service, so an untouched date is not logged as a correction."""

    type = forms.ChoiceField(choices=MANUAL_CHOICES)
    account = forms.ChoiceField(choices=CashAccount.choices, label="Cash source")
    destination_account = forms.ChoiceField(choices=CashAccount.choices, label="To cash source")
    amount = PesoField(label="Amount (₱)")
    note = forms.CharField(required=False, widget=forms.Textarea(attrs={"rows": 2}))
    category = forms.CharField(required=False)
    date = forms.DateTimeField(widget=DATE_TIME)

    def __init__(self, *args, transfer: bool, **kwargs):
        super().__init__(*args, **kwargs)
        if transfer:
            del self.fields["type"], self.fields["category"]
            self.fields["account"].label = "From cash source"
        else:
            del self.fields["destination_account"]

    def service_fields(self) -> dict:
        return _changed(self, {"amount": "amount_centavos", "date": "when"})


class DeleteEntryForm(forms.Form):
    reason = forms.CharField(required=False, widget=forms.Textarea(attrs={"rows": 2}),
                             help_text="Kept in the log, with what the entry was.")


# --- items --------------------------------------------------------------------

class ItemCorrectionForm(forms.Form):
    description = forms.CharField(required=False)
    type = forms.ChoiceField(choices=ItemType.choices)
    karat = forms.IntegerField(label="Karat / fineness", min_value=0)
    weight_grams = grams_field(label="Net weight (g)")
    gross_weight_grams = grams_field(label="Gross weight (g)", required=False)
    amount = PesoField(label="Amount (₱)")

    def service_fields(self) -> dict:
        return _changed(self, {"amount": "amount_centavos"})


# --- loans and disposal -------------------------------------------------------

class CommitmentForm(forms.Form):
    lender = forms.CharField(required=False)
    amount = PesoField(label="Loan amount (₱)")
    rate = PesoField(label="Rate per gram (₱)")
    branch = forms.ChoiceField(choices=NO_BRANCH + BRANCHES, required=False,
                               help_text="A branch loan credits that branch's Purchase Cash when the cash arrives.")
    date_approved = forms.DateTimeField(required=False, widget=DATE_TIME, help_text="Leave empty for now.")


class ProofForm(forms.Form):
    photo = forms.FileField(required=False, label="Photo of the cash received (or the lender's slip)")


class DisposalForm(forms.Form):
    items = forms.MultipleChoiceField(widget=forms.CheckboxSelectMultiple, required=False, label="Pieces")
    commitment = forms.ChoiceField(label="Commitment this batch settles", required=False)
    gross_grams = grams_field(label="Gross weight from the settlement (g)", required=False)
    gross_amount = PesoField(label="Gross amount from the settlement (₱)", required=False)
    photo = forms.FileField(required=False)

    def __init__(self, *args, pool, commitments, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["items"].choices = [(item.id, item.id) for item in pool]
        self.fields["commitment"].choices = [("", "—")] + [(c.id, f"{c.lender} ({c.id})") for c in commitments]


# --- staff and rates ----------------------------------------------------------

def _pin_field(label="PIN"):
    return forms.CharField(label=label, strip=False, widget=forms.PasswordInput(attrs={"inputmode": "numeric"}),
                           help_text="4 to 6 digits.")


class StaffForm(forms.Form):
    name = forms.CharField(required=False)
    role = forms.ChoiceField(choices=Role.choices)
    home_branch = forms.ChoiceField(choices=[("", "—")] + BRANCHES, required=False, label="Branch",
                                    help_text="Everyone but an Admin or Superuser works from one branch.")
    contact_number = forms.CharField(required=False, label="Contact number")

    def service_fields(self) -> dict:
        fields = _changed(self, {})
        if "home_branch" in fields:
            fields["home_branch"] = fields["home_branch"] or None
        return fields


class NewStaffForm(StaffForm):
    pin = _pin_field()


class PinForm(forms.Form):
    pin = _pin_field("New PIN")
    again = _pin_field("New PIN again")

    def clean(self):
        data = super().clean()
        if data.get("pin") and data.get("again") and data["pin"] != data["again"]:
            self.add_error("again", "The two PINs don't match")
        elif data.get("pin"):
            try:
                check_pin(data["pin"])
            except ShopError as error:
                self.add_error("pin", error.message)
        return data


class RateForm(forms.Form):
    price = PesoField(label="Price per gram (₱)")


class NewRateForm(RateForm):
    karat = forms.IntegerField(label="Karat (1 to 24) or silver fineness (100 to 999)")


class ApplyRatesForm(forms.Form):
    day = forms.DateField(widget=forms.DateInput(attrs={"type": "date"}))
    metal = forms.ChoiceField(choices=[("gold", "Gold"), ("silver", "Silver")])
