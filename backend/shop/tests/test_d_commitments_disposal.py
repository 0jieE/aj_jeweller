"""Stage (d): commitments and disposal. Ported from the app's
commitment_repository_test, scrap_disposal_test, silver_test and the
karatBreakdown case of purchase_batch_test."""

from shop.models import CashEntry, Item
from shop.services import cash

from .helpers import ARNEL, GRACE, LIZA, RHEA, ApiTestCase, png_b64


class LoanMixin:
    def loan(self, amount=50000000, *, branch="kidapawan", received=True, rate=500000):
        commitment = self.post(ARNEL, "/commitments", {"lender": "Test Lender", "amount_centavos": amount,
                                                       "rate_per_gram_centavos": rate, "branch": branch},
                               expect=201).data
        if received:
            self.post(ARNEL, f"/commitments/{commitment['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        return commitment

    def ledger(self, commitment_id):
        return self.get(ARNEL, f"/commitments/{commitment_id}").data["ledger"]

    def dispose(self, item_ids, commitment_id, gross_amount, gross_grams="10", *, branch="kidapawan", expect=201,
                **extra):
        return self.post(ARNEL, "/disposal", {"branch": branch, "item_ids": item_ids, "gross_grams": gross_grams,
                                              "gross_amount_centavos": gross_amount, "commitment_id": commitment_id,
                                              **extra}, expect=expect)

    def scrap(self, grams="10", amount=400000, karat=18, branch="kidapawan"):
        return self.released_item(type="scrap", grams=grams, amount=amount, karat=karat, branch=branch)


class CommitmentTests(LoanMixin, ApiTestCase):
    def test_a_new_commitment_starts_pending_with_nothing_repaid(self):
        commitment = self.loan(100000000, received=False)
        ledger = commitment["ledger"]
        self.assertEqual((ledger["status"], ledger["repaid_centavos"], ledger["remaining_centavos"],
                          ledger["progress"]), ("loanPending", 0, 100000000, 0))
        self.assertEqual(ledger["total_grams_owed"], "200.000")
        self.assertEqual(self.last_log().action, "commitmentAdded")

    def test_receiving_a_branch_loan_credits_that_branchs_purchase_cash(self):
        before = cash.account_balance("davao", "purchase")
        commitment = self.loan(20000000, branch="davao", received=False)
        self.assertEqual(self.refusal(self.post(ARNEL, f"/commitments/{commitment['id']}/receive", {})),
                         "A photo of the cash received (or the lender's slip) is required")
        received = self.post(ARNEL, f"/commitments/{commitment['id']}/receive", {"proof_photo": png_b64()},
                             expect=200).data
        self.assertEqual(received["ledger"]["status"], "loanReceived")
        self.assertIsNotNone(received["date_received"])
        self.assertEqual(cash.account_balance("davao", "purchase"), before + 20000000)
        entry = CashEntry.objects.get(linked_record_id=commitment["id"])
        self.assertEqual((entry.account, entry.type, entry.source_type), ("purchase", "cashIn", "commitment"))
        self.assertEqual(self.refusal(self.post(ARNEL, f"/commitments/{commitment['id']}/receive",
                                                {"proof_photo": png_b64()})),
                         "Cash for this loan was already recorded as received")

    def test_a_company_wide_loan_records_receipt_without_crediting_any_branch(self):
        commitment = self.loan(20000000, branch=None)
        self.assertEqual(CashEntry.objects.count(), 0)
        self.assertEqual(self.ledger(commitment["id"])["status"], "loanReceived")

    def test_a_branch_sees_its_own_loans_and_the_company_wide_ones(self):
        kid = self.loan(10000000, branch="kidapawan", received=False)
        company = self.loan(10000000, branch=None, received=False)
        davao = self.loan(10000000, branch="davao", received=False)
        ids = [c["id"] for c in self.get(GRACE, "/commitments").data["results"]]
        self.assertIn(kid["id"], ids)
        self.assertIn(company["id"], ids)
        self.assertNotIn(davao["id"], ids)

    def test_only_an_admin_manages_commitments(self):
        self.refusal(self.post(GRACE, "/commitments", {"lender": "X", "amount_centavos": 1,
                                                       "rate_per_gram_centavos": 1}), 403)


class DisposalTests(LoanMixin, ApiTestCase):
    # Acceptance 5 -----------------------------------------------------------
    def test_disposal_marks_items_disposed_moves_no_cash_and_draws_down_the_commitment(self):
        a, b = self.scrap("10", 400000), self.scrap("15", 600000)
        commitment = self.loan(100000000)
        balances = {acct: cash.account_balance("kidapawan", acct) for acct in ("purchase", "sales", "bank")}
        entries = CashEntry.objects.count()

        batch = self.dispose([a["id"], b["id"]], commitment["id"], 40000000, gross_grams="25").data
        self.assertEqual((batch["capital_centavos"], batch["net_centavos"]), (1000000, 39000000))
        self.assertEqual({Item.objects.get(pk=i).item_status for i in (a["id"], b["id"])}, {"disposed"})
        self.assertEqual({acct: cash.account_balance("kidapawan", acct) for acct in balances}, balances)
        self.assertEqual(CashEntry.objects.count(), entries, "disposal moves no cash")

        ledger = self.ledger(commitment["id"])
        self.assertEqual((ledger["repaid_centavos"], ledger["remaining_centavos"], ledger["status"]),
                         (40000000, 60000000, "loanReceived"))
        self.assertAlmostEqual(ledger["progress"], 0.4)
        pool_ids = [i["id"] for i in self.get(ARNEL, "/disposal/pool", {"branch": "kidapawan"}).data["results"]]
        self.assertNotIn(a["id"], pool_ids)

        # ...and flips to paid on its own once the gross covers the balance.
        c = self.scrap("20", 800000)
        self.dispose([c["id"]], commitment["id"], 60000000)
        ledger = self.ledger(commitment["id"])
        self.assertEqual((ledger["status"], ledger["remaining_centavos"], ledger["progress"]), ("loanPaid", 0, 1.0))
        self.assertEqual(len(ledger["applied_disposal_ids"]), 2)

    def test_an_overshooting_batch_never_makes_the_balance_negative(self):
        commitment = self.loan(30000000)
        self.dispose([self.scrap()["id"]], commitment["id"], 40000000)
        ledger = self.ledger(commitment["id"])
        self.assertEqual((ledger["remaining_centavos"], ledger["status"], ledger["progress"]), (0, "loanPaid", 1.0))

    def test_only_the_named_commitment_is_touched(self):
        settled, untouched = self.loan(), self.loan()
        self.dispose([self.scrap()["id"]], settled["id"], 500000)
        self.assertEqual(self.ledger(settled["id"])["repaid_centavos"], 500000)
        self.assertEqual(self.ledger(untouched["id"])["repaid_centavos"], 0)

    def test_a_batch_must_settle_an_open_received_loan(self):
        item = self.scrap()
        self.assertEqual(self.refusal(self.dispose([item["id"]], "", 1, expect=None)),
                         "Pick the commitment this batch settles to continue.")
        pending = self.loan(received=False)
        self.assertEqual(self.refusal(self.dispose([item["id"]], pending["id"], 1, expect=None)),
                         "Only a received loan with a balance left to pay can take a disposal batch")
        davao_loan = self.loan(branch="davao")
        self.assertIn("belongs to Davao", self.refusal(self.dispose([item["id"]], davao_loan["id"], 1, expect=None)))
        self.assertEqual(Item.objects.get(pk=item["id"]).item_status, "forDisposal")

    def test_only_pieces_in_the_pool_can_be_disposed(self):
        loan = self.loan()
        goods = self.released_item(type="goods")
        self.assertEqual(self.refusal(self.dispose([goods["id"]], loan["id"], 1, expect=None)),
                         '"Test goods" is not in the disposal pool')
        scrap, silver = self.scrap(), self.released_item(type="silver", karat=925)
        self.assertEqual(self.refusal(self.dispose([scrap["id"], silver["id"]], loan["id"], 1, expect=None)),
                         "A batch is all gold scrap or all silver — not both")
        self.assertEqual(self.refusal(self.dispose([scrap["id"]], loan["id"], 1, capital_centavos=1, expect=None)),
                         "Capital does not match the selected pieces (₱4,000.00)")

    def test_the_pool_holds_a_partitioned_lot_at_its_remaining_weight_and_drops_an_exhausted_one(self):
        lot = self.scrap("20", 800000)
        self.post(LIZA, f"/items/{lot['id']}/partitions",
                  {"description": "Partial", "type": "goods", "grams": "8", "amount_centavos": 320000}, expect=201)
        found = next(i for i in self.get(ARNEL, "/disposal/pool").data["results"] if i["id"] == lot["id"])
        self.assertEqual((found["effective_remaining_grams"], found["effective_remaining_amount_centavos"]),
                         ("12.000", 480000))
        small = self.scrap("10", 400000)
        self.post(LIZA, f"/items/{small['id']}/partitions",
                  {"description": "All of it", "type": "goods", "grams": "10", "amount_centavos": 400000}, expect=201)
        self.assertNotIn(small["id"], [i["id"] for i in self.get(ARNEL, "/disposal/pool").data["results"]])

    def test_karat_breakdown_is_grams_per_purity_highest_first(self):
        loan = self.loan()
        a, b, c = self.scrap("10", 400000, 18), self.scrap("5", 200000, 18), self.scrap("7", 350000, 21)
        batch = self.dispose([a["id"], b["id"], c["id"]], loan["id"], 1200000, gross_grams="22").data
        self.assertEqual([(k["karat"], k["grams"]) for k in batch["karat_breakdown"]], [(21, "7.000"), (18, "15.000")])

    def test_released_silver_can_be_disposed_and_that_takes_it_off_the_sell_list(self):
        silver = self.released_item(type="silver", karat=925, grams="30", amount=180000)
        pool = [i["id"] for i in self.get(ARNEL, "/disposal/pool", {"silver": "true"}).data["results"]]
        self.assertIn(silver["id"], pool)
        self.assertNotIn(silver["id"], [i["id"] for i in self.get(ARNEL, "/disposal/pool").data["results"]],
                         "the gold scrap pool stays gold")
        loan = self.loan(1000000, rate=6000)
        self.dispose([silver["id"]], loan["id"], 140000, gross_grams="30")
        self.assertEqual(Item.objects.get(pk=silver["id"]).item_status, "disposed")
        self.assertNotIn(silver["id"], [i["id"] for i in self.get(RHEA, "/items/sellable").data["results"]])

    def test_silver_held_in_an_order_cannot_be_disposed(self):
        silver = self.released_item(type="silver", karat=999)
        self.post(RHEA, f"/items/{silver['id']}/reserve", expect=200)
        self.assertNotIn(silver["id"],
                         [i["id"] for i in self.get(ARNEL, "/disposal/pool", {"silver": "true"}).data["results"]])

    def test_only_an_admin_runs_disposal(self):
        loan = self.loan()
        response = self.post(GRACE, "/disposal", {"branch": "kidapawan", "item_ids": [self.scrap()["id"]],
                                                  "gross_grams": "1", "gross_amount_centavos": 1,
                                                  "commitment_id": loan["id"]})
        self.assertEqual(self.refusal(response, 403), "Only an Admin can run disposal")
