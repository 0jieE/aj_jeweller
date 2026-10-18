"""The Django admin site: PIN sign-in for Admins only, view-only shop records,
and staff changes that go through the same rules and log as the API."""

import json
from pathlib import Path

from django.test import Client
from django.urls import reverse

from accounts.models import User
from shop.models import TransactionLog

from .helpers import ARNEL, BEN, GRACE, PIN, ApiTestCase

FIXTURE = Path(__file__).parent / "fixtures" / "app_demo_snapshot.json"


class AdminTestCase(ApiTestCase):
    def setUp(self):
        super().setUp()
        self.browser = Client()
        response = self.browser.post(reverse("admin:login"), {"username": "Arnel Javier", "password": PIN,
                                                               "next": "/admin/"})
        self.assertEqual(response.status_code, 302, response.content[:500])


class AdminSignInTests(ApiTestCase):
    def login(self, username, pin):
        return Client().post(reverse("admin:login"), {"username": username, "password": pin, "next": "/admin/"})

    def test_an_admin_signs_in_with_name_or_id_and_pin(self):
        self.assertEqual(self.login("arnel  JAVIER", PIN).status_code, 302)
        self.assertEqual(self.login(ARNEL, PIN).status_code, 302)

    def test_branch_staff_and_wrong_pins_are_turned_away(self):
        self.assertContains(self.login("Grace Ramos", PIN), "Only an Admin can use the administration site")
        self.assertContains(self.login("Arnel Javier", "0000"), "That name and PIN don&#x27;t match")

    def test_admin_pages_need_a_sign_in(self):
        response = Client().get("/admin/")
        self.assertEqual(response.status_code, 302)
        self.assertIn("/admin/login/", response["Location"])
        self.assertEqual(Client().get("/admin").status_code, 302)


class AdminPagesTests(AdminTestCase):
    def setUp(self):
        super().setUp()
        self.post(ARNEL, "/sync/import", json.loads(FIXTURE.read_text(encoding="utf-8")), expect=200)

    def test_every_list_and_detail_page_opens(self):
        index = self.browser.get("/admin/")
        self.assertEqual(index.status_code, 200)
        for path, detail in [
            ("shop/branch", "kidapawan"), ("shop/cashentry", "CSH001"), ("shop/customer", "CUS001"),
            ("shop/purchasebatch", "A7K2M9"), ("shop/item", "X2P7LN"), ("shop/sale", "S4M2HQ"),
            ("shop/commitment", "P7B4QX"), ("shop/disposalbatch", "F6H3ZN"), ("shop/goldrate", "18"),
            ("shop/ratechange", None), ("shop/storedreceipt", None), ("shop/transactionlog", "LOG006"),
            ("accounts/user", ARNEL), ("notifications/device", None), ("notifications/pushnotification", None),
        ]:
            self.assertEqual(self.browser.get(f"/admin/{path}/").status_code, 200, path)
            if detail:
                self.assertEqual(self.browser.get(f"/admin/{path}/{detail}/change/").status_code, 200, path)
        self.assertContains(self.browser.get("/admin/shop/branch/"), "₱1,037,903.00")
        self.assertContains(self.browser.get("/admin/shop/commitment/"), "Loan Paid")

    def test_shop_records_are_view_only(self):
        self.assertEqual(self.browser.get("/admin/shop/cashentry/add/").status_code, 403)
        self.assertEqual(self.browser.get("/admin/shop/cashentry/CSH001/delete/").status_code, 403)
        before = self.browser.get("/admin/shop/cashentry/CSH001/change/")
        self.assertNotContains(before, 'type="submit" value="Save"')
        response = self.browser.post("/admin/shop/cashentry/CSH001/change/", {"amount_centavos": 1})
        self.assertEqual(response.status_code, 403)

    def test_the_log_shows_what_changed(self):
        self.assertContains(self.browser.get("/admin/shop/transactionlog/LOG048/change/"), "24K per gram")


class AdminStaffTests(AdminTestCase):
    def test_adding_a_person_goes_through_the_rules_and_is_logged(self):
        before = TransactionLog.objects.count()
        response = self.browser.post("/admin/accounts/user/add/", {
            "user_id": "", "name": "Mika Santos", "role": "cashier", "home_branch": "davao",
            "contact_number": "0917 000 1111", "pin": "2468"})
        self.assertEqual(response.status_code, 302, response.content[:2000])
        mika = User.objects.get(name="Mika Santos")
        self.assertTrue(mika.check_password("2468"))
        self.assertEqual(TransactionLog.objects.count(), before + 1)
        self.assertEqual((TransactionLog.objects.latest("received_at").action,
                          TransactionLog.objects.latest("received_at").user_id), ("userAdded", ARNEL))

    def test_a_refusal_shows_on_the_form_in_the_apps_words_and_saves_nothing(self):
        response = self.browser.post("/admin/accounts/user/add/", {
            "name": " grace  ramos ", "role": "cashier", "home_branch": "davao", "pin": "2468"})
        self.assertContains(response, "Grace Ramos is already on file")
        response = self.browser.post(f"/admin/accounts/user/{ARNEL}/change/", {
            "name": "Arnel Javier", "role": "cashier", "home_branch": "davao", "contact_number": ""})
        self.assertContains(response, "only active Admin")
        self.assertEqual(User.objects.get(pk=ARNEL).role, "admin")
        self.assertFalse(TransactionLog.objects.filter(action="userUpdated").exists())

    def test_editing_and_resetting_a_pin(self):
        response = self.browser.post(f"/admin/accounts/user/{GRACE}/change/", {
            "name": "Grace R. Ramos", "role": "cashier", "home_branch": "kidapawan", "contact_number": "",
            "new_pin": "5678"})
        self.assertEqual(response.status_code, 302, response.content[:2000])
        grace = User.objects.get(pk=GRACE)
        self.assertEqual(grace.name, "Grace R. Ramos")
        self.assertTrue(grace.check_password("5678"))
        actions = list(TransactionLog.objects.filter(record_id=GRACE).values_list("action", flat=True))
        self.assertEqual(actions, ["userUpdated", "userUpdated"], "the edit and the PIN reset are each logged")

    def test_deactivating_from_the_list(self):
        self.browser.post("/admin/accounts/user/", {"action": "deactivate", "_selected_action": [BEN]})
        self.assertFalse(User.objects.get(pk=BEN).active)
        self.assertEqual(TransactionLog.objects.get(action="userDeactivated").user_id, ARNEL)

    def test_only_someone_with_no_records_can_be_deleted(self):
        self.purchase()  # Liza and nobody else now has a record... and the log names her
        self.assertEqual(self.browser.get("/admin/accounts/user/USR-K-APR/delete/").status_code, 403)
        typo = self.post(ARNEL, "/users", {"name": "Typo Person", "role": "salesRep", "home_branch": "kidapawan",
                                           "pin": "2468"}, expect=201).data["id"]
        response = self.browser.post(f"/admin/accounts/user/{typo}/delete/", {"post": "yes"})
        self.assertEqual(response.status_code, 302)
        self.assertFalse(User.objects.filter(pk=typo).exists())
        self.assertTrue(TransactionLog.objects.filter(action="userDeleted", record_id=typo).exists())

    def test_changing_your_own_pin_from_the_admin(self):
        response = self.browser.post("/admin/password_change/", {
            "old_password": PIN, "new_password1": "8642", "new_password2": "8642"})
        self.assertEqual(response.status_code, 302, response.content[:2000])
        self.assertTrue(User.objects.get(pk=ARNEL).check_password("8642"))
        self.assertEqual(self.browser.get("/admin/").status_code, 200, "still signed in to the admin")
        response = self.browser.post("/admin/password_change/", {
            "old_password": "8642", "new_password1": "12", "new_password2": "12"})
        self.assertContains(response, "A PIN is 4 to 6 digits")
