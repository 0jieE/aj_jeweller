"""Supervisor (one branch) and Superuser (Admin + the Django admin site)."""

import io
from unittest import mock

from django.core.management import CommandError, call_command
from django.test import Client, override_settings
from django.urls import reverse

from accounts.models import User
from notifications import fcm
from notifications.models import Device
from shop.models import RecordId, TransactionLog

from .helpers import ARNEL, BEN, GRACE, JOEL, LIZA, PAOLO, PIN, RHEA, ApiTestCase, png_b64

K_SUP, D_SUP, SU = "USR-K-SUP", "USR-D-SUP", "USR-SU01"


def add_person(user_id, name, role, branch=None):
    user = User(id=user_id, name=name, role=role, home_branch=branch)
    user.set_password(PIN)
    user.save()
    RecordId.objects.get_or_create(id=user_id, defaults={"kind": "user"})
    return user


class RolesTestCase(ApiTestCase):
    def setUp(self):
        super().setUp()
        add_person(K_SUP, "Kim Supervisor", "supervisor", "kidapawan")
        add_person(D_SUP, "Dan Supervisor", "supervisor", "davao")
        add_person(SU, "Sam Superuser", "superuser")

    def loan(self, branch, *, by=ARNEL, received=False):
        body = {"lender": f"Lender {branch}", "amount_centavos": 5000000, "rate_per_gram_centavos": 500000}
        if branch:
            body["branch"] = branch
        loan = self.post(by, "/commitments", body, expect=201).data
        if received:
            self.post(by, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        return loan


class SupervisorBranchWorkTests(RolesTestCase):
    def test_a_supervisor_runs_their_own_branch(self):
        entry = self.post(K_SUP, "/cash/entries", {"type": "expense", "amount_centavos": 5000, "note": "Bulbs",
                                                   "category": "Supplies"}, expect=201).data
        self.assertEqual(entry["branch"], "kidapawan")
        self.patch(K_SUP, f"/cash/entries/{entry['id']}", {"amount_centavos": 6000}, expect=200)

        item = self.released_item(type="scrap", grams="10", amount=400000)
        fixed = self.patch(K_SUP, f"/items/{item['id']}", {"description": "Scrap (rechecked)"}, expect=200).data
        self.assertEqual(fixed["item"]["description"], "Scrap (rechecked)")
        self.assertEqual(self.last_log().user_id, K_SUP)

        loan = self.loan("kidapawan", by=K_SUP)
        self.post(K_SUP, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        batch = self.post(K_SUP, "/disposal", {"item_ids": [item["id"]], "gross_grams": "10",
                                               "gross_amount_centavos": 500000, "commitment_id": loan["id"]},
                          expect=201).data
        self.assertEqual(batch["branch"], "kidapawan")

        lot = self.released_item(type="scrap", grams="20", amount=800000)
        piece = self.post(LIZA, f"/items/{lot['id']}/partitions", {"description": "P", "type": "goods",
                                                                  "grams": "5", "amount_centavos": 200000},
                          expect=201).data
        self.delete(K_SUP, f"/partitions/{piece['id']}", expect=200)

        # A transfer with their branch at either end.
        self.post(K_SUP, "/cash/transfers", {"to_branch": "davao", "amount_centavos": 100, "note": "Float"},
                  expect=201)
        self.post(K_SUP, "/cash/transfers", {"from_branch": "davao", "to_branch": "kidapawan",
                                             "amount_centavos": 100, "note": "Float back"}, expect=201)

    def test_and_is_refused_every_one_of_those_at_the_other_branch(self):
        self.refusal(self.post(K_SUP, "/cash/entries", {"branch": "davao", "type": "cashIn", "amount_centavos": 5,
                                                        "note": "x"}), 403)
        davao_entry = self.post(BEN, "/cash/entries", {"type": "cashIn", "amount_centavos": 5, "note": "x"},
                                expect=201).data
        self.refusal(self.patch(K_SUP, f"/cash/entries/{davao_entry['id']}", {"amount_centavos": 6}), 403)
        self.refusal(self.delete(K_SUP, f"/cash/entries/{davao_entry['id']}"), 403)
        self.refusal(self.post(K_SUP, "/cash/transfers", {"from_branch": "davao", "from_account": "bank",
                                                          "to_branch": "davao", "to_account": "purchase",
                                                          "amount_centavos": 5, "note": "x"}), 403)

        davao_item = self.released_item(type="scrap", branch="davao")
        self.refusal(self.patch(K_SUP, f"/items/{davao_item['id']}", {"description": "x"}), 403)

        davao_loan = self.loan("davao")
        self.refusal(self.post(K_SUP, f"/commitments/{davao_loan['id']}/receive", {"proof_photo": png_b64()}), 403)
        self.refusal(self.post(K_SUP, "/commitments", {"lender": "X", "amount_centavos": 1,
                                                       "rate_per_gram_centavos": 1, "branch": "davao"}), 403)
        self.post(ARNEL, f"/commitments/{davao_loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        self.refusal(self.post(K_SUP, "/disposal", {"branch": "davao", "item_ids": [davao_item["id"]],
                                                    "gross_grams": "1", "gross_amount_centavos": 1,
                                                    "commitment_id": davao_loan["id"]}), 403)

        lot = self.released_item(type="scrap", branch="davao", grams="20", amount=800000)
        piece = self.post(JOEL, f"/items/{lot['id']}/partitions", {"description": "P", "type": "goods",
                                                                  "grams": "5", "amount_centavos": 200000},
                          expect=201).data
        self.refusal(self.delete(K_SUP, f"/partitions/{piece['id']}"), 403)
        self.refusal(self.get(K_SUP, "/purchases", {"branch": "davao"}, expect=None), 403)

    def test_a_company_wide_loan_stays_the_admins(self):
        message = self.refusal(self.post(K_SUP, "/commitments", {"lender": "Golden Circle", "amount_centavos": 1,
                                                                 "rate_per_gram_centavos": 1}), 403)
        self.assertIn("company-wide loan is the Admin's", message)
        company = self.loan(None)
        self.refusal(self.post(K_SUP, f"/commitments/{company['id']}/receive", {"proof_photo": png_b64()}), 403)
        self.post(ARNEL, f"/commitments/{company['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        scrap = self.released_item(type="scrap")
        self.refusal(self.post(K_SUP, "/disposal", {"item_ids": [scrap["id"]], "gross_grams": "1",
                                                    "gross_amount_centavos": 1, "commitment_id": company["id"]}),
                     403)

    def test_a_supervisor_still_does_not_encode_purchases_or_build_sales(self):
        self.refusal(self.purchase(by=K_SUP, expect=None), 403)
        item = self.released_item()
        self.refusal(self.post(K_SUP, f"/items/{item['id']}/reserve"), 403)


class RatesForEveryoneTests(RolesTestCase):
    def test_every_role_can_set_a_rate_and_the_log_names_them(self):
        self.post(ARNEL, "/rates", {"karat": 18, "price_per_gram_centavos": 460000}, expect=201)
        for price, person in enumerate((GRACE, LIZA, RHEA, K_SUP, BEN, JOEL, PAOLO), start=1):
            self.patch(person, "/rates/18", {"price_per_gram_centavos": 460000 + price * 100}, expect=200)
            log = self.last_log()
            self.assertEqual((log.action, log.user_id), ("goldRateUpdated", person))
        self.post(GRACE, "/rates", {"karat": 925, "price_per_gram_centavos": 6500}, expect=201)
        self.assertEqual(self.last_log().user_id, GRACE)


class SupervisorStaffTests(RolesTestCase):
    def new_cashier(self, by, branch, expect=201):
        return self.post(by, "/users", {"name": f"New Cashier {branch} {by}", "role": "cashier",
                                        "home_branch": branch, "pin": "2468"}, expect=expect)

    def test_a_supervisor_adds_and_manages_counter_staff_at_their_branch(self):
        cashier = self.new_cashier(K_SUP, "kidapawan").data
        self.assertEqual(TransactionLog.objects.get(action="userAdded", record_id=cashier["id"]).user_id, K_SUP)
        self.patch(K_SUP, f"/users/{cashier['id']}", {"role": "salesRep"}, expect=200)
        self.post(K_SUP, f"/users/{cashier['id']}/pin", {"pin": "1357"}, expect=200)
        self.post(K_SUP, f"/users/{GRACE}/deactivate", expect=200)
        self.post(K_SUP, f"/users/{GRACE}/reactivate", expect=200)

    def test_but_not_at_the_other_branch(self):
        self.refusal(self.new_cashier(K_SUP, "davao", expect=None), 403)
        self.refusal(self.post(K_SUP, f"/users/{BEN}/deactivate"), 403)
        self.refusal(self.post(K_SUP, f"/users/{BEN}/pin", {"pin": "1357"}), 403)
        self.refusal(self.patch(K_SUP, f"/users/{BEN}", {"name": "Benny"}), 403)
        self.refusal(self.patch(K_SUP, f"/users/{GRACE}", {"home_branch": "davao"}), 403)

    def test_a_supervisor_cannot_climb_out_of_the_branch(self):
        for role in ("admin", "superuser", "supervisor"):
            body = {"name": f"Climber {role}", "role": role, "pin": "2468"}
            if role == "supervisor":
                body["home_branch"] = "kidapawan"
            self.refusal(self.post(K_SUP, "/users", body), 403)
        for target in (ARNEL, SU, D_SUP, K_SUP):
            self.refusal(self.patch(K_SUP, f"/users/{target}", {"name": "Renamed"}), 403)
            self.refusal(self.post(K_SUP, f"/users/{target}/deactivate"), 403)
            self.refusal(self.post(K_SUP, f"/users/{target}/pin", {"pin": "1357"}), 403)
            self.refusal(self.delete(K_SUP, f"/users/{target}"), 403)
        for role in ("admin", "superuser", "supervisor"):
            self.refusal(self.patch(K_SUP, f"/users/{GRACE}", {"role": role}), 403)
            self.refusal(self.patch(K_SUP, f"/users/{K_SUP}", {"role": role}), 403)
        self.assertEqual(User.objects.get(pk=K_SUP).role, "supervisor")
        self.assertEqual(User.objects.get(pk=GRACE).role, "cashier")
        self.assertFalse(User.objects.filter(name__startswith="Climber").exists())

    def test_a_supervisor_needs_a_branch(self):
        message = self.refusal(self.post(ARNEL, "/users", {"name": "No Branch Sup", "role": "supervisor",
                                                           "pin": "2468"}))
        self.assertEqual(message, "A Supervisor works from one branch — pick it")
        created = self.post(ARNEL, "/users", {"name": "Real Sup", "role": "supervisor", "home_branch": "davao",
                                              "pin": "2468"}, expect=201).data
        self.assertEqual(created["home_branch"], "davao")
        # An Admin or Superuser never keeps a branch.
        admin = self.post(SU, "/users", {"name": "Branchless Admin", "role": "admin", "home_branch": "davao",
                                         "pin": "2468"}, expect=201).data
        self.assertIsNone(admin["home_branch"])

    def test_only_a_superuser_manages_a_superuser(self):
        self.assertEqual(self.refusal(self.post(ARNEL, "/users", {"name": "Another SU", "role": "superuser",
                                                                  "pin": "2468"}), 403),
                         "Only a Superuser can manage a Superuser")
        self.refusal(self.post(ARNEL, f"/users/{SU}/deactivate"), 403)
        self.refusal(self.patch(ARNEL, f"/users/{GRACE}", {"role": "superuser"}), 403)
        self.post(SU, "/users", {"name": "Another SU", "role": "superuser", "pin": "2468"}, expect=201)

    def test_the_last_superuser_cannot_be_demoted_or_deactivated(self):
        message = self.refusal(self.patch(SU, f"/users/{SU}", {"role": "admin"}))
        self.assertIn("only active Superuser", message)
        second = self.post(SU, "/users", {"name": "Second SU", "role": "superuser", "pin": "2468"},
                           expect=201).data["id"]
        self.patch(SU, f"/users/{second}", {"role": "admin"}, expect=200)


class SuperuserTests(RolesTestCase):
    def test_a_superuser_may_do_everything_an_admin_may(self):
        self.assertEqual(len(self.get(SU, "/branches").data), 2)
        davao_item = self.released_item(type="scrap", branch="davao")
        self.patch(SU, f"/items/{davao_item['id']}", {"description": "Fixed by SU"}, expect=200)
        company = self.loan(None, by=SU, received=True)
        self.post(SU, "/disposal", {"branch": "davao", "item_ids": [davao_item["id"]], "gross_grams": "10",
                                    "gross_amount_centavos": 100000, "commitment_id": company["id"]}, expect=201)
        self.post(SU, "/cash/entries", {"branch": "davao", "type": "cashIn", "amount_centavos": 5, "note": "x"},
                  expect=201)
        self.post(SU, "/users", {"name": "New Admin", "role": "admin", "pin": "2468"}, expect=201)
        self.post(SU, "/rates", {"karat": 22, "price_per_gram_centavos": 560000}, expect=201)
        self.assertEqual(self.post(SU, "/sync/import", {"version": 1, "branches": []}).status_code, 422,
                         "the import is open to a Superuser (this snapshot is just incomplete)")
        self.refusal(self.post(K_SUP, "/sync/import", {"version": 1}), 403)


class DjangoAdminAccessTests(RolesTestCase):
    def login(self, name):
        return Client().post(reverse("admin:login"), {"username": name, "password": PIN, "next": "/admin/"})

    def test_only_a_superuser_gets_into_the_admin_site(self):
        self.assertEqual(self.login("Sam Superuser").status_code, 302)
        for name in ("Arnel Javier", "Kim Supervisor", "Grace Ramos"):
            self.assertContains(self.login(name), "Only a Superuser can use the administration site")
        self.assertTrue(User.objects.get(pk=SU).is_staff)
        self.assertTrue(User.objects.get(pk=SU).is_superuser)
        self.assertFalse(User.objects.get(pk=ARNEL).is_staff)
        self.assertFalse(User.objects.get(pk=ARNEL).is_superuser)

    @override_settings(ADMIN_SITE_ROLES=frozenset({"superuser", "admin"}))
    def test_the_transition_switch_can_let_an_admin_back_in(self):
        self.assertEqual(self.login("Arnel Javier").status_code, 302)
        self.assertContains(self.login("Kim Supervisor"), "Only a Superuser")


class SetRoleTests(ApiTestCase):
    def run_command(self, *args):
        out = io.StringIO()
        call_command("set_role", *args, stdout=out, stderr=io.StringIO())
        return out.getvalue()

    def test_promotes_logs_and_is_idempotent(self):
        out = self.run_command("--id", ARNEL, "--role", "superuser")
        self.assertIn("is now Superuser", out)
        self.assertEqual(User.objects.get(pk=ARNEL).role, "superuser")
        log = self.last_log()
        self.assertEqual((log.action, log.user_id, log.record_id), ("userUpdated", ARNEL, ARNEL))
        self.assertIn({"field": "Role", "before": "Admin", "after": "Superuser"}, log.changes)
        logs = self.log_count()
        self.assertIn("already Superuser", self.run_command("--id", ARNEL, "--role", "superuser"))
        self.assertEqual(self.log_count(), logs)

    def test_a_supervisor_needs_a_branch_and_can_be_logged_under_someone_else(self):
        self.run_command("--id", GRACE, "--role", "supervisor", "--by", ARNEL)  # keeps her Kidapawan branch
        grace = User.objects.get(pk=GRACE)
        self.assertEqual((grace.role, grace.home_branch), ("supervisor", "kidapawan"))
        self.assertEqual(self.last_log().user_id, ARNEL)

    def test_refuses_rubbish(self):
        for args, message in [
            (("--id", ARNEL, "--role", "owner"), "is not a role"),
            (("--id", "USR-NOBODY", "--role", "admin"), "No user"),
            (("--id", ARNEL, "--role", "superuser", "--branch", "davao"), "works across both branches"),
            (("--id", ARNEL, "--role", "supervisor"), "works from one branch"),
            (("--id", GRACE, "--role", "cashier", "--branch", "manila"), "is not a branch"),
            (("--id", ARNEL, "--role", "cashier", "--branch", "davao"), "only active Admin"),
        ]:
            with self.assertRaisesMessage(CommandError, message):
                self.run_command(*args)
        self.assertEqual(User.objects.get(pk=ARNEL).role, "admin")


class SupervisorNotificationTests(RolesTestCase):
    def setUp(self):
        super().setUp()
        fcm.reset()
        self.sent = []
        client = mock.Mock()
        client.send.side_effect = lambda token, *a: (self.sent.append(token), fcm.SendResult(ok=True, status=200))[1]
        patcher = mock.patch("notifications.fcm.get_client", return_value=client)
        patcher.start()
        self.addCleanup(patcher.stop)
        for user_id in (ARNEL, SU, K_SUP, D_SUP, GRACE, BEN, LIZA):
            Device.objects.create(token=f"tok-{user_id}", user_id=user_id)

    def test_a_purchase_for_release_tells_the_branchs_cashiers_and_supervisor_only(self):
        with self.captureOnCommitCallbacks(execute=True):
            self.purchase()
        self.assertEqual(sorted(self.sent), sorted([f"tok-{GRACE}", f"tok-{K_SUP}"]))

    def test_a_branch_loan_tells_admins_superusers_and_that_branchs_supervisor(self):
        loan = self.loan("kidapawan")
        with self.captureOnCommitCallbacks(execute=True):
            self.post(ARNEL, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        self.assertEqual(sorted(self.sent), sorted([f"tok-{SU}", f"tok-{K_SUP}"]), "never the one who did it")

    def test_a_company_wide_loan_tells_no_supervisor(self):
        loan = self.loan(None)
        with self.captureOnCommitCallbacks(execute=True):
            self.post(SU, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        self.assertEqual(self.sent, [f"tok-{ARNEL}"])
