"""The admin site: same sign-in as the app, and a PIN — not a password — change.

Only an active Superuser gets in (settings.ADMIN_SITE_ROLES). Sign in with your name (or user id) and PIN; wrong
PINs count towards the same lockout as the phone.
"""

from django import forms
from django.contrib import admin
from django.contrib.admin.forms import AdminAuthenticationForm
from django.db import transaction

from accounts.services import SignInRefused, authenticate_pin, change_own_pin, check_pin
from shop.errors import ShopError
from shop.services.base import Ctx, acquire_write_lock


class LoginForm(AdminAuthenticationForm):
    error_messages = {
        **AdminAuthenticationForm.error_messages,
        "invalid_login": "That name and PIN don't match",
        "inactive": "This account has been deactivated — ask an Admin",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["username"].label = "Name or user id"
        self.fields["password"].label = "PIN"

    def clean(self):
        username = (self.cleaned_data.get("username") or "").strip()
        pin = self.cleaned_data.get("password") or ""
        if not username or not pin:
            return self.cleaned_data
        from accounts.models import User

        by_id = User.objects.filter(pk=username).exists()
        try:
            user = authenticate_pin(user_id=username if by_id else None, name=None if by_id else username, pin=pin)
        except SignInRefused as refused:
            raise forms.ValidationError(refused.message, code=refused.code) from None
        user.backend = "accounts.backends.PinBackend"
        self.user_cache = user
        if not self.allowed(user):
            raise forms.ValidationError(self.refused_message, code="not_superuser")
        return self.cleaned_data

    # Who this sign-in admits, and what it tells everyone else. The office at
    # /administrator/ (office.views) subclasses this form and changes only these.
    refused_message = "Only a Superuser can use the administration site"

    def allowed(self, user) -> bool:
        return user.is_staff


class PinChangeForm(forms.Form):
    """Field names match Django's password-change view; the rules are the PIN's."""

    old_password = forms.CharField(label="Current PIN", widget=forms.PasswordInput(render_value=False), strip=False)
    new_password1 = forms.CharField(label="New PIN", widget=forms.PasswordInput, strip=False,
                                    help_text="4 to 6 digits.")
    new_password2 = forms.CharField(label="New PIN again", widget=forms.PasswordInput, strip=False)

    def __init__(self, user, *args, **kwargs):
        self.user = user
        super().__init__(*args, **kwargs)

    def clean(self):
        data = super().clean()
        if not self.user.check_password(data.get("old_password") or ""):
            self.add_error("old_password", "Your current PIN is not right")
        new, again = data.get("new_password1"), data.get("new_password2")
        if new and again and new != again:
            self.add_error("new_password2", "The two PINs don't match")
        elif new:
            try:
                check_pin(new)
            except ShopError as error:
                self.add_error("new_password1", error.message)
        return data

    def save(self, commit=True):
        with transaction.atomic():
            acquire_write_lock()
            # Logged as a userUpdated row, like a PIN change from the phone.
            self.user = change_own_pin(Ctx.for_user(self.user), self.cleaned_data["old_password"],
                                       self.cleaned_data["new_password1"])
        return self.user


class ShopAdminSite(admin.AdminSite):
    site_header = "AJ Jeweler administration"
    site_title = "AJ Jeweler admin"
    index_title = "Kidapawan and Davao"
    site_url = None  # there is no public website to "view"
    login_form = LoginForm
    password_change_template = "admin/pin_change_form.html"

    def password_change(self, request, extra_context=None):
        from django.contrib.auth.views import PasswordChangeView
        from django.urls import reverse

        request.current_app = self.name
        return PasswordChangeView.as_view(
            form_class=PinChangeForm,
            success_url=reverse("admin:password_change_done", current_app=self.name),
            template_name=self.password_change_template,
            extra_context={**self.each_context(request), **(extra_context or {}), "title": "Change your PIN"},
        )(request)
