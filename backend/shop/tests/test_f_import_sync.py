"""Stage (f): POST /sync/import of the phone's snapshot, the seed command, and
the offline outbox (idempotent writes, push, changes feed).

`fixtures/app_demo_snapshot.json` was written by the Flutter app itself
(AppRepository().toSnapshot(), via tools/app_snapshot_dump), so these tests
import exactly what a phone holds.
"""

import io
import json
from datetime import timedelta
from pathlib import Path

from django.core.management import call_command
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework.test import APIClient

from accounts.models import User
from shop import demo
from shop.models import (
    CashEntry,
    Customer,
    DisposalBatch,
    Item,
    PurchaseBatch,
    RateChange,
    Sale,
    TransactionLog,
)
from shop.services import cash

from .helpers import API, ARNEL, BEN, GRACE, LIZA, RHEA, ApiTestCase, png_b64

FIXTURE = Path(__file__).parent / "fixtures" / "app_demo_snapshot.json"


def app_snapshot() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class ImportTests(ApiTestCase):
    def do_import(self, snapshot=None, *, expect=200, query=""):
        return self.post(ARNEL, f"/sync/import{query}", snapshot or app_snapshot(), expect=expect)

    def test_the_phones_snapshot_moves_over_with_its_ids_and_balances(self):
        snap = app_snapshot()
        report = self.do_import(snap).data
        for section in ("items", "sales", "purchaseBatches", "cashEntries", "customers", "logs", "commitments",
                        "disposalBatches", "rateHistory", "goldRates"):
            self.assertEqual(report["created"][section], len(snap[section]), section)
        self.assertEqual(report["skipped"]["users"], 7, "the staff were already on the server")
        self.assertTrue(PurchaseBatch.objects.filter(pk="A7K2M9").exists())
        self.assertTrue(Customer.objects.filter(pk="CUS001").exists())
        self.assertTrue(CashEntry.objects.filter(pk="CSH016").exists())

        # The Dashboard figures the app's own cash_ledger_test pins down.
        self.assertEqual(cash.account_balance("kidapawan", "purchase"), 103790300)
        self.assertEqual(cash.account_balance("davao", "purchase"), 69416900)
        self.assertEqual(cash.account_balance("kidapawan", "sales"), 11500000)
        self.assertEqual(cash.account_balance("kidapawan", "bank"), 25850000)
        self.assertEqual(cash.account_balance("davao", "bank"), 18420000)

        # Derived loan status, from the disposals applied.
        statuses = {c["id"]: c["ledger"]["status"] for c in self.get(ARNEL, "/commitments").data["results"]}
        self.assertEqual(statuses, {"P7B4QX": "loanPaid", "P2N9KM": "loanReceived", "P5T3HD": "loanPending"})

        # The partitioned seed lot keeps its whole-lot figures.
        lot = Item.objects.get(pk="X2P7LN")
        self.assertEqual((float(lot.effective_original_grams), lot.effective_remaining_amount), (42.5, 10500000))
        self.assertEqual(Item.objects.get(pk="M9Q4RT").parent_lot_id, "X2P7LN")
        self.assertEqual(DisposalBatch.objects.get(pk="F6H3ZN").ordered_items()[0].id, "Q6Y3DN")

        # Every log row points at a record that exists, and names its person.
        for log in TransactionLog.objects.exclude(action="snapshotImported"):
            self.assertIsNotNone(log.user_id, log.id)
            if log.record_kind == "purchaseBatch":
                self.assertTrue(PurchaseBatch.objects.filter(pk=log.record_id).exists(), log.summary)
            elif log.record_kind == "item":
                self.assertTrue(Item.objects.filter(pk=log.record_id).exists(), log.summary)
            elif log.record_kind == "sale":
                self.assertTrue(Sale.objects.filter(pk=log.record_id).exists(), log.summary)
        self.assertEqual(TransactionLog.objects.get(pk="LOG006").summary,
                         "Released ₱17,000.00 to Grace Palma for 1 item(s)")

        # Every transaction links to its customer.
        self.assertFalse(PurchaseBatch.objects.filter(customer__isnull=True).exists())
        self.assertFalse(Sale.objects.filter(customer__isnull=True).exists())

        # A cart hold that no order holds goes back on sale, as the app does on load.
        self.assertEqual(Item.objects.get(pk="R4J9WD").item_status, "listed")
        self.assertTrue(any("R4J9WD" in w for w in report["warnings"]))

        # The import itself is one log row naming the Admin.
        log = TransactionLog.objects.filter(action="snapshotImported").get()
        self.assertEqual(log.user_id, ARNEL)

    def test_importing_twice_duplicates_nothing(self):
        self.do_import()
        counts = {m.__name__: m.objects.count() for m in (Item, Sale, PurchaseBatch, CashEntry, Customer, RateChange,
                                                         DisposalBatch)}
        logs = TransactionLog.objects.exclude(action="snapshotImported").count()
        report = self.do_import().data
        self.assertEqual(sum(report["created"].values()), 0)
        self.assertEqual({m.__name__: m.objects.count() for m in (Item, Sale, PurchaseBatch, CashEntry, Customer,
                                                                  RateChange, DisposalBatch)}, counts)
        self.assertEqual(TransactionLog.objects.exclude(action="snapshotImported").count(), logs)
        self.assertEqual(cash.account_balance("kidapawan", "purchase"), 103790300)

    def test_a_record_deleted_on_the_server_is_not_brought_back(self):
        self.do_import()
        self.delete(ARNEL, "/partitions/M9Q4RT", expect=200)
        self.do_import()
        self.assertFalse(Item.objects.filter(pk="M9Q4RT").exists())

    def test_new_staff_arrive_without_a_pin(self):
        snap = app_snapshot()
        snap["users"].append({"id": "USR-K-NEW", "name": "New Person", "role": "salesRep", "homeBranch": "kidapawan",
                              "contact": None, "active": True})
        report = self.do_import(snap).data
        self.assertFalse(User.objects.get(pk="USR-K-NEW").has_pin)
        self.assertTrue(any("New Person has no PIN yet" in w for w in report["warnings"]))

    def test_a_dry_run_reports_without_writing(self):
        report = self.do_import(query="?dry_run=true").data
        self.assertTrue(report["dry_run"])
        self.assertEqual(report["created"]["items"], 23)
        self.assertEqual(Item.objects.count(), 0)
        self.assertEqual(TransactionLog.objects.count(), 0)

    def test_a_bad_snapshot_is_refused_whole_and_says_what_is_wrong(self):
        snap = app_snapshot()
        snap["items"][0]["type"] = "gold"
        snap["items"][1]["karat"] = 925
        snap["cashEntries"][0]["amount"] = "lots"
        response = self.do_import(snap, expect=422)
        problems = response.data["error"]["problems"]
        self.assertEqual(len(problems), 3)
        self.assertTrue(any(p.startswith("items[0].type") for p in problems))
        self.assertTrue(any("silver purity" not in p and "karat of 1–24" in p for p in problems))
        self.assertEqual(Item.objects.count(), 0, "a bad file changes nothing")

        broken = app_snapshot()
        broken["branches"] = []
        self.assertIn("Saved data is missing a branch", self.refusal(self.do_import(broken, expect=None)))

    def test_an_id_held_by_another_kind_of_record_is_a_conflict(self):
        self.post(LIZA, "/customers", {"name": "Not a purchase", "id": "A7K2M9"}, expect=201)
        response = self.do_import(expect=409)
        self.assertEqual(response.data["error"]["code"], "import_conflict")
        self.assertIn("A7K2M9", response.data["error"]["message"])
        self.assertEqual(Item.objects.count(), 0)

    def test_only_an_admin_imports(self):
        self.refusal(self.post(GRACE, "/sync/import", app_snapshot()), 403)

    def test_photos_and_receipts_travel_as_base64(self):
        snap = app_snapshot()
        snap["customers"][0]["photo"] = png_b64()
        snap["receipts"] = [{"id": "R7X2KQ", "recordId": "A6K4MB", "kind": "purchase", "branch": "kidapawan",
                             "counterparty": "Grace Palma", "total": 1700000, "issuedAt": snap["savedAt"],
                             "bytes": "JVBERi0xLjQK", "text": "AJ JEWELER"}]
        self.do_import(snap)
        self.assertTrue(Customer.objects.get(pk=snap["customers"][0]["id"]).photo)
        self.assertEqual(self.get(GRACE, "/receipts/R7X2KQ").data["record_id"], "A6K4MB")


class SeedTests(ApiTestCase):
    def test_the_seed_port_matches_what_the_app_writes(self):
        app = app_snapshot()
        ours = demo.build(timezone.make_aware(parse_datetime(app["savedAt"])))

        def norm(value):
            # Dates within two seconds count as equal: the app takes `now`
            # separately for each part of its seed.
            if isinstance(value, str) and len(value) >= 19 and value[4] == "-" and value[10] == "T":
                return parse_datetime(value).replace(microsecond=0) - timedelta(seconds=parse_datetime(value).second % 2)
            if isinstance(value, dict):
                return {k: norm(v) for k, v in value.items()}
            if isinstance(value, list):
                return [norm(v) for v in value]
            return value

        for section in ("users", "branches", "goldRates", "rateHistory", "items", "sales", "commitments",
                        "disposalBatches", "cashEntries", "purchaseBatches", "customers"):
            self.assertEqual(len(ours[section]), len(app[section]), section)
            for mine, theirs in zip(ours[section], app[section]):
                mine, theirs = norm(mine), norm(theirs)
                for key in theirs:
                    a, b = mine.get(key), theirs.get(key)
                    if hasattr(a, "tzinfo") and hasattr(b, "tzinfo"):
                        self.assertLessEqual(abs((a - b).total_seconds()), 2, f"{section} {theirs.get('id')} {key}")
                    else:
                        self.assertEqual(a, b, f"{section} {theirs.get('id', theirs.get('karat'))} {key}")
        by_id = {log["id"]: log for log in ours["logs"]}
        for theirs in app["logs"]:
            mine = by_id[theirs["id"]]
            for key in ("action", "userId", "userName", "role", "summary", "branch", "recordId", "recordKind", "amount",
                        "changes"):
                self.assertEqual(mine[key], theirs[key], f"{theirs['id']} {key}")

    def test_seed_command_loads_the_demo_shop_and_everyone_can_sign_in(self):
        call_command("seed_demo", "--reset", stdout=io.StringIO())
        self.assertEqual(cash.account_balance("kidapawan", "purchase"), 103790300)
        self.assertEqual(cash.account_balance("davao", "purchase"), 69416900)
        self.assertEqual(Item.objects.count(), 23)
        self.assertEqual(TransactionLog.objects.filter(action="snapshotImported").count(), 1)
        login = APIClient().post(f"{API}/auth/login", {"name": "Grace Ramos", "pin": "1234"}, format="json")
        self.assertEqual(login.status_code, 200)

        # Running it again with --reset gives the same shop, not a doubled one.
        call_command("seed_demo", "--reset", stdout=io.StringIO())
        self.assertEqual(Item.objects.count(), 23)
        self.assertEqual(CashEntry.objects.count(), 16)


class SnapshotExportTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        self.post(ARNEL, "/sync/import", app_snapshot(), expect=200)

    def test_the_server_hands_back_the_phones_own_format(self):
        app = app_snapshot()
        out = self.get(ARNEL, "/sync/snapshot").data
        self.assertEqual(out["version"], 1)
        self.assertGreater(out["cursor"], 0)
        for section in ("items", "sales", "purchaseBatches", "cashEntries", "customers", "commitments",
                        "disposalBatches", "goldRates", "rateHistory"):
            self.assertEqual(len(out[section]), len(app[section]), section)
        theirs = {i["id"]: i for i in app["items"]}
        for item in out["items"]:
            for key in ("description", "weight", "gross", "karat", "type", "capital", "branch", "verification",
                        "encodedBy", "batchId", "parentLotId", "originalGrams", "remainingAmount"):
                self.assertEqual(item[key], theirs[item["id"]][key], f"{item['id']} {key}")
            self.assertIsNone(parse_datetime(item["purchaseDate"]).tzinfo, "the phone reads local times")
        self.assertEqual({e["id"]: e["amount"] for e in out["cashEntries"]},
                         {e["id"]: e["amount"] for e in app["cashEntries"]})
        self.assertNotIn("snapshotImported", {log["action"] for log in out["logs"]},
                         "the v1 app cannot parse server-only actions")
        self.assertEqual(len(out["logs"]), len(app["logs"]))

    def test_branch_staff_get_their_branch_and_company_wide_records(self):
        out = self.get(BEN, "/sync/snapshot", {"photos": "false"}).data
        self.assertEqual({i["branch"] for i in out["items"]}, {"davao"})
        self.assertEqual(len(out["branches"]), 2, "the phone refuses a snapshot without both branches")
        self.assertIn("P2N9KM", [c["id"] for c in out["commitments"]], "company-wide loans travel to every branch")
        self.assertNotIn("P7B4QX", [c["id"] for c in out["commitments"]])


class OutboxTests(ApiTestCase):
    def push(self, user, operations, *, expect=200, **extra):
        return self.post(user, "/sync/push", {"operations": operations, **extra}, expect=expect).data

    def offline_purchase(self, minutes_ago=90):
        when = (timezone.localtime() - timedelta(minutes=minutes_ago)).replace(tzinfo=None).isoformat()
        return [
            {"key": "op-1", "method": "POST", "path": "/api/v1/purchases", "recorded_at": when, "body": {
                "id": "Q7MNP3", "branch": "kidapawan", "date": when,
                "customer": {"id": "C4VR8T", "name": "Offline Olivia"},
                "lines": [{"id": "Q7MNP4", "description": "Offline ring", "weight_grams": 3.5, "karat": 18,
                           "type": "goods", "amount_centavos": 180000}]}},
        ]

    def test_queued_writes_apply_in_order_dated_when_they_happened(self):
        ops = self.offline_purchase(minutes_ago=90)
        when = ops[0]["recorded_at"]
        ops.append({"key": "op-2", "method": "POST", "path": "/api/v1/purchases/Q7MNP3/release",
                    "recorded_at": when, "body": {"proof_photo": png_b64(), "cash_entry_id": "Q7MNP5"}})
        result = self.push(LIZA, ops[:1])
        self.assertEqual(result["applied"], 1)
        result = self.push(GRACE, ops[1:])
        self.assertEqual(result["results"][0]["status"], 200, result)
        self.assertEqual(CashEntry.objects.get(pk="Q7MNP5").linked_record_id, "Q7MNP3")
        log = TransactionLog.objects.get(action="cashReleased")
        self.assertEqual(timezone.localtime(log.at).replace(tzinfo=None).isoformat(timespec="seconds"),
                         when[:19], "the log says when it happened on the phone")
        self.assertGreater(log.received_at, log.at, "and records when the server received it")
        self.assertEqual(PurchaseBatch.objects.get(pk="Q7MNP3").released_by_id, GRACE)

    def test_resending_a_queue_never_acts_twice(self):
        ops = self.offline_purchase()
        first = self.push(LIZA, ops)
        again = self.push(LIZA, ops)
        self.assertTrue(again["results"][0]["replayed"])
        self.assertEqual(again["results"][0]["body"]["id"], first["results"][0]["body"]["id"])
        self.assertEqual(PurchaseBatch.objects.count(), 1)
        self.assertEqual(TransactionLog.objects.filter(action="purchaseRecorded").count(), 1)

    def test_a_refused_change_comes_back_with_the_apps_message_and_the_rest_still_apply(self):
        item = self.released_item()
        sale = self.post(RHEA, "/sales", {"branch": "kidapawan", "customer": {"name": "B"},
                                          "lines": [{"item_id": item["id"], "negotiated_price_centavos": 900000}]},
                         expect=201).data
        self.post(GRACE, f"/sales/{sale['id']}/complete", {"cash_centavos": 900000, "bank_centavos": 0}, expect=200)
        result = self.push(GRACE, [
            {"key": "k1", "method": "POST", "path": f"sales/{sale['id']}/complete",
             "body": {"cash_centavos": 900000, "bank_centavos": 0}},
            {"key": "k2", "method": "POST", "path": "cash/entries",
             "body": {"type": "cashIn", "amount_centavos": 5000, "note": "Float top-up"}},
        ])
        refused, applied = result["results"]
        self.assertEqual(refused["status"], 422)
        self.assertEqual(refused["body"]["error"]["message"], "Payment for this order was already received")
        self.assertEqual(applied["status"], 201)
        self.assertEqual((result["applied"], result["refused"]), (1, 1))

    def test_stop_on_error_leaves_the_rest_of_the_queue_unsent(self):
        result = self.push(GRACE, [
            {"key": "a", "method": "POST", "path": "cash/entries", "body": {"type": "cashIn", "amount_centavos": 0,
                                                                          "note": "x"}},
            {"key": "b", "method": "POST", "path": "cash/entries", "body": {"type": "cashIn", "amount_centavos": 5,
                                                                          "note": "x"}},
        ], stop_on_error=True)
        self.assertEqual(result["results"][1], {"key": "b", "status": None, "skipped": True})
        self.assertEqual(CashEntry.objects.count(), 0)

    def test_the_outbox_cannot_reach_the_push_or_sign_in_endpoints(self):
        result = self.push(GRACE, [{"key": "x", "method": "POST", "path": "/api/v1/sync/push", "body": {}}])
        self.assertEqual(result["results"][0]["status"], 400)

    def test_a_change_dated_too_far_back_or_in_the_future_is_refused(self):
        old = (timezone.localtime() - timedelta(days=40)).replace(tzinfo=None).isoformat()
        future = (timezone.localtime() + timedelta(hours=2)).replace(tzinfo=None).isoformat()
        for when, code in ((old, "recorded_at_too_old"), (future, "recorded_at_future")):
            result = self.push(GRACE, [{"key": code, "method": "POST", "path": "cash/entries", "recorded_at": when,
                                        "body": {"type": "cashIn", "amount_centavos": 5, "note": "x"}}])
            self.assertEqual(result["results"][0]["body"]["error"]["code"], code)


class IdempotencyTests(ApiTestCase):
    def test_a_replayed_key_returns_the_first_result(self):
        body = {"type": "cashIn", "amount_centavos": 5000, "note": "Float"}
        first = self.post(GRACE, "/cash/entries", body, expect=201, **{"Idempotency-Key": "abc"})
        again = self.post(GRACE, "/cash/entries", body, expect=201, **{"Idempotency-Key": "abc"})
        self.assertEqual(again["Idempotent-Replayed"], "true")
        self.assertEqual(again.data["id"], first.data["id"])
        self.assertEqual(CashEntry.objects.count(), 1)

    def test_a_refusal_is_remembered_too(self):
        body = {"type": "cashIn", "amount_centavos": 0, "note": "Float"}
        self.post(GRACE, "/cash/entries", body, expect=422, **{"Idempotency-Key": "no"})
        again = self.post(GRACE, "/cash/entries", body, expect=422, **{"Idempotency-Key": "no"})
        self.assertEqual(again["Idempotent-Replayed"], "true")

    def test_reusing_a_key_for_a_different_request_is_refused(self):
        self.post(GRACE, "/cash/entries", {"type": "cashIn", "amount_centavos": 5000, "note": "A"}, expect=201,
                  **{"Idempotency-Key": "same"})
        response = self.post(GRACE, "/cash/entries", {"type": "cashIn", "amount_centavos": 7000, "note": "B"},
                             **{"Idempotency-Key": "same"})
        self.assertEqual(self.refusal(response), "That Idempotency-Key was already used for a different request")
        self.assertEqual(CashEntry.objects.count(), 1)

    def test_keys_belong_to_the_person_who_sent_them(self):
        body = {"type": "cashIn", "amount_centavos": 5000, "note": "Float", "branch": "kidapawan"}
        self.post(GRACE, "/cash/entries", body, expect=201, **{"Idempotency-Key": "shared"})
        self.post(ARNEL, "/cash/entries", body, expect=201, **{"Idempotency-Key": "shared"})
        self.assertEqual(CashEntry.objects.count(), 2)


class ChangesFeedTests(ApiTestCase):
    def test_changes_since_a_cursor_in_the_phones_format(self):
        start = self.get(ARNEL, "/sync/changes", {"since": 0}).data["cursor"]
        item = self.released_item(type="scrap", grams="20", amount=800000)
        piece = self.post(LIZA, f"/items/{item['id']}/partitions", {"description": "Piece", "type": "goods",
                                                                   "grams": "5", "amount_centavos": 200000},
                          expect=201).data
        feed = self.get(ARNEL, "/sync/changes", {"since": start, "photos": "false"}).data
        ids = {i["id"] for i in feed["changes"]["items"]}
        self.assertEqual(ids, {item["id"], piece["id"]})
        self.assertIn("purchaseBatches", feed["changes"])
        self.assertIn("cashEntries", feed["changes"])
        self.assertTrue(all(log["action"] != "itemReserved" for log in feed["changes"].get("logs", [])))
        cursor = feed["cursor"]

        self.delete(ARNEL, f"/partitions/{piece['id']}", expect=200)
        feed = self.get(ARNEL, "/sync/changes", {"since": cursor}).data
        self.assertEqual(feed["deleted"], {"items": [piece["id"]]})
        self.assertEqual([i["id"] for i in feed["changes"]["items"]], [item["id"]])
        self.assertEqual(self.get(ARNEL, "/sync/changes", {"since": feed["cursor"]}).data["changes"], {})

    def test_branch_staff_only_receive_their_branch(self):
        start = self.get(BEN, "/sync/changes").data["cursor"]
        self.released_item(branch="kidapawan")
        self.assertNotIn("items", self.get(BEN, "/sync/changes", {"since": start}).data["changes"])
