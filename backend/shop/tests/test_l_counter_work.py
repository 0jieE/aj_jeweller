"""Counter work is shared by everybody; running a branch is not.

Any role may encode a purchase, build an order, release the cash and receive
payment — at their own branch. The cash ledger (the shop's own money) belongs
to a Supervisor at their branch and to an Admin or Superuser at both.
"""

from unittest import mock

from notifications import fcm
from notifications.models import Device
from shop.models import CashEntry, PurchaseBatch, Sale

from .helpers import ARNEL, BEN, D_SUP, GRACE, JOEL, K_SUP, LIZA, PAOLO, RHEA, ApiTestCase, png_b64

LEDGER_REFUSAL = "Only a Supervisor or Admin can"


class CounterWorkIsSharedTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        self.add_supervisors()

    def test_a_sales_rep_releases_a_purchase_and_the_record_names_them(self):
        batch = self.purchase().data
        released = self.release(batch["id"], by=RHEA).data
        self.assertEqual(released["released_by"]["id"], RHEA)
        self.assertEqual(PurchaseBatch.objects.get(pk=batch["id"]).released_by_id, RHEA)
        entry = CashEntry.objects.get(linked_record_id=batch["id"])
        self.assertEqual((entry.recorded_by_id, entry.recorded_by_role, entry.account), (RHEA, "salesRep", "purchase"))
        log = self.last_log()
        self.assertEqual((log.action, log.user_id, log.role), ("cashReleased", RHEA, "salesRep"))

    def test_an_appraiser_receives_payment_on_an_order(self):
        item = self.released_item()
        sale = self.post(RHEA, "/sales", {"branch": "kidapawan", "customer": {"name": "Teresa Lim"},
                                          "lines": [{"item_id": item["id"], "negotiated_price_centavos": 900000}]},
                         expect=201).data
        done = self.post(LIZA, f"/sales/{sale['id']}/complete", {"cash_centavos": 900000, "bank_centavos": 0},
                         expect=200).data
        self.assertEqual(done["received_by"]["id"], LIZA)
        self.assertEqual(Sale.objects.get(pk=sale["id"]).received_by_id, LIZA)

    def test_a_cashier_encodes_a_purchase_and_builds_an_order(self):
        batch = self.purchase(by=GRACE).data
        self.assertEqual(batch["submitted_by"]["id"], GRACE)
        self.release(batch["id"], by=GRACE)
        sale = self.post(GRACE, "/sales", {"branch": "kidapawan", "customer": {"name": "Buyer"},
                                           "lines": [{"item_id": batch["items"][0]["id"],
                                                      "negotiated_price_centavos": 600000}]}, expect=201).data
        self.assertEqual(sale["submitted_by"]["id"], GRACE)
        # Returning either for correction is counter work too.
        self.post(LIZA, f"/sales/{sale['id']}/return", {"note": "Price"}, expect=200)
        other = self.purchase(by=RHEA).data
        self.post(LIZA, f"/purchases/{other['id']}/return", {"note": "Weight"}, expect=200)

    def test_shared_counter_work_never_reaches_into_the_other_branch(self):
        self.refusal(self.purchase(by=JOEL, branch="kidapawan", expect=None), 403)
        batch = self.purchase().data
        self.assertIn("You work from Davao", self.refusal(self.release(batch["id"], by=PAOLO, expect=None), 403))
        item = self.released_item()
        self.refusal(self.post(BEN, "/sales", {"branch": "kidapawan", "customer": {"name": "B"},
                                               "lines": [{"item_id": item["id"],
                                                          "negotiated_price_centavos": 1}]}), 403)


class CashLedgerIsTheBranchsTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        self.add_supervisors()

    def test_a_supervisor_records_at_their_own_branch_and_is_refused_at_the_other(self):
        entry = self.post(K_SUP, "/cash/entries", {"type": "cashIn", "amount_centavos": 5000, "note": "Float"},
                          expect=201).data
        self.assertEqual(entry["branch"], "kidapawan")
        self.assertIn("You work from Kidapawan",
                      self.refusal(self.post(K_SUP, "/cash/entries", {"branch": "davao", "type": "cashIn",
                                                                      "amount_centavos": 5, "note": "x"}), 403))

    def test_counter_staff_are_refused_every_part_of_the_cash_ledger(self):
        existing = self.post(K_SUP, "/cash/entries", {"type": "expense", "amount_centavos": 5000, "note": "Bulbs",
                                                      "category": "Supplies"}, expect=201).data
        pair = self.post(K_SUP, "/cash/transfers", {"to_branch": "davao", "amount_centavos": 100, "note": "Float"},
                         expect=201).data
        before = CashEntry.objects.count()
        for person in (GRACE, LIZA, RHEA):
            attempts = [
                self.post(person, "/cash/entries", {"type": "cashIn", "amount_centavos": 5, "note": "x"}),
                self.post(person, "/cash/entries", {"type": "expense", "amount_centavos": 5, "note": "x",
                                                    "category": "Other"}),
                self.post(person, "/cash/entries", {"type": "withdrawal", "amount_centavos": 5, "note": "x"}),
                self.post(person, "/cash/transfers", {"to_branch": "davao", "amount_centavos": 5, "note": "x"}),
                self.patch(person, f"/cash/entries/{existing['id']}", {"amount_centavos": 6}),
                self.delete(person, f"/cash/entries/{existing['id']}", {"reason": "x"}),
                self.patch(person, f"/cash/entries/{pair['in']['id']}", {"amount_centavos": 6}),
                self.delete(person, f"/cash/entries/{pair['out']['id']}"),
            ]
            for response in attempts:
                self.assertTrue(self.refusal(response, 403).startswith(LEDGER_REFUSAL), (person, response.data))
        self.assertEqual(CashEntry.objects.count(), before)
        self.assertEqual(CashEntry.objects.get(pk=existing["id"]).amount_centavos, 5000)

    def test_the_admin_still_keeps_the_ledger_at_both_branches(self):
        self.post(ARNEL, "/cash/entries", {"branch": "davao", "type": "cashIn", "amount_centavos": 5, "note": "x"},
                  expect=201)
        self.post(D_SUP, "/cash/entries", {"type": "cashIn", "amount_centavos": 5, "note": "x"}, expect=201)


class RunningTheBranchIsNotSharedTests(ApiTestCase):
    """Everything that was BRANCH_MANAGERS or ADMIN_ONLY still refuses where it should."""

    def setUp(self):
        super().setUp()
        self.add_supervisors()

    def test_branch_management_refuses_every_counter_role(self):
        item = self.released_item(type="scrap")
        lot = self.released_item(type="scrap", grams="20", amount=800000)
        piece = self.post(LIZA, f"/items/{lot['id']}/partitions", {"description": "P", "type": "goods",
                                                                  "grams": "5", "amount_centavos": 200000},
                          expect=201).data
        loan = self.post(K_SUP, "/commitments", {"lender": "L", "amount_centavos": 5000000,
                                                 "rate_per_gram_centavos": 500000, "branch": "kidapawan"},
                         expect=201).data
        for person in (GRACE, LIZA, RHEA):
            for response in (
                self.patch(person, f"/items/{item['id']}", {"description": "x"}),
                self.delete(person, f"/partitions/{piece['id']}"),
                self.post(person, "/disposal", {"item_ids": [item["id"]], "gross_grams": "1",
                                                "gross_amount_centavos": 1, "commitment_id": loan["id"]}),
                self.post(person, "/commitments", {"lender": "L", "amount_centavos": 1, "rate_per_gram_centavos": 1,
                                                   "branch": "kidapawan"}),
                self.post(person, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}),
                self.post(person, "/users", {"name": "Hire", "role": "cashier", "home_branch": "kidapawan",
                                             "pin": "2468"}),
                self.post(person, "/sync/import", {"version": 1}),
            ):
                self.refusal(response, 403)

    def test_admin_only_actions_still_refuse_a_supervisor(self):
        company = self.post(K_SUP, "/commitments", {"lender": "Company", "amount_centavos": 1,
                                                    "rate_per_gram_centavos": 1})
        self.refusal(company, 403)
        self.refusal(self.post(K_SUP, "/sync/import", {"version": 1}), 403)
        self.refusal(self.post(K_SUP, "/users", {"name": "A", "role": "admin", "pin": "2468"}), 403)


class NotificationsFollowResponsibilityTests(ApiTestCase):
    """Who is notified follows responsibility, not who happened to do the work."""

    def setUp(self):
        super().setUp()
        self.add_supervisors()
        fcm.reset()
        self.sent = []
        client = mock.Mock()
        client.send.side_effect = lambda token, *a: (self.sent.append(token), fcm.SendResult(ok=True, status=200))[1]
        patcher = mock.patch("notifications.fcm.get_client", return_value=client)
        patcher.start()
        self.addCleanup(patcher.stop)
        for user_id in (ARNEL, GRACE, LIZA, RHEA, BEN, K_SUP, D_SUP):
            Device.objects.create(token=f"tok-{user_id}", user_id=user_id)

    def test_a_purchase_for_release_tells_the_branchs_cashiers_and_supervisor_even_from_a_sales_rep(self):
        with self.captureOnCommitCallbacks(execute=True):
            self.purchase(by=RHEA)
        self.assertEqual(sorted(self.sent), sorted([f"tok-{GRACE}", f"tok-{K_SUP}"]))

    def test_never_whoever_did_it(self):
        with self.captureOnCommitCallbacks(execute=True):
            self.purchase(by=GRACE)
        self.assertEqual(self.sent, [f"tok-{K_SUP}"])
