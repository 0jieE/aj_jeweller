"""Creates the first Admin on an empty server, so someone can sign in.

    python manage.py bootstrap_admin --id USR-AJ01 --name "Arnel Javier" --pin 1234

Using the same id the phone uses for the owner (USR-AJ01 in the app) means a
later /sync/import recognises them instead of adding a second person.
"""

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from accounts.models import User
from accounts.services import check_pin
from shop.enums import LogAction, LogRecordKind, Role
from shop.errors import ShopError
from shop.ids import claim_user_id
from shop.services.base import Ctx, acquire_write_lock, write_log


class Command(BaseCommand):
    help = "Create the first Admin (only while no active Admin exists)."

    def add_arguments(self, parser):
        parser.add_argument("--id", default="USR-AJ01")
        parser.add_argument("--name", required=True)
        parser.add_argument("--pin", required=True)

    def handle(self, *args, **options):
        try:
            check_pin(options["pin"])
            with transaction.atomic():
                acquire_write_lock()
                if User.objects.filter(role=Role.ADMIN, active=True).exists():
                    raise CommandError("An active Admin already exists — add more staff through the API")
                user = User(id=claim_user_id(options["id"]), name=options["name"], role=Role.ADMIN)
                user.set_password(options["pin"])
                user.save()
                # Every write names a person; the first Admin names themself.
                write_log(Ctx.for_user(user), LogAction.USER_ADDED, f"Added {user.name} as Admin",
                          record_id=user.id, record_kind=LogRecordKind.USER)
        except ShopError as error:
            raise CommandError(error.message) from error
        self.stdout.write(self.style.SUCCESS(f"Created {user.name} ({user.id}). Sign in with that name and PIN."))
