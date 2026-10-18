"""Sends one test notification to every phone a person is signed in on, and
prints what FCM said — how the shop checks a new phone.

    python manage.py send_test_notification --user USR-K-CSH
"""

from django.core.management.base import BaseCommand, CommandError

from accounts.models import User
from notifications import fcm
from notifications.models import Device


class Command(BaseCommand):
    help = "Send a test push notification to every device of one user and print FCM's answer."

    def add_arguments(self, parser):
        parser.add_argument("--user", required=True, help="User id, e.g. USR-K-CSH")

    def handle(self, *args, **options):
        user = User.objects.filter(pk=options["user"]).first()
        if user is None:
            raise CommandError(f"No user {options['user']}")
        client = fcm.get_client()
        if client is None:
            raise CommandError(f"Notifications are off: {fcm.off_reason()}. Set FIREBASE_CREDENTIALS_FILE in .env.")
        devices = list(Device.objects.filter(user=user))
        if not devices:
            raise CommandError(f"{user.name} has no registered phone. Sign in as them on the phone, allow "
                               f"notifications, then try again.")

        self.stdout.write(f"Sending to {len(devices)} device(s) of {user.name} ({user.id}) via project "
                          f"{client.project_id}")
        delivered = 0
        for device in devices:
            result = client.send(device.token, "AJ Jeweler test", f"Notifications reach {user.name}'s phone.",
                                 {"kind": "test"})
            label = f"  {device.platform} ...{device.token[-10:]}"
            if result.ok:
                delivered += 1
                self.stdout.write(self.style.SUCCESS(f"{label}: sent ({result.message_id})"))
            else:
                line = f"{label}: HTTP {result.status} {result.error_code} — {result.message}"
                if result.token_is_dead:
                    device.delete()
                    line += " — token removed"
                self.stdout.write(self.style.ERROR(line))
        if not delivered:
            raise CommandError("Nothing was delivered.")
