"""Stage (a): signing in with a PIN, staff management, branches."""

from django.core.management import call_command
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from accounts.models import User
from shop.models import TransactionLog

from .helpers import API, ARNEL, BEN, GRACE, LIZA, PIN, RHEA, ApiTestCase


class SignInTests(ApiTestCase):
    def login(self, **body):
        return APIClient().post(f"{API}/auth/login", body, format="json")

    def test_name_and_pin_sign_in_returns_tokens_and_the_person(self):
        response = self.login(name="  grace   RAMOS ", pin=PIN)
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["user"]["id"], GRACE)
        self.assertIn("access", response.data)
        self.assertIn("refresh", response.data)

        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {response.data['access']}")
        self.assertEqual(client.get(f"{API}/me").data["name"], "Grace Ramos")

    def test_a_wrong_pin_is_refused_without_saying_which_part_was_wrong(self):
        response = self.login(name="Grace Ramos", pin="9999")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.data["error"]["message"], "That name and PIN don't match")
        self.assertEqual(self.login(name="Nobody Here", pin=PIN).data["error"]["message"],
                         "That name and PIN don't match")

    @override_settings(PIN_MAX_ATTEMPTS=3)
    def test_repeated_wrong_pins_lock_the_sign_in(self):
        for _ in range(3):
            self.login(name="Grace Ramos", pin="0000")
        response = self.login(name="Grace Ramos", pin=PIN)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.data["error"]["code"], "locked")

    def test_a_deactivated_person_cannot_sign_in_or_keep_using_a_token(self):
        client = self.api(BEN)
        self.post(ARNEL, f"/users/{BEN}/deactivate", expect=200)
        self.assertEqual(self.login(name="Ben Soriano", pin=PIN).status_code, 403)
        self.assertEqual(client.get(f"{API}/me").status_code, 401)

    def test_resetting_a_pin_signs_the_person_out_everywhere(self):
        old = self.api(GRACE)
        self.assertEqual(old.get(f"{API}/me").status_code, 200)
        self.post(ARNEL, f"/users/{GRACE}/pin", {"pin": "5678"}, expect=200)
        self.assertEqual(old.get(f"{API}/me").status_code, 401)
        self.assertEqual(self.login(name="Grace Ramos", pin="5678").status_code, 200)

    def test_changing_your_own_pin_needs_the_current_one(self):
        self.refusal(self.post(GRACE, "/me/pin", {"current_pin": "0000", "new_pin": "4321"}))
        response = self.post(GRACE, "/me/pin", {"current_pin": PIN, "new_pin": "4321"}, expect=200)
        self.assertIn("access", response.data)
        self.assertEqual(self.login(name="Grace Ramos", pin="4321").status_code, 200)

    def test_a_pin_is_four_to_six_digits(self):
        self.assertEqual(self.refusal(self.post(ARNEL, f"/users/{GRACE}/pin", {"pin": "12"})),
                         "A PIN is 4 to 6 digits")
        self.refusal(self.post(ARNEL, f"/users/{GRACE}/pin", {"pin": "abcd"}))

    def test_every_request_needs_a_signed_in_person(self):
        self.assertEqual(APIClient().get(f"{API}/branches").status_code, 401)
        self.assertEqual(APIClient().post(f"{API}/purchases", {}, format="json").status_code, 401)

    def test_the_staff_picker_lists_active_people_without_signing_in(self):
        names = [p["name"] for p in APIClient().get(f"{API}/auth/staff").data]
        self.assertIn("Grace Ramos", names)
        self.assertEqual(len(names), 7)


class StaffManagementTests(ApiTestCase):
    def test_adding_a_user_logs_it_under_the_admin(self):
        before = self.log_count()
        response = self.post(ARNEL, "/users", {"name": "Mika Santos", "role": "cashier", "home_branch": "davao",
                                               "contact_number": "0917 000 1111", "pin": "2468"}, expect=201)
        self.assertTrue(response.data["id"].startswith("USR-"))
        self.assertEqual(self.log_count(), before + 1)
        log = self.last_log()
        self.assertEqual((log.action, log.user_id, log.record_kind), ("userAdded", ARNEL, "user"))

    def test_names_must_be_unique_and_branch_staff_need_a_branch(self):
        self.assertEqual(
            self.refusal(self.post(ARNEL, "/users", {"name": " grace  ramos ", "role": "cashier",
                                                     "home_branch": "davao", "pin": "2468"})),
            "Grace Ramos is already on file")
        self.assertEqual(
            self.refusal(self.post(ARNEL, "/users", {"name": "No Branch", "role": "salesRep", "pin": "2468"})),
            "A Sales Rep works from one branch — pick it")
        self.assertEqual(self.refusal(self.post(ARNEL, "/users", {"name": "  ", "role": "admin", "pin": "2468"})),
                         "A user needs a name")

    def test_only_an_admin_or_supervisor_manages_staff(self):
        message = self.refusal(self.post(GRACE, "/users", {"name": "X", "role": "admin", "pin": "2468"}), 403)
        self.assertEqual(message, "Only a Supervisor or Admin can manage staff")

    def test_editing_a_user_records_before_and_after(self):
        response = self.patch(ARNEL, f"/users/{GRACE}", {"name": "Grace R. Ramos", "home_branch": "davao"},
                              expect=200)
        fields = [c["field"] for c in response.data["changes"]]
        self.assertEqual(fields, ["Name", "Branch"])
        log = self.last_log()
        self.assertEqual(log.action, "userUpdated")
        self.assertEqual(log.changes[0], {"field": "Name", "before": "Grace Ramos", "after": "Grace R. Ramos"})

    def test_the_last_active_admin_cannot_be_demoted_deactivated_or_deleted(self):
        self.assertEqual(
            self.refusal(self.patch(ARNEL, f"/users/{ARNEL}", {"role": "cashier", "home_branch": "davao"})),
            "Arnel Javier is the only active Admin — make someone else Admin first")
        # Deactivating needs another admin to do it, and is still refused.
        second = self.post(ARNEL, "/users", {"name": "Second Admin", "role": "admin", "pin": "2468"},
                           expect=201).data["id"]
        self.post(ARNEL, f"/users/{second}/deactivate", expect=200)
        self.assertEqual(self.refusal(self.post(ARNEL, f"/users/{ARNEL}/deactivate")),
                         "You can't deactivate yourself — switch to another Admin first")
        self.assertEqual(self.refusal(self.delete(ARNEL, f"/users/{ARNEL}")), "You can't delete yourself")
        self.assertTrue(User.objects.get(pk=ARNEL).active)

    def test_the_last_admin_cannot_be_deactivated_by_anyone(self):
        # Two admins; one deactivates the other, leaving one — who then can't go.
        second = self.post(ARNEL, "/users", {"name": "Second Admin", "role": "admin", "pin": "2468"},
                           expect=201).data["id"]
        self.post(second, f"/users/{ARNEL}/deactivate", expect=200)
        self.post(second, f"/users/{ARNEL}/reactivate", expect=200)
        self.post(ARNEL, f"/users/{second}/deactivate", expect=200)
        self.assertEqual(self.refusal(self.delete(ARNEL, f"/users/{ARNEL}")), "You can't delete yourself")

    def test_someone_on_a_record_must_be_deactivated_not_deleted(self):
        self.purchase(by=LIZA)
        response = self.delete(ARNEL, f"/users/{LIZA}")
        message = self.refusal(response)
        self.assertIn("Deactivate them instead", message)
        self.assertGreater(response.data["error"]["record_count"], 0)

        mistake = self.post(ARNEL, "/users", {"name": "Typo Person", "role": "salesRep", "home_branch": "kidapawan",
                                              "pin": "2468"}, expect=201).data["id"]
        self.delete(ARNEL, f"/users/{mistake}", expect=204)
        self.assertFalse(User.objects.filter(pk=mistake).exists())
        self.assertEqual(self.last_log().action, "userDeleted")

    def test_a_deactivated_user_still_names_their_records(self):
        self.purchase(by=LIZA)
        self.post(ARNEL, f"/users/{LIZA}/deactivate", expect=200)
        purchases = self.get(ARNEL, "/purchases").data["results"]
        self.assertEqual(purchases[0]["submitted_by"]["name"], "Liza Mendoza")


class BranchTests(ApiTestCase):
    def test_admin_sees_both_branches_with_three_balances_each(self):
        data = self.get(ARNEL, "/branches").data
        self.assertEqual([b["id"] for b in data], ["davao", "kidapawan"])
        self.assertEqual(set(data[0]["accounts"]), {"purchase", "sales", "bank"})

    def test_branch_staff_see_their_own_branch_only(self):
        data = self.get(RHEA, "/branches").data
        self.assertEqual([b["id"] for b in data], ["kidapawan"])
        self.refusal(self.get(RHEA, "/branches", {"branch": "davao"}, expect=None), 403)


class BootstrapAdminTests(TestCase):
    def test_creates_the_first_admin_once_and_logs_it(self):
        call_command("bootstrap_admin", name="Arnel Javier", pin="1234")
        user = User.objects.get(pk="USR-AJ01")
        self.assertTrue(user.check_password("1234"))
        self.assertEqual(TransactionLog.objects.get().user_id, "USR-AJ01")
        from django.core.management.base import CommandError

        with self.assertRaises(CommandError):
            call_command("bootstrap_admin", name="Someone Else", pin="1234", id="USR-AJ02")
