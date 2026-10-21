"""Who may use the office: an active Superuser, and nobody else.

Not the Admin either, though the Admin owns the shop. This surface reaches
further into the records than any other, and a wrong move here is a wrong
history, not a wrong purchase; the owner runs the shop from the app.

`superuser_only` guards every page. It is applied in office/urls.py to the
whole of `pages`, rather than view by view, so a page added later cannot be
left open by forgetting it — and a bookmarked URL is checked like any other.
Deliberately not settings.ADMIN_SITE_ROLES: widening Django's own admin must
not widen this.
"""

from functools import wraps

from django.contrib.auth.views import redirect_to_login
from django.http import HttpResponse
from django.shortcuts import render
from django.urls import reverse

from shop.enums import Role

REFUSED = ("This screen belongs to whoever maintains the system. "
           "Everything you do for the shop is in the app.")


def may_enter(user) -> bool:
    return bool(user.is_authenticated and user.is_active and user.role == Role.SUPERUSER)


def refused(request, status: int = 403):
    """The friendly no: who this is for, and where the person's own work is."""
    return render(request, "office/refused.html", {"refused_message": REFUSED}, status=status)


def superuser_only(view):
    @wraps(view)
    def guarded(request, *args, **kwargs):
        if not request.user.is_authenticated:
            login = reverse("office:login")
            if request.headers.get("HX-Request"):
                # A table filtered after the session ran out: send the whole
                # window to the sign-in, not a sign-in form into the table.
                response = HttpResponse(status=204)
                response["HX-Redirect"] = f"{login}?next={request.get_full_path()}"
                return response
            return redirect_to_login(request.get_full_path(), login)
        if not may_enter(request.user):
            return refused(request)
        return view(request, *args, **kwargs)

    guarded.superuser_only = True
    return guarded
