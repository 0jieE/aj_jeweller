"""Puts staff on a server from a file — first setup, and every hire after.

    python manage.py create_staff --file staff.json            # dry run (the default)
    python manage.py create_staff --file staff.json --apply    # really create

staff.json is a list of
    {"id": "USR-AJ01", "name": "...", "role": "admin|cashier|assistantAppraiser|salesRep",
     "home_branch": "kidapawan|davao", "contact_number": "...", "pin": "1234"}
with home_branch (none for an Admin), contact_number and pin optional; pin
defaults to 1234. The file holds PINs: it is git-ignored, keep it off chats.

* Dry run by default. A dry run does the whole job inside a transaction and
  rolls it back, so it reports exactly what --apply would do and writes nothing.
* Idempotent. Someone already on file with that id is left exactly as they
  are — never renamed, never given a new PIN — and reported "already there".
  Running it twice is how you check it worked.
* Every creation goes through accounts.services.add_user, as the API does:
  same rules, one log row each, naming the Admin who created them. On an
  empty server the first Admin in the file is created the way bootstrap_admin
  does it (naming themself), and the rest are created as that Admin.
* A bad row (unknown role, a branch on an Admin, no branch for branch staff,
  a short PIN, a name already taken) is reported and skipped; the rest carry
  on, and the command exits non-zero.
* At the end: who exists now, and each new person's PIN — printed once.
"""

import json
from dataclasses import dataclass, field
from pathlib import Path

from django.core.management import call_command
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from accounts import services
from accounts.models import User
from shop.enums import BOTH_BRANCH_ROLES, BranchId, Role, a_role, needs_branch
from shop.errors import ShopError
from shop.ids import USER_ID_RE
from shop.services.base import Ctx, acquire_write_lock

DEFAULT_PIN = "1234"
OWNER_ID = "USR-AJ01"


class _DryRun(Exception):
    pass


@dataclass
class Outcome:
    created: list[dict] = field(default_factory=list)  # rows, with their PIN
    existing: list[str] = field(default_factory=list)
    refused: list[tuple[str, str]] = field(default_factory=list)  # (row label, why)


def _label(row: dict, index: int) -> str:
    who = row.get("name") or row.get("id") or "?"
    return f"row {index + 1} ({who})"


def _row_problem(row: dict) -> str | None:
    """What the file itself gets wrong, before any rule on the server."""
    if not isinstance(row, dict):
        return "is not an object"
    user_id = row.get("id")
    if not isinstance(user_id, str) or not USER_ID_RE.match(user_id):
        return f"id {user_id!r} is not a user id — use USR- plus a short suffix, e.g. USR-K-CSH"
    if not isinstance(row.get("name"), str) or not row["name"].strip():
        return "has no name"
    role = row.get("role")
    if role not in Role.values:
        return f"role {role!r} is not one of {', '.join(Role.values)}"
    branch = row.get("home_branch") or None
    if branch is not None and branch not in BranchId.values:
        return f"home_branch {branch!r} is not kidapawan or davao"
    if not needs_branch(role) and branch is not None:
        return f"{a_role(role)} works across both branches - leave home_branch out"
    if needs_branch(role) and branch is None:
        return f"{a_role(role)} works from one branch - give home_branch"
    pin = row.get("pin", DEFAULT_PIN)
    try:
        services.check_pin(pin if isinstance(pin, str) else str(pin))
    except ShopError as error:
        return error.message
    return None


class Command(BaseCommand):
    help = "Create staff from a JSON file (dry run unless --apply). Existing people are never changed."

    def add_arguments(self, parser):
        parser.add_argument("--file", required=True, help="Path to staff.json")
        parser.add_argument("--apply", action="store_true", help="Really create them (default is a dry run).")
        parser.add_argument("--dry-run", action="store_true", help="Only report (the default).")

    def handle(self, *args, **options):
        rows = self._read(options["file"])
        apply = options["apply"] and not options["dry_run"]
        outcome = Outcome()
        try:
            with transaction.atomic():
                acquire_write_lock()
                self._create(rows, outcome)
                if not apply:
                    raise _DryRun
        except _DryRun:
            pass
        self._report(outcome, apply)
        if outcome.refused:
            raise CommandError(f"{len(outcome.refused)} row(s) refused — see above")

    # --- reading ---------------------------------------------------------------
    @staticmethod
    def _read(path: str) -> list:
        file = Path(path)
        if not file.is_file():
            raise CommandError(f"No file at {path}")
        try:
            rows = json.loads(file.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CommandError(f"{path} is not valid JSON: {error}") from None
        if not isinstance(rows, list):
            raise CommandError(f"{path} must hold a list of people")
        return rows

    # --- creating --------------------------------------------------------------
    def _create(self, rows: list, outcome: Outcome) -> None:
        pending = []
        seen = set()
        for index, row in enumerate(rows):
            label = _label(row if isinstance(row, dict) else {}, index)
            problem = _row_problem(row)
            if problem:
                outcome.refused.append((label, problem))
                continue
            if row["id"] in seen:
                outcome.refused.append((label, f"{row['id']} appears twice in the file"))
                continue
            seen.add(row["id"])
            if User.objects.filter(pk=row["id"]).exists():
                outcome.existing.append(row["id"])  # never touched: no rename, no new PIN
                continue
            pending.append((label, row))

        actor = self._actor(pending, outcome)
        if actor is None:
            for label, _row in pending:
                outcome.refused.append((label, "there is no Admin on this server to create them as — "
                                               "put the owner (role admin) in the file"))
            return
        ctx = Ctx.for_user(actor)
        for label, row in pending:
            pin = str(row.get("pin", DEFAULT_PIN))
            try:
                with transaction.atomic():
                    services.add_user(ctx, user_id=row["id"], name=row["name"], role=row["role"],
                                      home_branch=row.get("home_branch") or None,
                                      contact_number=row.get("contact_number"), pin=pin)
            except ShopError as error:
                outcome.refused.append((label, error.message))
                continue
            outcome.created.append({**row, "pin": pin})

    def _actor(self, pending: list, outcome: Outcome) -> User | None:
        """The Admin who creates everyone: the owner if on file, else any active
        Admin — or, on an empty server, the first Admin in the file, created
        the way bootstrap_admin does it."""
        admins = User.objects.filter(role__in=BOTH_BRANCH_ROLES, active=True)
        actor = admins.filter(pk=OWNER_ID).first() or admins.order_by("created_at").first()
        if actor is not None:
            return actor
        for index, (label, row) in enumerate(pending):
            if row["role"] not in BOTH_BRANCH_ROLES:
                continue
            pin = str(row.get("pin", DEFAULT_PIN))
            try:
                with transaction.atomic():
                    call_command("bootstrap_admin", id=row["id"], name=row["name"], pin=pin, role=row["role"],
                                 stdout=_Quiet(), stderr=_Quiet())
            except CommandError as error:
                outcome.refused.append((label, str(error)))
                pending.pop(index)
                return None
            pending.pop(index)
            outcome.created.append({**row, "pin": pin})
            user = User.objects.get(pk=row["id"])
            if row.get("contact_number"):
                services.update_user(Ctx.for_user(user), user.pk, contact_number=row["contact_number"])
            return user
        return None

    # --- reporting -------------------------------------------------------------
    def _report(self, outcome: Outcome, apply: bool) -> None:
        out = self.stdout
        out.write("" if apply else "DRY RUN: nothing was written. Run again with --apply to create these people.\n")
        verb = "Created" if apply else "Would create"
        for row in outcome.created:
            out.write(f"  {verb}: {row['id']}  {row['name']}  ({Role(row['role']).label}"
                      f"{', ' + BranchId(row['home_branch']).label if row.get('home_branch') else ''})")
        for user_id in outcome.existing:
            out.write(f"  Already there, left as is: {user_id}")
        for label, why in outcome.refused:
            self.stderr.write(f"  Refused {label}: {why}")

        out.write("\nStaff on this server now:" if apply else "\nStaff on this server now (unchanged by a dry run):")
        out.write(f"  {'ID':<14}{'NAME':<28}{'ROLE':<22}{'BRANCH':<12}ACTIVE")
        for user in User.objects.order_by("role", "home_branch", "name"):
            out.write(f"  {user.id:<14}{user.name[:27]:<28}{user.role_label:<22}"
                      f"{(BranchId(user.home_branch).label if user.home_branch else 'Both'):<12}"
                      f"{'yes' if user.active else 'no'}")

        if apply and outcome.created:
            out.write("\nPINs for the people just created (shown this once):")
            for row in outcome.created:
                out.write(f"  {row['id']:<14}{row['name'][:27]:<28}PIN {row['pin']}")
            out.write("These PINs are on screen only. Do not paste them into a chat, an email or a file: hand each "
                      "one over in person, and have everyone change theirs at first sign-in (Change PIN on the "
                      "phone).")


class _Quiet:
    def write(self, *_args, **_kwargs):
        pass

    def flush(self):
        pass
