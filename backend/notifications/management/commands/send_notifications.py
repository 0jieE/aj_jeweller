"""Sends any notification still waiting in the outbox, and drops ones too old
to be news. Run it every few minutes (Windows Task Scheduler or cron). It is
the only sender when PUSH_DELIVERY=command, and the retry path otherwise.

    python manage.py send_notifications
"""

from django.core.management.base import BaseCommand

from notifications import outbox


class Command(BaseCommand):
    help = "Send pending push notifications and expire stale ones."

    def handle(self, *args, **options):
        expired = outbox.expire_stale()
        counts = outbox.send_pending()
        summary = ", ".join(f"{n} {status}" for status, n in sorted(counts.items())) or "nothing pending"
        self.stdout.write(f"{summary}; {expired} expired")
