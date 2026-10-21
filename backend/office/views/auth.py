"""Signing in to the office: the admin site's PIN form, admitting only a Superuser."""

from django.contrib.auth import views as auth_views
from django.shortcuts import redirect, render
from django.urls import reverse_lazy

from config.admin_site import LoginForm

from ..access import REFUSED, may_enter


class OfficeLoginForm(LoginForm):
    """Same name-or-id and PIN, same lockout, as the app and the admin site.
    A correct PIN from anyone but a Superuser signs nobody in."""

    refused_message = REFUSED

    def allowed(self, user) -> bool:
        return may_enter(user)


def login(request):
    if may_enter(request.user):
        return redirect("office:today")
    return auth_views.LoginView.as_view(
        template_name="office/login.html",
        authentication_form=OfficeLoginForm,
        next_page=reverse_lazy("office:today"),
        extra_context={"title": "Sign in"},
    )(request)


logout = auth_views.LogoutView.as_view(next_page=reverse_lazy("office:login"))


def not_found(request, path=""):
    """Any other address under /administrator/ — never the Flutter app's index.html.
    Listed among the guarded pages, so a refused person hears the same as on a real one."""
    return render(request, "office/not_found.html", {"title": "Not found"}, status=404)
