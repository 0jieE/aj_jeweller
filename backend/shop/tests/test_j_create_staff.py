"""create_staff: putting real staff on a server from a file."""

import io
import json
import tempfile
from pathlib import Path

from django.core.management import CommandError, call_command
from django.test import TestCase

from accounts.models import User
from shop.models import TransactionLog

STAFF = [
    {"id": "USR-AJ01", "name": "Owner Person", "role": "admin", "pin": "4826"},
    {"id": "USR-K-CSH", "name": "Kida Cashier", "role": "cashier", "home_branch": "kidapawan",
     "contact_number": "0917 000 1111", "pin": "5931"},
    {"id": "USR-D-APR", "name": "Davao Appraiser", "role": "assistantAppraiser", "home_branch": "davao"},
    {"id": "USR-D-REP", "name": "Davao Rep", "role": "salesRep", "home_branch": "davao", "pin": "772211"},
]


class CreateStaffTests(TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def file(self, rows) -> str:
        path = Path(self.dir.name) / "staff.json"
        path.write_text(json.dumps(rows), encoding="utf-8")
        return str(path)

    def run_command(self, rows, *args, expect_refusal=False):
        out, err = io.StringIO(), io.StringIO()
        if expect_refusal:
            with self.assertRaises(CommandError):
                call_command("create_staff", "--file", self.file(rows), *args, stdout=out, stderr=err)
        else:
            call_command("create_staff", "--file", self.file(rows), *args, stdout=out, stderr=err)
        return out.getvalue(), err.getvalue()

    def test_creating_from_a_file_makes_exactly_those_people(self):
        out, _ = self.run_command(STAFF, "--apply")
        people = {u.id: (u.name, u.role, u.home_branch) for u in User.objects.all()}
        self.assertEqual(people, {
            "USR-AJ01": ("Owner Person", "admin", None),
            "USR-K-CSH": ("Kida Cashier", "cashier", "kidapawan"),
            "USR-D-APR": ("Davao Appraiser", "assistantAppraiser", "davao"),
            "USR-D-REP": ("Davao Rep", "salesRep", "davao"),
        })
        self.assertTrue(User.objects.get(pk="USR-AJ01").check_password("4826"))
        self.assertTrue(User.objects.get(pk="USR-D-APR").check_password("1234"), "no PIN given means 1234")
        self.assertEqual(User.objects.get(pk="USR-K-CSH").contact_number, "0917 000 1111")
        # Logged through the service: the owner names themself, the rest are added by the owner.
        added = dict(TransactionLog.objects.filter(action="userAdded").values_list("record_id", "user_id"))
        self.assertEqual(added, {"USR-AJ01": "USR-AJ01", "USR-K-CSH": "USR-AJ01", "USR-D-APR": "USR-AJ01",
                                 "USR-D-REP": "USR-AJ01"})
        # Each PIN once, at the end.
        for pin in ("4826", "5931", "772211"):
            self.assertEqual(out.count(pin), 1, pin)
        self.assertIn("Do not paste them", out)

    def test_a_second_run_changes_nothing_and_says_so(self):
        self.run_command(STAFF, "--apply")
        logs = TransactionLog.objects.count()
        out, _ = self.run_command(STAFF, "--apply")
        self.assertEqual(out.count("Already there"), 4)
        self.assertNotIn("Created:", out)
        self.assertNotIn("PIN 4826", out, "no PINs to hand out when nobody is new")
        self.assertEqual(TransactionLog.objects.count(), logs)
        self.assertEqual(User.objects.count(), 4)

    def test_an_existing_persons_pin_is_never_reset(self):
        self.run_command(STAFF, "--apply")
        owner = User.objects.get(pk="USR-AJ01")
        owner.set_password("9090")
        owner.save()
        renamed = [{**STAFF[0], "name": "Someone Else", "pin": "1111"}]
        self.run_command(renamed, "--apply")
        owner.refresh_from_db()
        self.assertTrue(owner.check_password("9090"))
        self.assertEqual(owner.name, "Owner Person")

    def test_bad_rows_are_refused_one_by_one_and_the_rest_are_created(self):
        rows = STAFF + [
            {"id": "USR-X-ONE", "name": "Wrong Role", "role": "manager", "home_branch": "davao"},
            {"id": "USR-X-TWO", "name": "Branchy Admin", "role": "admin", "home_branch": "davao"},
            {"id": "USR-X-THR", "name": "Floating Cashier", "role": "cashier"},
            {"id": "USR-X-FOU", "name": "Short Pin", "role": "salesRep", "home_branch": "davao", "pin": "12"},
            {"id": "USR-X-FIV", "name": "kida  CASHIER", "role": "cashier", "home_branch": "davao"},
        ]
        _, err = self.run_command(rows, "--apply", expect_refusal=True)
        self.assertIn("role 'manager' is not one of", err)
        self.assertIn("an Admin works across both branches", err)
        self.assertNotIn("a Admin", err)
        self.assertIn("a Cashier works from one branch", err)
        self.assertIn("A PIN is 4 to 6 digits", err)
        self.assertIn("Kida Cashier is already on file", err)
        self.assertEqual(set(User.objects.values_list("id", flat=True)),
                         {"USR-AJ01", "USR-K-CSH", "USR-D-APR", "USR-D-REP"})

    def test_a_dry_run_writes_nothing(self):
        out, _ = self.run_command(STAFF)
        self.assertIn("DRY RUN", out)
        self.assertEqual(out.count("Would create"), 4)
        self.assertNotIn("4826", out, "no PINs are printed for people who were not created")
        self.assertEqual(User.objects.count(), 0)
        self.assertEqual(TransactionLog.objects.count(), 0)
        self.run_command(STAFF, "--dry-run", "--apply")
        self.assertEqual(User.objects.count(), 0, "--dry-run wins")

    def test_on_a_server_that_already_has_an_admin_new_staff_are_added_by_them(self):
        self.run_command(STAFF[:1], "--apply")
        self.run_command([{"id": "USR-K-NEW", "name": "New Hire", "role": "salesRep", "home_branch": "kidapawan"}],
                         "--apply")
        log = TransactionLog.objects.get(action="userAdded", record_id="USR-K-NEW")
        self.assertEqual(log.user_id, "USR-AJ01")

    def test_with_no_admin_anywhere_the_rows_are_refused(self):
        _, err = self.run_command(STAFF[1:], "--apply", expect_refusal=True)
        self.assertIn("no Admin on this server", err)
        self.assertEqual(User.objects.count(), 0)

    def test_a_file_that_is_not_a_list_is_refused_whole(self):
        path = Path(self.dir.name) / "staff.json"
        path.write_text('{"id": "USR-AJ01"}', encoding="utf-8")
        with self.assertRaisesMessage(CommandError, "must hold a list"):
            call_command("create_staff", "--file", str(path), stdout=io.StringIO())
