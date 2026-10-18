"""Handsets that receive push notifications, and the notifications waiting to
go to them.

Neither is a shop record: a device row is sign-in bookkeeping (like the PIN
attempt counter), and an outbox row is a message about a record, not the
record. So neither writes a TransactionLog row nor travels to the phone in a
snapshot.
"""

from django.conf import settings
from django.db import models
from django.utils import timezone


class Device(models.Model):
    """One FCM registration token — one handset, signed in as one person."""

    class Platform(models.TextChoices):
        ANDROID = "android", "Android"
        IOS = "ios", "iOS"
        WEB = "web", "Web"

    token = models.CharField(max_length=4096, unique=True)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="devices")
    platform = models.CharField(max_length=12, choices=Platform.choices, default=Platform.ANDROID)
    created_at = models.DateTimeField(default=timezone.now)
    last_seen_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-last_seen_at"]
        indexes = [models.Index(fields=["user"])]

    def __str__(self) -> str:
        return f"{self.platform} device of {self.user_id}"


class PushNotification(models.Model):
    """The outbox: one notification for one person.

    Written inside the same transaction as the shop change it is about, so a
    refused or rolled-back write never notifies anyone. Sent after commit.
    """

    class Status(models.TextChoices):
        PENDING = "pending", "Waiting to send"
        SENT = "sent", "Sent"
        NO_DEVICE = "no_device", "Person has no registered phone"
        OFF = "off", "Notifications are off on this server"
        FAILED = "failed", "Could not be delivered"
        EXPIRED = "expired", "Too old to send"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="+")
    kind = models.CharField(max_length=16)  # purchase | sale | commitment | item — what the app routes on
    record_id = models.CharField(max_length=32)
    branch = models.CharField(max_length=16, blank=True, default="")
    title = models.CharField(max_length=120)
    body = models.CharField(max_length=500)
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.PENDING)
    attempts = models.PositiveSmallIntegerField(default=0)
    devices_reached = models.PositiveSmallIntegerField(default=0)
    last_error = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(default=timezone.now)
    sent_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["status", "created_at"])]

    @property
    def data(self) -> dict[str, str]:
        # FCM requires every data value to be a string.
        return {"kind": self.kind, "record_id": self.record_id, "branch": self.branch or ""}
