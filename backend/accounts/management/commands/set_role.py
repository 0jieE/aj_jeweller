"""Changes one person's role from the server's shell — the way back into the
Django admin site, which only a Superuser may use.

    python manage.py set_role --id USR-AJ01 --role superuser
    python manage.py set_role --id USR-K-SUP --role supervisor --branch kidapawan
    DATABASE_URL="<external url>" python manage.py set_role --id USR-AJ01 --role superuser

* Idempotent: someone who already holds the role is left alone, and nothing
  is logged.
* Refuses an unknown id or role, a Supervisor or counter role without a
  branch, and anything the staff rules refuse (leaving the shop with no
  Admin, or no Superuser).
* Logged like any staff edit (userUpdated, before/after). The actor is --by,
  or the person themself, the way bootstrap_admin names the first Admin.

It skips only the "who may manage whom" check — whoever can run commands on
the server already holds every key.
"""

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from accounts import services
from accounts.models import User
from shop.enums import BranchId, Role, a_role, needs_branch
from shop.errors import ShopError
from shop.services.base import Ctx, acquire_write_lock


class Command(BaseCommand):
    help = "Set one person's role (and branch). The way back into the admin site: --role superuser."

    def add_arguments(self, parser):
        parser.add_argument("--id", required=True, help="User id, e.g. USR-AJ01")
        parser.add_argument("--role", required=True, help=f"One of: {', '.join(Role.values)}")
        parser.add_argument("--branch", help="kidapawan or davao — for a Supervisor or counter role")
        parser.add_argument("--by", help="User id to log the change under (default: the person themself)")

    def handle(self, *args, **options):
        role, branch = options["role"], options["branch"] or None
        if role not in Role.values:
            raise CommandError(f"{role!r} is not a role — use one of {', '.join(Role.values)}")
        if branch is not None and branch not in BranchId.values:
            raise CommandError(f"{branch!r} is not a branch — use kidapawan or davao")
        user = User.objects.filter(pk=options["id"]).first()
        if user is None:
            raise CommandError(f"No user {options['id']}")
        if not needs_branch(role):
            if branch is not None:
                raise CommandError(f"{a_role(role, capital=True)} works across both branches - leave --branch out")
        else:
            branch = branch or user.home_branch
            if branch is None:
                raise CommandError(f"{a_role(role, capital=True)} works from one branch - give --branch")
        actor = user
        if options["by"]:
            actor = User.objects.filter(pk=options["by"], active=True).first()
            if actor is None:
                raise CommandError(f"No active user {options['by']} to log this under")

        if user.role == role and user.home_branch == branch:
            self.stdout.write(f"{user.name} ({user.id}) is already {Role(role).label}"
                              f"{' at ' + BranchId(branch).label if branch else ''} — nothing changed.")
            return
        before = user.attribution
        try:
            with transaction.atomic():
                acquire_write_lock()
                services.update_user(Ctx.for_user(actor), user.pk, role=role, home_branch=branch, trusted=True)
        except ShopError as error:
            raise CommandError(error.message) from error
        user.refresh_from_db()
        self.stdout.write(self.style.SUCCESS(
            f"{before} is now {user.role_label}{' at ' + BranchId(user.home_branch).label if user.home_branch else ''}."
            f" Logged under {actor.name}."))
        if role == Role.SUPERUSER:
            self.stdout.write(f"{user.name} can sign in to /admin/ with their name and PIN.")
