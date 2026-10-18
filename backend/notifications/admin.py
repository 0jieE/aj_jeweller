"""Phones and push notifications in the admin site."""

from django.contrib import admin

from shop.admin_tools import ReadOnlyAdmin

from . import outbox
from .models import Device, PushNotification


@admin.register(Device)
class DeviceAdmin(ReadOnlyAdmin):
    """Registered phones. Removing one is the same as that phone signing out."""

    list_display = ["user", "platform", "token_tail", "created_at", "last_seen_at"]
    list_filter = ["platform", "user__home_branch"]
    search_fields = ["user__name", "user__id", "token"]
    list_select_related = ["user"]
    actions = ["delete_selected"]

    def has_delete_permission(self, request, obj=None):
        return request.user.is_active and request.user.is_staff

    @admin.display(description="Token")
    def token_tail(self, obj):
        return f"…{obj.token[-12:]}"


@admin.register(PushNotification)
class PushNotificationAdmin(ReadOnlyAdmin):
    list_display = ["created_at", "user", "title", "body", "status", "devices_reached", "attempts", "kind",
                    "record_id"]
    list_filter = ["status", "kind", "branch"]
    search_fields = ["user__name", "record_id", "title", "body"]
    date_hierarchy = "created_at"
    list_select_related = ["user"]
    actions = ["send_now"]

    @admin.action(description="Send the selected pending notifications now")
    def send_now(self, request, queryset):
        counts = outbox.send_pending(list(queryset.filter(status=PushNotification.Status.PENDING)
                                          .values_list("pk", flat=True)))
        self.message_user(request, ", ".join(f"{n} {s}" for s, n in counts.items()) or "Nothing was pending.")
