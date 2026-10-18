"""The notification outbox: written with the shop change, sent after commit.

Why an outbox table plus a thread, rather than a bare thread:

* The row is written inside the shop's own transaction. A write that is
  refused or rolled back therefore notifies nobody, and a notification can
  never describe something that did not happen.
* After commit (`transaction.on_commit`) a short-lived background thread sends
  the new rows, so the request that wrote a purchase never waits on Google.
* Anything the thread could not send — FCM unreachable, the server restarted
  mid-send — stays `pending`, and `python manage.py send_notifications` (run
  it every few minutes from Task Scheduler / cron) retries it. Rows too old to
  be useful are marked expired instead of arriving in a burst.

PUSH_DELIVERY picks how the post-commit send runs: "thread" (default),
"inline" (in the request thread — tests), or "command" (only the management
command sends).
"""

import logging
import threading
from datetime import timedelta

from django.conf import settings
from django.db import close_old_connections, connection, transaction
from django.utils import timezone

from . import fcm
from .models import Device, PushNotification

log = logging.getLogger("notifications")

MAX_ATTEMPTS = 5
Status = PushNotification.Status


def enqueue(users, *, kind: str, record_id: str, branch: str | None, title: str, body: str,
            exclude_user_id: str | None = None) -> list[int]:
    """Queues one notification per person (never the person who caused it) and
    arranges for them to be sent once the current transaction commits."""
    rows = []
    seen = set()
    for user in users:
        if user is None or user.pk in seen or user.pk == exclude_user_id or not user.active:
            continue
        seen.add(user.pk)
        rows.append(PushNotification.objects.create(
            user=user, kind=kind, record_id=record_id, branch=branch or "", title=title[:120], body=body[:500],
        ))
    ids = [row.pk for row in rows]
    if ids:
        transaction.on_commit(lambda: _after_commit(ids))
    return ids


def _after_commit(ids: list[int]) -> None:
    mode = settings.PUSH_DELIVERY
    if mode == "inline":
        send_pending(ids)
    elif mode == "thread":
        threading.Thread(target=_send_in_thread, args=(ids,), name="push-send", daemon=True).start()
    # "command": left pending for `manage.py send_notifications`


def _send_in_thread(ids: list[int]) -> None:
    close_old_connections()
    try:
        send_pending(ids)
    except Exception:  # never let a notification problem surface anywhere
        log.exception("Sending push notifications failed; they stay pending for send_notifications")
    finally:
        connection.close()


def send_pending(ids: list[int] | None = None, *, client=None) -> dict[str, int]:
    """Sends pending notifications (all of them, or just `ids`). Each row is
    claimed with SKIP LOCKED, so two senders never deliver the same one."""
    client =client if client is not None else fcm.get_client()
    queryset = PushNotification.objects.filter(status=Status.PENDING)
    if ids is not None:
        queryset = queryset.filter(pk__in=ids)
    counts: dict[str, int] = {}
    for pk in list(queryset.order_by("created_at").values_list("pk", flat=True)):
        with transaction.atomic():
            row = PushNotification.objects.select_for_update(skip_locked=True).filter(
                pk=pk, status=Status.PENDING).first()
            if row is None:
                continue  # another sender has it
            _deliver(row, client)
            counts[row.status] = counts.get(row.status, 0) + 1
    return counts


def _deliver(row: PushNotification, client) -> None:
    if client is None:
        row.status = Status.OFF
        row.last_error = "Notifications are off on this server (no Firebase credential)"
        row.save()
        return
    devices = list(Device.objects.filter(user_id=row.user_id))
    if not devices:
        row.status = Status.NO_DEVICE
        row.save()
        return
    row.attempts += 1
    reached, transient, errors = 0, False, []
    for device in devices:
        result = client.send(device.token, row.title, row.body, row.data)
        if result.ok:
            reached += 1
            continue
        if result.token_is_dead:
            # A stale token must never stop the rest of the staff being reached.
            log.info("Removing a dead FCM token of %s (%s)", device.user_id, result.error_code)
            device.delete()
            continue
        transient = transient or result.transient
        errors.append(f"{result.error_code or result.status}: {result.message}")
    row.devices_reached = reached
    row.last_error = "; ".join(errors)[:2000]
    if reached:
        row.status, row.sent_at = Status.SENT, timezone.now()
    elif transient and row.attempts < MAX_ATTEMPTS:
        row.status = Status.PENDING  # try again on the next send_notifications run
    elif errors:
        row.status = Status.FAILED
    else:
        row.status = Status.NO_DEVICE  # every token it had turned out to be dead
    row.save()


def expire_stale() -> int:
    """Pending rows older than PUSH_MAX_AGE_HOURS are no longer news."""
    cutoff = timezone.now() - timedelta(hours=settings.PUSH_MAX_AGE_HOURS)
    return PushNotification.objects.filter(status=Status.PENDING, created_at__lt=cutoff).update(
        status=Status.EXPIRED, last_error="Too old to send")
