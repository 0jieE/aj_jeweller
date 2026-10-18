"""Stage (e): rates and rate history, receipts, the transaction log, exports,
and acceptance check 9 across every mutating endpoint."""

import csv
import io
from datetime import timedelta

from django.db import DatabaseError, transaction
from django.utils import timezone

from shop.models import GoldRate, RateChange, StoredReceipt, TransactionLog

from .helpers import ARNEL, BEN, GRACE, LIZA, RHEA, ApiTestCase, png_b64

PRICES = {24: 615000, 22: 563800, 21: 538100, 20: 512500, 18: 461300, 14: 358800, 10: 256300, 999: 7500, 925: 6500}


def seed_rates():
    """The app's seed: each rate first set a month ago, nudged two weeks ago,
    and today's figure two hours back."""
    now = timezone.now()
    for karat, current in PRICES.items():
        first = round(current * 0.96 / 100) * 100
        second = round(current * 0.98 / 100) * 100
        GoldRate.objects.create(karat=karat, price_per_gram_centavos=current, updated_at=now - timedelta(hours=2))
        RateChange.objects.create(karat=karat, after_centavos=first, at=now - timedelta(days=30),
                                  user_id=ARNEL, user_name="Arnel Javier")
        RateChange.objects.create(karat=karat, before_centavos=first, after_centavos=second,
                                  at=now - timedelta(days=14), user_id=ARNEL, user_name="Arnel Javier")
        RateChange.objects.create(karat=karat, before_centavos=second, after_centavos=current,
                                  at=now - timedelta(hours=2), user_id=ARNEL, user_name="Arnel Javier")


class RateTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        seed_rates()

    def history(self, karat):
        return self.get(ARNEL, "/rates/history", {"karat": karat}).data["results"]

    def test_gold_and_silver_are_listed_separately_highest_first(self):
        data = self.get(RHEA, "/rates").data
        self.assertEqual([r["karat"] for r in data["silver"]], [999, 925])
        self.assertEqual([r["karat"] for r in data["gold"]], [24, 22, 21, 20, 18, 14, 10])

    def test_adding_a_new_karat_and_a_new_fineness(self):
        self.post(ARNEL, "/rates", {"karat": 16, "price_per_gram_centavos": 400000}, expect=201)
        self.post(ARNEL, "/rates", {"karat": 950, "price_per_gram_centavos": 7000, "silver": True}, expect=201)
        self.assertEqual(self.last_log().action, "goldRateAdded")
        history = self.history(16)
        self.assertEqual(len(history), 1)
        self.assertTrue(history[0]["is_initial"])

    def test_one_rate_per_purity_within_its_metals_range(self):
        self.assertEqual(self.refusal(self.post(ARNEL, "/rates", {"karat": 18, "price_per_gram_centavos": 500000})),
                         "18K already has a rate — edit its price instead")
        self.assertEqual(self.refusal(self.post(ARNEL, "/rates", {"karat": 925, "price_per_gram_centavos": 7000})),
                         "925 silver already has a rate — edit its price instead")
        self.assertEqual(self.refusal(self.post(ARNEL, "/rates", {"karat": 25, "price_per_gram_centavos": 1,
                                                                  "silver": False})), "Gold karat is 1 to 24")
        self.assertEqual(self.refusal(self.post(ARNEL, "/rates", {"karat": 50, "price_per_gram_centavos": 1,
                                                                  "silver": True})),
                         "Silver fineness is 100 to 999 (e.g. 925)")
        self.assertEqual(self.refusal(self.post(ARNEL, "/rates", {"karat": 16, "price_per_gram_centavos": 0})),
                         "A rate must be above zero")
        self.assertEqual(GoldRate.objects.get(pk=18).price_per_gram_centavos, 461300)
        self.refusal(self.post(GRACE, "/rates", {"karat": 16, "price_per_gram_centavos": 1}), 403)

    def test_an_edit_is_recorded_with_before_after_and_who(self):
        count = len(self.history(18))
        response = self.patch(ARNEL, "/rates/18", {"price_per_gram_centavos": 466300}, expect=200).data
        self.assertTrue(response["changed"])
        history = self.history(18)
        self.assertEqual(len(history), count + 1)
        self.assertEqual((history[0]["before_centavos"], history[0]["after_centavos"], history[0]["delta_centavos"],
                          history[0]["user"]["id"]), (461300, 466300, 5000, ARNEL))
        log = self.last_log()
        self.assertEqual(log.summary, "18K rate changed from ₱4,613.00 to ₱4,663.00 per gram")
        self.assertEqual(log.changes, [{"field": "18K per gram", "before": "₱4,613.00", "after": "₱4,663.00"}])

    def test_saving_the_same_price_adds_nothing(self):
        count, logs = len(self.history(24)), self.log_count()
        self.assertFalse(self.patch(ARNEL, "/rates/24", {"price_per_gram_centavos": 615000}, expect=200).data["changed"])
        self.assertEqual((len(self.history(24)), self.log_count()), (count, logs))

    def test_rates_on_a_day_read_the_price_at_its_close(self):
        today = timezone.localdate()
        two_weeks = today - timedelta(days=14)
        def price_on(day, karat=18):
            rates = self.get(GRACE, f"/rates/on/{day.isoformat()}").data["rates"]
            return next(r["price_per_gram_centavos"] for r in rates if r["karat"] == karat)
        self.assertEqual(price_on(today), 461300)
        self.assertEqual(price_on(two_weeks), round(461300 * 0.98 / 100) * 100)
        self.assertEqual(price_on(two_weeks - timedelta(days=1)), round(461300 * 0.96 / 100) * 100)
        self.assertIsNone(price_on(today - timedelta(days=31)))

    def test_applying_a_days_table_sets_every_gold_rate_and_leaves_silver_alone(self):
        day = timezone.localdate() - timedelta(days=14)
        silver_before = {r.karat: r.price_per_gram_centavos for r in GoldRate.objects.filter(karat__gte=100)}
        logs = self.log_count()
        changed = self.post(ARNEL, "/rates/apply", {"date": day.isoformat(), "silver": False}, expect=200).data
        self.assertEqual(changed["changed"], 7)
        for rate in GoldRate.objects.filter(karat__lt=100):
            self.assertEqual(rate.price_per_gram_centavos, round(PRICES[rate.karat] * 0.98 / 100) * 100)
            self.assertEqual(RateChange.objects.filter(karat=rate.karat).order_by("-at").first().restored_from, day)
        self.assertEqual({r.karat: r.price_per_gram_centavos for r in GoldRate.objects.filter(karat__gte=100)},
                         silver_before)
        self.assertEqual(self.log_count(), logs + 1, "one log row for the whole table")
        self.assertEqual(len(self.last_log().changes), 7)

    def test_applying_todays_rates_changes_nothing(self):
        count = RateChange.objects.count()
        self.assertEqual(self.post(ARNEL, "/rates/apply", {"date": timezone.localdate().isoformat()},
                                   expect=200).data["changed"], 0)
        self.assertEqual(RateChange.objects.count(), count)

    def test_a_rate_not_yet_set_on_the_chosen_day_is_left_alone(self):
        self.post(ARNEL, "/rates", {"karat": 16, "price_per_gram_centavos": 400000}, expect=201)
        self.post(ARNEL, "/rates/apply", {"date": (timezone.localdate() - timedelta(days=14)).isoformat()}, expect=200)
        self.assertEqual(GoldRate.objects.get(pk=16).price_per_gram_centavos, 400000)

    def test_the_rate_history_cannot_be_rewritten(self):
        row = RateChange.objects.first()
        with self.assertRaises(DatabaseError), transaction.atomic():
            RateChange.objects.filter(pk=row.pk).update(after_centavos=1)
        with self.assertRaises(DatabaseError), transaction.atomic():
            RateChange.objects.filter(pk=row.pk).delete()


class ReceiptTests(ApiTestCase):
    def test_a_purchase_receipt_is_issued_once_cash_is_released(self):
        batch = self.post(LIZA, "/purchases", {"branch": "kidapawan",
                                               "customer": {"name": "Maria Santos", "contact_number": "0917 555 0142"},
                                               "lines": [{"description": "22K gold necklace, rope chain",
                                                          "weight_grams": "15.750", "gross_weight_grams": "16.400",
                                                          "karat": 22, "type": "goods",
                                                          "amount_centavos": 8200000}]}, expect=201).data
        self.assertEqual(self.refusal(self.post(GRACE, "/receipts", {"record_id": batch["id"]})),
                         "The receipt is issued once a Cashier releases the cash.")
        self.release(batch["id"])
        receipt = self.post(GRACE, "/receipts", {"record_id": batch["id"], "kind": "purchase"}, expect=201).data
        self.assertEqual((receipt["kind"], receipt["counterparty"], receipt["total_centavos"]),
                         ("purchase", "Maria Santos", 8200000))
        lines = receipt["text"].splitlines()
        self.assertEqual(lines[:4], ["AJ JEWELER", "Kidapawan Branch", "PURCHASE RECEIPT", f"Receipt No. {batch['id']}"])
        self.assertIn("Sold to us by: Maria Santos", lines)
        self.assertIn("0917 555 0142", lines)
        self.assertIn("  22K · 15.750g net — ₱82,000.00", lines)
        self.assertEqual(lines[-2:], ["TOTAL PAID: ₱82,000.00", "Cash released by Grace Ramos."])

        pdf = self.api(GRACE).get(f"/api/v1/receipts/{receipt['id']}/pdf")
        self.assertEqual(pdf.status_code, 200)
        self.assertTrue(b"".join(pdf.streaming_content).startswith(b"%PDF"))

    def test_reissuing_replaces_the_document_and_keeps_the_receipt(self):
        item = self.released_item()
        sale = self.post(RHEA, "/sales", {"branch": "kidapawan", "customer": {"name": "Teresa Lim"},
                                          "lines": [{"item_id": item["id"], "negotiated_price_centavos": 1000000,
                                                     "final_grams": "9.9"}]}, expect=201).data
        self.assertEqual(self.refusal(self.post(GRACE, "/receipts", {"record_id": sale["id"]})),
                         "The receipt is issued once payment is received.")
        self.post(GRACE, f"/sales/{sale['id']}/complete", {"cash_centavos": 400000, "bank_centavos": 600000},
                  expect=200)
        first = self.post(GRACE, "/receipts", {"record_id": sale["id"]}, expect=201).data
        self.assertIn("  18K · 9.900g — ₱10,000.00", first["text"].splitlines())
        self.assertIn("Cash: ₱4,000.00", first["text"])
        self.assertIn("Bank transfer: ₱6,000.00", first["text"])
        again = self.post(GRACE, "/receipts", {"record_id": sale["id"]}, expect=201).data
        self.assertEqual(again["id"], first["id"])
        self.assertEqual(StoredReceipt.objects.count(), 1)
        self.assertIn("Re-issued", self.last_log().summary)

    def test_receipts_are_scoped_to_the_branch(self):
        item = self.released_item()
        batch_id = item["batch_id"]
        self.post(GRACE, "/receipts", {"record_id": batch_id}, expect=201)
        self.assertEqual(self.get(BEN, "/receipts").data["count"], 0)
        self.refusal(self.get(BEN, f"/receipts/{batch_id}", expect=None), 403)


class LogTests(ApiTestCase):
    def test_a_branch_view_keeps_company_wide_entries_in_sight(self):
        seed_rates()
        self.patch(ARNEL, "/rates/18", {"price_per_gram_centavos": 470000}, expect=200)
        self.purchase()
        actions = [entry["action"] for entry in self.get(BEN, "/logs").data["results"]]
        self.assertIn("goldRateUpdated", actions)
        self.assertNotIn("purchaseRecorded", actions, "a Kidapawan purchase is not Davao's business")

    def test_logs_filter_by_category_user_record_and_text(self):
        batch = self.purchase().data
        self.release(batch["id"])
        story = self.get(ARNEL, "/logs", {"record": batch["id"]}).data["results"]
        self.assertEqual([e["action"] for e in story], ["cashReleased", "purchaseRecorded"])
        self.assertEqual([e["user_name"] for e in story], ["Grace Ramos", "Liza Mendoza"])
        self.assertEqual(self.get(ARNEL, "/logs", {"user": GRACE}).data["count"], 1)
        self.assertEqual(self.get(ARNEL, "/logs", {"category": "purchase"}).data["count"], 2)
        self.assertEqual(self.get(ARNEL, "/logs", {"q": "Released ₱5,000.00"}).data["count"], 1)

    def test_the_log_is_append_only_in_the_database(self):
        self.purchase()
        row = TransactionLog.objects.first()
        with self.assertRaises(DatabaseError), transaction.atomic():
            TransactionLog.objects.filter(pk=row.pk).update(summary="quietly corrected")
        with self.assertRaises(DatabaseError), transaction.atomic():
            TransactionLog.objects.filter(pk=row.pk).delete()
        with self.assertRaises(RuntimeError):
            row.save()


class ExportTests(ApiTestCase):
    def test_purchases_export_as_csv_with_the_apps_columns(self):
        batch = self.purchase(customer="Maria Santos").data
        self.release(batch["id"])
        response = self.api(ARNEL).get("/api/v1/exports/purchases", {"format": "csv"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.content.startswith(b"\xef\xbb\xbf"), "Excel needs the byte-order mark")
        rows = list(csv.reader(io.StringIO(response.content.decode("utf-8-sig"))))
        self.assertEqual(rows[0][:4], ["Date", "Purchase ID", "Item ID", "Branch"])
        self.assertEqual(rows[1][1], batch["id"])
        self.assertEqual(rows[1][11], "5000.00")
        self.assertEqual(rows[1][-1], "Grace Ramos")
        self.assertEqual(response["X-Total-Centavos"], "500000")
        self.assertIn("aj-jeweler_purchases_all-branches_all-dates.csv", response["Content-Disposition"])

    def test_expenses_export_as_xlsx_and_pdf(self):
        self.post(GRACE, "/cash/entries", {"type": "expense", "amount_centavos": 120000, "note": "Electric bill",
                                           "category": "Utilities"}, expect=201)
        xlsx = self.api(GRACE).get("/api/v1/exports/expenses", {"format": "xlsx"})
        self.assertEqual(xlsx.status_code, 200)
        self.assertTrue(xlsx.content.startswith(b"PK"))
        pdf = self.api(GRACE).get("/api/v1/exports/expenses", {"format": "pdf"})
        self.assertTrue(pdf.content.startswith(b"%PDF"))
        self.assertEqual(self.api(GRACE).get("/api/v1/exports/nonsense").status_code, 404)


class EveryMutationLogsOnceTests(ApiTestCase):
    """Acceptance 9: every mutation writes exactly one log row naming the actor,
    and corrections carry before/after values."""

    CORRECTIONS = {"itemEdited", "cashEntryEdited", "userUpdated", "customerUpdated", "goldRateUpdated",
                   "purchaseResubmitted", "saleResubmitted", "cashEntryDeleted"}

    def step(self, actor, method, path, body=None, expect=None):
        before = self.log_count()
        call = {"post": self.post, "patch": self.patch, "put": self.put, "delete": self.delete}[method]
        response = call(actor, path, body or {})
        self.assertLess(response.status_code, 300, (path, getattr(response, "data", None)))
        self.assertEqual(self.log_count(), before + 1, f"{method.upper()} {path} must write exactly one log row")
        log = self.last_log()
        self.assertEqual(log.user_id, actor, path)
        self.assertEqual(log.user_name, self.staff[actor].name, path)
        self.assertTrue(log.summary, path)
        if expect:
            self.assertEqual(log.action, expect, path)
        if log.action in self.CORRECTIONS:
            self.assertTrue(log.changes, f"{log.action} must carry before/after values")
            for c in log.changes:
                self.assertEqual(set(c), {"field", "before", "after"})
        return response.data if response.status_code != 204 else None

    def test_every_mutating_endpoint(self):
        seed_rates()
        s = self.step
        user = s(ARNEL, "post", "/users", {"name": "Mika Santos", "role": "cashier", "home_branch": "davao",
                                           "pin": "2468"}, "userAdded")
        s(ARNEL, "patch", f"/users/{user['id']}", {"contact_number": "0917"}, "userUpdated")
        s(ARNEL, "post", f"/users/{user['id']}/pin", {"pin": "1357"}, "userUpdated")
        s(ARNEL, "post", f"/users/{user['id']}/deactivate", None, "userDeactivated")
        s(ARNEL, "post", f"/users/{user['id']}/reactivate", None, "userReactivated")
        s(ARNEL, "delete", f"/users/{user['id']}", None, "userDeleted")
        s(GRACE, "post", "/me/pin", {"current_pin": "1234", "new_pin": "1234"}, "userUpdated")
        self._clients.pop(GRACE)  # a new PIN hash revokes her old token, as it should

        customer = s(LIZA, "post", "/customers", {"name": "Nora Salcedo"}, "customerAdded")
        s(LIZA, "patch", f"/customers/{customer['id']}", {"address": "Amas"}, "customerUpdated")
        s(LIZA, "put", f"/customers/{customer['id']}/photo", {"photo": png_b64()}, "customerPhotoUpdated")

        lines = [{"description": "Lot", "weight_grams": "50", "karat": 18, "type": "scrap", "amount_centavos": 2000000},
                 {"description": "Ring", "weight_grams": "3", "karat": 18, "type": "goods", "amount_centavos": 150000}]
        batch = s(LIZA, "post", "/purchases", {"branch": "kidapawan", "customer": {"name": "Nora Salcedo"},
                                               "lines": lines}, "purchaseRecorded")
        lot, ring = batch["items"][0]["id"], batch["items"][1]["id"]
        s(GRACE, "post", f"/purchases/{batch['id']}/return", {"note": "Recheck"}, "purchaseReturned")
        s(LIZA, "post", f"/purchases/{batch['id']}/resubmit", {"lines": [{"id": ring, "weight_grams": "3.1"}]},
          "purchaseResubmitted")
        s(GRACE, "post", f"/purchases/{batch['id']}/return", {"note": "Again"}, "purchaseReturned")
        s(LIZA, "post", f"/items/{ring}/resubmit", {"weight_grams": "3.2"}, "purchaseResubmitted")
        s(GRACE, "post", f"/purchases/{batch['id']}/release", {"proof_photo": png_b64()}, "cashReleased")
        s(LIZA, "put", f"/items/{ring}/photo", {"photo": png_b64()}, "photoAttached")
        s(ARNEL, "patch", f"/items/{ring}", {"description": "Ring (polished)"}, "itemEdited")
        piece = s(LIZA, "post", f"/items/{lot}/partitions", {"description": "Piece", "type": "goods", "grams": "5",
                                                             "amount_centavos": 200000}, "partitionCreated")
        s(ARNEL, "delete", f"/partitions/{piece['id']}", None, "partitionReturned")

        s(RHEA, "post", f"/items/{ring}/reserve", None, "itemReserved")
        s(RHEA, "post", f"/items/{ring}/release-reservation", None, "reservationReleased")
        sale = s(RHEA, "post", "/sales", {"branch": "kidapawan", "customer": {"name": "Buyer"},
                                          "lines": [{"item_id": ring, "negotiated_price_centavos": 200000}]},
                 "saleSubmitted")
        s(GRACE, "post", f"/sales/{sale['id']}/return", {"note": "Price"}, "saleReturned")
        s(RHEA, "post", f"/sales/{sale['id']}/resubmit",
          {"lines": [{"item_id": ring, "negotiated_price_centavos": 210000}]}, "saleResubmitted")
        s(GRACE, "post", f"/sales/{sale['id']}/complete", {"cash_centavos": 10000, "bank_centavos": 200000},
          "paymentReceived")
        s(GRACE, "post", "/receipts", {"record_id": sale["id"]}, "receiptIssued")

        entry = s(GRACE, "post", "/cash/entries", {"type": "cashIn", "amount_centavos": 5000, "note": "Float"},
                  "cashEntryRecorded")
        s(GRACE, "patch", f"/cash/entries/{entry['id']}", {"amount_centavos": 6000}, "cashEntryEdited")
        s(GRACE, "delete", f"/cash/entries/{entry['id']}", {"reason": "typo"}, "cashEntryDeleted")
        s(GRACE, "post", "/cash/transfers", {"to_branch": "davao", "amount_centavos": 1000, "note": "Float"},
          "cashTransferred")

        loan = s(ARNEL, "post", "/commitments", {"lender": "Metro Pawnshop", "amount_centavos": 5000000,
                                                 "rate_per_gram_centavos": 500000, "branch": "kidapawan"},
                 "commitmentAdded")
        s(ARNEL, "post", f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, "commitmentReceived")
        s(ARNEL, "post", "/disposal", {"branch": "kidapawan", "item_ids": [lot], "gross_grams": "50",
                                       "gross_amount_centavos": 2100000, "commitment_id": loan["id"]},
          "disposalCompleted")

        s(ARNEL, "post", "/rates", {"karat": 16, "price_per_gram_centavos": 400000}, "goldRateAdded")
        s(ARNEL, "patch", "/rates/16", {"price_per_gram_centavos": 410000}, "goldRateUpdated")
        s(ARNEL, "post", "/rates/apply", {"date": (timezone.localdate() - timedelta(days=14)).isoformat()},
          "goldRateUpdated")
