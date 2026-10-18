"""Loads the same demo data the app opens with.

    python manage.py seed_demo            # into an empty database
    python manage.py seed_demo --reset    # wipe every record first, then seed
    python manage.py seed_demo --pin 2468 # the PIN every demo person signs in with

The data is rebuilt relative to now (shop/demo.py) and loaded through the
same importer as POST /sync/import. Every demo person gets the same PIN.
"""

from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction

from accounts.models import User
from accounts.services import check_pin
from shop import demo
from shop.errors import ShopError
from shop.ids import is_taken
from shop.models import Branch, RecordId
from shop.services import cash
from shop.services.base import Ctx, acquire_write_lock
from shop.services.importer import import_snapshot
from shop.text import peso

_TABLES = [
    "shop_disposalitem", "shop_disposalbatch", "shop_salelineitem", "shop_sale", "shop_cashentry",
    "shop_storedreceipt", "shop_item", "shop_purchasebatch", "shop_commitment", "shop_customer", "shop_ratechange",
    "shop_goldrate", "shop_transactionlog", "shop_idempotency_record", "shop_sync_change", "shop_record_id",
    "accounts_user",
]


class Command(BaseCommand):
    help = "Load the app's demo data (staff, purchases, sales, loans, ledger, rates, log)."

    def add_arguments(self, parser):
        parser.add_argument("--reset", action="store_true", help="Delete every record first.")
        parser.add_argument("--pin", default="1234", help="PIN for every demo person (default 1234).")

    def handle(self, *args, **options):
        try:
            check_pin(options["pin"])
        except ShopError as error:
            raise CommandError(error.message) from error
        with transaction.atomic():
            acquire_write_lock()
            if options["reset"]:
                with connection.cursor() as cursor:
                    # Settle deferred foreign-key checks first: TRUNCATE refuses
                    # a table with pending trigger events.
                    cursor.execute("SET CONSTRAINTS ALL IMMEDIATE")
                    # TRUNCATE (unlike DELETE) is not blocked by the append-only triggers.
                    cursor.execute(f"TRUNCATE {', '.join(_TABLES)} RESTART IDENTITY CASCADE")
                    cursor.execute("SET CONSTRAINTS ALL DEFERRED")
                Branch.objects.update(starting_purchase_cash_centavos=0, starting_sales_cash_centavos=0,
                                      starting_bank_centavos=0)
            elif User.objects.exclude(pk__in=[p["id"] for p in demo.STAFF]).exists():
                raise CommandError("This database already has its own staff — run with --reset to replace "
                                   "everything with the demo data")

            for person in demo.STAFF:
                user = User.objects.filter(pk=person["id"]).first()
                if user is None:
                    user = User(id=person["id"], name=person["name"], role=person["role"],
                                home_branch=person["homeBranch"])
                    if not is_taken(user.id):
                        RecordId.objects.create(id=user.id, kind="user")
                user.set_password(options["pin"])
                user.save()

            admin = User.objects.get(pk=demo.ADMIN)
            try:
                report = import_snapshot(Ctx.for_user(admin), demo.build())
            except ShopError as error:
                raise CommandError(error.message) from error

        created = {k: v for k, v in report["created"].items() if v}
        self.stdout.write(self.style.SUCCESS("Demo data loaded: " + ", ".join(f"{v} {k}" for k, v in created.items())))
        for branch in Branch.objects.order_by("id"):
            # "PHP", not "₱": a Windows console's code page often has no peso sign.
            figures = ", ".join(f"{a} PHP {peso(cash.account_balance(branch, a))[1:]}"
                                for a in ("purchase", "sales", "bank"))
            self.stdout.write(f"  {branch.label}: {figures}")
        self.stdout.write("Sign in as any demo person with PIN "
                          f"{options['pin']}: " + ", ".join(p["name"] for p in demo.STAFF))
