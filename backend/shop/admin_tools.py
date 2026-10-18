"""Building blocks for the admin site.

Shop records are **view-only** here. Editing a row directly would skip the
business rules and the one-log-row-per-change rule (and the transaction log is
append-only in the database anyway), so every change goes through the API —
or, for staff, through admin forms that call the same services.
"""

from django.contrib import admin
from django.db import transaction
from django.utils.html import format_html

from .errors import ShopError
from .services.base import Ctx, acquire_write_lock
from .text import peso


class _Rollback(Exception):
    pass


def trial(fn) -> str | None:
    """Runs a service call and always rolls it back. Returns the refusal
    message, or None if it would succeed — so an admin form can say no in the
    service's own words before anything is saved."""
    try:
        with transaction.atomic():
            acquire_write_lock()
            fn()
            raise _Rollback
    except _Rollback:
        return None
    except ShopError as error:
        return error.message


def run(fn):
    """Runs a service call for real, under the shop's write lock."""
    with transaction.atomic():
        acquire_write_lock()
        return fn()


def ctx_for(request) -> Ctx:
    return Ctx.for_user(request.user)


def money(value) -> str:
    return "—" if value is None else peso(value)


def grams(value) -> str:
    return "—" if value is None else f"{value:.3f} g"


def photo_link(field) -> str:
    if not field:
        return "—"
    return format_html('<a href="{}" target="_blank"><img src="{}" style="max-height:80px"></a>', field.url, field.url)


class ReadOnlyAdmin(admin.ModelAdmin):
    """Browse, search and filter; no add, change or delete."""

    actions = None
    list_per_page = 50

    def has_add_permission(self, request, obj=None):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def has_view_permission(self, request, obj=None):
        return request.user.is_active and request.user.is_staff


class ReadOnlyInline(admin.TabularInline):
    extra = 0
    can_delete = False
    show_change_link = True

    def has_add_permission(self, request, obj=None):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def has_view_permission(self, request, obj=None):
        return request.user.is_active and request.user.is_staff
