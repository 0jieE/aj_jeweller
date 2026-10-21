"""Staff: add, edit, deactivate, set PINs — through accounts/services, so the
role rules (last Admin, last Superuser, one branch per counter role) hold
here exactly as they do in the app."""

from django.contrib import messages
from django.contrib.auth import update_session_auth_hash
from django.shortcuts import redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from accounts import services as accounts
from accounts.models import User

from ..forms import NewStaffForm, PinForm, StaffForm
from .auth import not_found
from .common import attempt, ctx, history


def staff(request):
    people = User.objects.order_by("-active", "role", "name_key")
    return render(request, "office/staff.html", {"title": "Staff", "people": people, "now": timezone.now()})


def staff_new(request):
    form = NewStaffForm(request.POST or None)
    error = None
    if request.method == "POST" and form.is_valid():
        data = form.cleaned_data
        person, error = attempt(lambda: accounts.add_user(
            ctx(request), name=data["name"], role=data["role"], home_branch=data["home_branch"] or None,
            contact_number=data["contact_number"], pin=data["pin"]))
        if person is not None:
            messages.success(request, f"Added {person.name} as {person.role_label}.")
            return redirect("office:staff-member", person.id)
    return render(request, "office/staff_new.html", {"title": "Add staff", "form": form, "error": error},
                  status=422 if request.method == "POST" else 200)


def _member_page(request, person, *, edit=None, pin=None, error=None, status=200):
    return render(request, "office/staff_member.html", {
        "title": person.name, "person": person,
        "edit": edit or StaffForm(initial={"name": person.name, "role": person.role,
                                           "home_branch": person.home_branch or "",
                                           "contact_number": person.contact_number or ""}),
        "pin": pin or PinForm(),
        "delete_problem": accounts.delete_problem(ctx(request), person),
        "activity": accounts.activity_count(person.id),
        "log": history(person.id),
        "error": error,
    }, status=status)


def _person(pk):
    return User.objects.filter(pk=pk).first()


def staff_member(request, pk):
    person = _person(pk)
    if person is None:
        return not_found(request)
    return _member_page(request, person)


@require_POST
def staff_edit(request, pk):
    person = _person(pk)
    if person is None:
        return not_found(request)
    form = StaffForm(request.POST, initial={"name": person.name, "role": person.role,
                                            "home_branch": person.home_branch or "",
                                            "contact_number": person.contact_number or ""})
    if not form.is_valid():
        return _member_page(request, person, edit=form, status=422)
    changes, error = attempt(lambda: accounts.update_user(ctx(request), person.id, **form.service_fields()))
    if error:
        return _member_page(request, person, edit=form, error=error, status=422)
    messages.success(request, "Saved." if changes else "Nothing was changed.")
    return redirect("office:staff-member", person.id)


@require_POST
def staff_pin(request, pk):
    person = _person(pk)
    if person is None:
        return not_found(request)
    form = PinForm(request.POST)
    if not form.is_valid():
        return _member_page(request, person, pin=form, status=422)
    changed, error = attempt(lambda: accounts.set_pin(ctx(request), person.id, form.cleaned_data["pin"]))
    if error:
        return _member_page(request, person, pin=form, error=error, status=422)
    if changed.id == request.user.id:
        update_session_auth_hash(request, changed)  # your own new PIN keeps you signed in here
    messages.success(request, f"{person.name}'s PIN is set. They are signed out everywhere until they use it.")
    return redirect("office:staff-member", person.id)


@require_POST
def staff_active(request, pk):
    person = _person(pk)
    if person is None:
        return not_found(request)
    turn_on = request.POST.get("active") == "1"
    _, error = attempt(lambda: accounts.set_active(ctx(request), person.id, turn_on))
    if error:
        return _member_page(request, person, error=error, status=422)
    messages.success(request, f"{person.name} is {'active again' if turn_on else 'deactivated'}.")
    return redirect("office:staff-member", person.id)


@require_POST
def staff_delete(request, pk):
    person = _person(pk)
    if person is None:
        return not_found(request)
    name = person.name
    _, error = attempt(lambda: accounts.delete_user(ctx(request), person.id))
    if error:
        return _member_page(request, person, error=error, status=422)
    messages.success(request, f"Deleted {name}.")
    return redirect("office:staff")


