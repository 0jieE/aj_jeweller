"""Stage (b): customers, items, purchase batches, release, corrections,
partitions. Ported from the app's purchase_batch_test, purchase_repository_test,
accountability_test, customer_test and silver_test."""

from decimal import Decimal

from shop.models import CashEntry, Customer, Item, RecordId
from shop.services import cash

from .helpers import ARNEL, BEN, GRACE, JOEL, LIZA, RHEA, ApiTestCase, png_b64

THREE_PIECES = [
    {"description": "22K necklace", "gross_weight_grams": "16.400", "weight_grams": "15.750", "karat": 22,
     "type": "goods", "amount_centavos": 8200000},
    {"description": "18K ring", "gross_weight_grams": "3.850", "weight_grams": "3.200", "karat": 18,
     "type": "goods", "amount_centavos": 1350000},
    {"description": "Broken chain scrap", "gross_weight_grams": "10.000", "weight_grams": "10.000", "karat": 14,
     "type": "scrap", "amount_centavos": 450000},
]


def purchase_cash(branch="kidapawan") -> int:
    return cash.account_balance(branch, "purchase")


class PurchaseBatchTests(ApiTestCase):
    def three_pieces(self, **extra):
        return self.purchase(customer="Maria Santos", lines=THREE_PIECES, **extra).data

    # Acceptance 1 -----------------------------------------------------------
    def test_a_purchase_moves_no_cash_until_release_then_exactly_one_entry_against_purchase_cash(self):
        before = purchase_cash()
        batch = self.three_pieces()
        self.assertEqual(batch["verification_status"], "awaitingVerification")
        self.assertEqual(batch["total_centavos"], 10000000)
        self.assertTrue(all(i["item_status"] == "pending" for i in batch["items"]))
        self.assertEqual(purchase_cash(), before, "cash moves at release, not at entry")
        self.assertEqual(CashEntry.objects.count(), 0)

        released = self.release(batch["id"]).data
        entries = list(CashEntry.objects.all())
        self.assertEqual(len(entries), 1, "one release, one entry — not one per piece")
        entry = entries[0]
        self.assertEqual((entry.account, entry.type, entry.source_type), ("purchase", "expense", "purchase"))
        self.assertEqual(entry.amount_centavos, 10000000)
        self.assertEqual(entry.linked_record_id, batch["id"])
        self.assertEqual(entry.recorded_by_id, GRACE)
        self.assertEqual(purchase_cash(), before - 10000000)
        self.assertEqual(cash.account_balance("kidapawan", "sales"), 0)
        self.assertEqual(cash.account_balance("kidapawan", "bank"), 0)
        self.assertEqual(released["cash_entry"]["id"], entry.id)

    def test_release_verifies_every_piece_and_routes_each_to_its_home(self):
        batch = self.three_pieces()
        released = self.release(batch["id"]).data
        status_by_type = {i["type"]: i["item_status"] for i in released["items"]}
        self.assertEqual(status_by_type, {"goods": "listed", "scrap": "forDisposal"})
        self.assertTrue(all(i["verification_status"] == "verified" for i in released["items"]))
        self.assertIsNotNone(released["released_at"])
        self.assertEqual(released["released_by"]["id"], GRACE)
        self.assertEqual(released["submitted_by"]["id"], LIZA)
        self.assertIsNotNone(released["release_proof_photo_url"])

    def test_release_needs_a_proof_photo_and_is_never_paid_twice(self):
        batch = self.three_pieces()
        message = self.refusal(self.post(GRACE, f"/purchases/{batch['id']}/release", {}))
        self.assertEqual(message, "A photo of the cash being handed over is required to release it")
        self.release(batch["id"])
        after = purchase_cash()
        self.assertEqual(self.refusal(self.release(batch["id"], expect=None)),
                         "Cash for this purchase was already released")
        self.assertEqual(purchase_cash(), after)
        self.assertEqual(CashEntry.objects.count(), 1)

    def test_release_accepts_a_multipart_photo_upload(self):
        from django.core.files.uploadedfile import SimpleUploadedFile

        from .helpers import png_bytes

        batch = self.three_pieces()
        upload = SimpleUploadedFile("cash.png", png_bytes(), content_type="image/png")
        self.post(GRACE, f"/purchases/{batch['id']}/release", {"proof_photo": upload}, fmt="multipart", expect=200)

    def test_a_purchase_with_nothing_in_it_is_refused(self):
        self.assertEqual(self.refusal(self.purchase(lines=[], expect=None)), "A purchase needs at least one item")

    def test_gross_weight_is_kept_beside_the_net_it_is_priced_on(self):
        necklace = self.three_pieces()["items"][0]
        self.assertEqual((necklace["weight_grams"], necklace["gross_weight_grams"], necklace["deducted_grams"]),
                         ("15.750", "16.400", "0.650"))

    def test_lines_read_back_in_the_order_they_were_entered(self):
        names = [i["description"] for i in self.three_pieces()["items"]]
        self.assertEqual(names, ["22K necklace", "18K ring", "Broken chain scrap"])

    def test_returning_sends_the_whole_batch_back_with_a_note_and_moves_no_cash(self):
        batch = self.three_pieces()
        self.refusal(self.post(GRACE, f"/purchases/{batch['id']}/return", {"note": " "}))
        returned = self.post(GRACE, f"/purchases/{batch['id']}/return", {"note": "Recheck the 18K ring weight"},
                             expect=200).data
        self.assertEqual(returned["verification_status"], "returnedForCorrection")
        self.assertEqual(returned["verification_note"], "Recheck the 18K ring weight")
        self.assertTrue(all(i["verification_status"] == "returnedForCorrection" for i in returned["items"]))
        self.assertEqual(CashEntry.objects.count(), 0)
        self.assertEqual(self.refusal(self.release(batch["id"], expect=None)),
                         "This purchase was returned for correction — it can be released once it is resubmitted")

    def test_fixing_one_piece_puts_the_whole_batch_back_in_the_queue(self):
        batch = self.three_pieces()
        self.post(GRACE, f"/purchases/{batch['id']}/return", {"note": "Recheck weight"}, expect=200)
        ring = next(i for i in batch["items"] if i["description"] == "18K ring")
        back = self.post(LIZA, f"/items/{ring['id']}/resubmit", {
            "description": "18K ring (rechecked)", "weight_grams": "3.4", "amount_centavos": 1400000,
        }, expect=200).data
        self.assertEqual(back["verification_status"], "awaitingVerification")
        self.assertIsNone(back["verification_note"])
        self.assertEqual(back["total_centavos"], 10050000)
        fixed = next(i for i in back["items"] if i["id"] == ring["id"])
        self.assertEqual((fixed["item_status"], fixed["verification_note"], fixed["weight_grams"]),
                         ("pending", None, "3.400"))
        log = self.last_log()
        self.assertEqual(log.action, "purchaseResubmitted")
        self.assertIn({"field": "Final weight", "before": "3.200g", "after": "3.400g"}, log.changes)

    def test_resubmitting_keeps_the_photo_and_the_encoder(self):
        batch = self.purchase(lines=[{"description": "Ring", "weight_grams": "3", "karat": 18, "type": "goods",
                                      "amount_centavos": 150000, "photo": png_b64()}]).data
        self.post(GRACE, f"/purchases/{batch['id']}/return", {"note": "Recheck weight"}, expect=200)
        self.post(LIZA, f"/purchases/{batch['id']}/resubmit",
                  {"lines": [{"id": batch["items"][0]["id"], "weight_grams": "3.1"}]}, expect=200)
        item = Item.objects.get(pk=batch["items"][0]["id"])
        self.assertTrue(item.photo)
        self.assertEqual(item.encoded_by_id, LIZA)

    def test_only_encoders_record_and_only_cashiers_release(self):
        self.assertEqual(self.refusal(self.purchase(by=RHEA, expect=None), 403),
                         "Only an Assistant Appraiser or Admin can encode purchases")
        batch = self.three_pieces()
        self.assertEqual(self.refusal(self.release(batch["id"], by=LIZA, expect=None), 403),
                         "Only a Cashier or Admin can release cash")

    def test_branch_staff_work_their_own_branch(self):
        message = self.refusal(self.purchase(by=JOEL, branch="kidapawan", expect=None), 403)
        self.assertEqual(message, "You work from Davao — this belongs to Kidapawan")
        batch = self.three_pieces()
        self.refusal(self.release(batch["id"], by=BEN, expect=None), 403)
        self.refusal(self.get(JOEL, f"/purchases/{batch['id']}", expect=None), 403)
        self.assertEqual(self.get(JOEL, "/purchases").data["count"], 0)


class RecordIdTests(ApiTestCase):
    def test_a_client_chosen_id_is_the_primary_key(self):
        batch = self.purchase(id="A7K2M9", lines=[{**THREE_PIECES[0], "id": "7H3M2Q"}]).data
        self.assertEqual((batch["id"], batch["items"][0]["id"]), ("A7K2M9", "7H3M2Q"))

    def test_an_id_is_unique_across_every_record_type(self):
        batch = self.purchase().data
        # The purchase's code cannot be reused for an item, a customer, anything.
        response = self.purchase(lines=[{**THREE_PIECES[0], "id": batch["id"]}], expect=409)
        self.assertEqual(response.data["error"]["code"], "duplicate_id")
        self.assertEqual(response.data["error"]["existing_kind"], "purchaseBatch")
        self.assertEqual(Item.objects.count(), 1, "the refused purchase left nothing behind")

    def test_ids_avoid_ambiguous_characters(self):
        for bad in ("A7K2M0", "ABCDEI", "abc123", "TOOLONG1"):
            self.assertEqual(self.purchase(id=bad, expect=422).data["error"]["code"], "invalid_id")
        batch = self.purchase().data
        allowed = set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        for code in [batch["id"], batch["items"][0]["id"], batch["customer"]["id"]]:
            self.assertEqual(len(code), 6)
            self.assertTrue(set(code) <= allowed, code)
        self.assertTrue(RecordId.objects.filter(pk=batch["id"], kind="purchaseBatch").exists())


class PurityTests(ApiTestCase):
    # Acceptance 6 -----------------------------------------------------------
    def test_silver_with_a_gold_karat_or_gold_with_a_silver_purity_is_refused(self):
        silver_18k = [{"description": "Chain", "weight_grams": "20", "karat": 18, "type": "silver",
                       "amount_centavos": 130000}]
        gold_925 = [{"description": "Ring", "weight_grams": "20", "karat": 925, "type": "goods",
                     "amount_centavos": 130000}]
        self.assertEqual(self.refusal(self.purchase(lines=silver_18k, expect=None)),
                         "A silver piece needs a silver purity (e.g. 925), not a gold karat")
        self.assertEqual(self.refusal(self.purchase(lines=gold_925, expect=None)),
                         "A gold piece needs a karat, not a silver purity")
        self.assertEqual(Item.objects.count(), 0)

    def test_the_database_itself_refuses_a_purity_that_does_not_match_the_metal(self):
        from django.db import IntegrityError, transaction

        item = self.released_item()
        with self.assertRaises(IntegrityError), transaction.atomic():
            Item.objects.filter(pk=item["id"]).update(type="silver")

    def test_a_correction_cannot_switch_metal_without_switching_purity(self):
        item = self.purchase().data["items"][0]
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{item['id']}", {"type": "silver"})),
                         "A silver piece needs a silver purity (e.g. 925), not a gold karat")
        fixed = self.patch(ARNEL, f"/items/{item['id']}", {"type": "silver", "karat": 925}, expect=200).data["item"]
        self.assertEqual((fixed["type"], fixed["karat"]), ("silver", 925))

    def test_released_silver_is_listed_like_goods(self):
        item = self.released_item(type="silver", karat=925)
        self.assertEqual(item["item_status"], "listed")
        sellable = [i["id"] for i in self.get(RHEA, "/items/sellable", {"silver": "true"}).data["results"]]
        self.assertIn(item["id"], sellable)


class CustomerBookTests(ApiTestCase):
    def test_a_purchase_files_its_customer_and_links_back(self):
        batch = self.purchase(customer="Nora Salcedo").data
        customer = Customer.objects.get(name="Nora Salcedo")
        self.assertEqual(batch["customer"]["id"], customer.id)
        detail = self.get(LIZA, f"/customers/{customer.id}").data
        self.assertEqual([p["id"] for p in detail["purchases"]], [batch["id"]])

    def test_the_same_person_however_typed_is_one_record(self):
        self.purchase(customer="Nora Salcedo")
        self.purchase(customer="  nora   SALCEDO ")
        self.assertEqual(Customer.objects.count(), 1)

    def test_a_later_visit_fills_gaps_but_never_blanks_what_is_on_file(self):
        self.post(LIZA, "/purchases", {"branch": "kidapawan",
                                       "customer": {"name": "Nora Salcedo", "contact_number": "0917 000 1111"},
                                       "lines": THREE_PIECES[:1]}, expect=201)
        self.post(LIZA, "/purchases", {"branch": "kidapawan",
                                       "customer": {"name": "Nora Salcedo", "address": "Lanao", "contact_number": ""},
                                       "lines": THREE_PIECES[:1]}, expect=201)
        customer = Customer.objects.get()
        self.assertEqual((customer.contact_number, customer.address), ("0917 000 1111", "Lanao"))

    def test_the_transaction_keeps_the_details_as_given_that_day(self):
        self.post(LIZA, "/purchases", {"branch": "kidapawan", "customer": {"name": "Nora", "address": "Amas"},
                                       "lines": THREE_PIECES[:1]}, expect=201)
        later = self.post(LIZA, "/purchases", {"branch": "kidapawan", "customer": {"name": "Nora", "address": "Lanao"},
                                               "lines": THREE_PIECES[:1]}, expect=201).data
        first = self.get(LIZA, "/purchases").data["results"][-1]
        self.assertEqual((first["customer"]["address"], later["customer"]["address"]), ("Amas", "Lanao"))

    def test_a_counter_photo_is_filed_on_the_customer_and_a_new_one_replaces_it(self):
        first = self.post(LIZA, "/purchases", {"branch": "kidapawan",
                                               "customer": {"name": "Regular", "photo": png_b64((1, 2, 3))},
                                               "lines": THREE_PIECES[:1]}, expect=201).data
        customer_id = first["customer"]["id"]
        old = Customer.objects.get(pk=customer_id).photo.name
        self.post(LIZA, "/purchases", {"branch": "kidapawan", "customer": {"name": "Regular", "id": customer_id},
                                       "lines": THREE_PIECES[:1]}, expect=201)
        self.assertEqual(Customer.objects.get(pk=customer_id).photo.name, old)
        self.post(LIZA, "/purchases", {"branch": "kidapawan",
                                       "customer": {"name": "Regular", "id": customer_id, "photo": png_b64((9, 9, 9))},
                                       "lines": THREE_PIECES[:1]}, expect=201)
        self.assertNotEqual(Customer.objects.get(pk=customer_id).photo.name, old)

    def test_an_offline_phone_can_name_a_new_customer_itself(self):
        batch = self.post(LIZA, "/purchases", {"branch": "kidapawan", "customer": {"name": "New Face", "id": "C7NX4Q"},
                                               "lines": THREE_PIECES[:1]}, expect=201).data
        self.assertEqual(batch["customer"]["id"], "C7NX4Q")

    def test_changing_a_photo_from_the_book_is_logged(self):
        customer = self.post(LIZA, "/customers", {"name": "Book Person"}, expect=201).data
        self.put(LIZA, f"/customers/{customer['id']}/photo", {"photo": png_b64()}, expect=200)
        log = self.last_log()
        self.assertEqual((log.action, log.record_kind, log.record_id),
                         ("customerPhotoUpdated", "customer", customer["id"]))

    def test_search_ranks_names_starting_with_the_query_first(self):
        for name in ("Norma Reyes", "Nora Salcedo", "Elenora Cruz"):
            self.post(LIZA, "/customers", {"name": name}, expect=201)
        names = [c["name"] for c in self.get(LIZA, "/customers", {"q": "nor"}).data["results"]]
        self.assertEqual(set(names[:2]), {"Nora Salcedo", "Norma Reyes"})
        self.assertEqual(names[-1], "Elenora Cruz")

    def test_a_photo_must_actually_be_a_photo(self):
        customer = self.post(LIZA, "/customers", {"name": "Book Person"}, expect=201).data
        response = self.put(LIZA, f"/customers/{customer['id']}/photo", {"photo": "bm90IGEgcGhvdG8="})
        self.assertEqual(response.status_code, 400)


class CorrectionTests(ApiTestCase):
    def test_a_plain_correction_records_before_and_after_and_moves_no_cash(self):
        item = self.released_item(grams="10", amount=500000)
        before = purchase_cash()
        response = self.patch(ARNEL, f"/items/{item['id']}", {
            "description": "Test goods (reweighed)", "weight_grams": "9.5", "amount_centavos": 480000,
        }, expect=200).data
        self.assertEqual((response["item"]["weight_grams"], response["item"]["capital_amount_centavos"]),
                         ("9.500", 480000))
        self.assertLessEqual({"Description", "Final weight", "Amount"}, {c["field"] for c in response["changes"]})
        self.assertFalse(response["cash_moved"])
        self.assertIn("not moved in the ledger", response["cash_note"])
        self.assertEqual(purchase_cash(), before, "an edit never fabricates a cash movement")
        log = self.last_log()
        self.assertEqual((log.action, log.user_id), ("itemEdited", ARNEL))
        self.assertIn("not moved in the ledger", log.summary)
        self.assertIn({"field": "Amount", "before": "₱5,000.00", "after": "₱4,800.00"}, log.changes)

    def test_only_an_admin_corrects(self):
        item = self.released_item()
        self.assertEqual(self.refusal(self.patch(GRACE, f"/items/{item['id']}", {"description": "x"}), 403),
                         "Only an Admin can correct records")

    def test_a_correction_that_changes_nothing_writes_nothing(self):
        item = self.released_item()
        logs = self.log_count()
        response = self.patch(ARNEL, f"/items/{item['id']}", {"description": item["description"]}, expect=200).data
        self.assertEqual(response["changes"], [])
        self.assertEqual(self.log_count(), logs)

    def test_a_type_change_moves_the_piece_between_shelf_and_disposal_pool(self):
        item = self.released_item(type="goods")
        fixed = self.patch(ARNEL, f"/items/{item['id']}", {"type": "scrap"}, expect=200).data["item"]
        self.assertEqual(fixed["item_status"], "forDisposal")

    def test_gross_follows_net_when_nothing_was_deducted(self):
        item = self.released_item(grams="10")
        fixed = self.patch(ARNEL, f"/items/{item['id']}", {"weight_grams": "9"}, expect=200).data["item"]
        self.assertEqual(fixed["gross_weight_grams"], "9.000")
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{item['id']}", {"gross_weight_grams": "8"})),
                         "The original weight cannot be less than the final weight")

    def test_sold_and_disposed_pieces_are_closed_to_corrections(self):
        item = self.released_item()
        Item.objects.filter(pk=item["id"]).update(item_status="sold")
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{item['id']}", {"description": "x"})),
                         "A sold item can no longer be edited")
        Item.objects.filter(pk=item["id"]).update(item_status="disposed")
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{item['id']}", {"description": "x"})),
                         "A disposed item can no longer be edited")


class PartitionTests(ApiTestCase):
    def lot(self, grams="50", amount=2000000):
        return self.released_item(type="scrap", grams=grams, amount=amount)

    def draw(self, lot_id, grams, amount, *, by=LIZA, type="goods", expect=201):
        return self.post(by, f"/items/{lot_id}/partitions",
                         {"description": "Piece", "type": type, "grams": grams, "amount_centavos": amount},
                         expect=expect)

    def remaining(self, lot_id):
        lot = Item.objects.get(pk=lot_id)
        return lot.effective_remaining_grams, lot.effective_remaining_amount

    def test_drawing_takes_grams_and_amount_from_the_lot_together(self):
        lot = self.lot()
        child = self.draw(lot["id"], "20", 800000).data
        self.assertEqual((child["parent_lot_id"], child["weight_grams"], child["karat"], child["verification_status"],
                          child["item_status"]), (lot["id"], "20.000", 18, "verified", "listed"))
        parent = Item.objects.get(pk=lot["id"])
        self.assertEqual((parent.effective_original_grams, parent.effective_original_amount), (Decimal("50"), 2000000))
        self.assertEqual(self.remaining(lot["id"]), (Decimal("30"), 1200000))
        self.assertEqual(self.last_log().action, "partitionCreated")

    # Acceptance 4 -----------------------------------------------------------
    def test_a_partition_never_draws_more_than_the_lot_has_left(self):
        lot = self.lot(grams="10", amount=400000)
        self.assertEqual(self.refusal(self.draw(lot["id"], "15", 100000, expect=None)),
                         "Only 10.000g remain on this lot — reduce the weight.")
        self.assertEqual(self.refusal(self.draw(lot["id"], "5", 500000, expect=None)),
                         "Only ₱4,000.00 remain on this lot — reduce the amount.")
        self.assertEqual(self.remaining(lot["id"]), (Decimal("10"), 400000))
        self.draw(lot["id"], "6", 240000)
        self.assertEqual(self.refusal(self.draw(lot["id"], "4.001", 1, expect=None)),
                         "Only 4.000g remain on this lot — reduce the weight.")
        self.draw(lot["id"], "4", 160000)
        exhausted = Item.objects.get(pk=lot["id"])
        self.assertTrue(exhausted.is_exhausted)
        self.assertEqual(self.refusal(self.draw(lot["id"], "0.001", 1, expect=None)),
                         "Only 0.000g remain on this lot — reduce the weight.")

    def test_deleting_a_partition_restores_the_lot_exactly(self):
        lot = self.lot()
        a = self.draw(lot["id"], "20", 800000).data
        self.draw(lot["id"], "5", 200000)
        cash_before, entries_before = purchase_cash(), CashEntry.objects.count()

        restored = self.delete(ARNEL, f"/partitions/{a['id']}", expect=200).data["lot"]
        self.assertEqual((restored["effective_remaining_grams"], restored["effective_remaining_amount_centavos"]),
                         ("45.000", 1800000))
        self.assertTrue(restored["has_partitions"], "one sibling is still drawn out")
        self.assertFalse(Item.objects.filter(pk=a["id"]).exists())
        self.assertEqual((purchase_cash(), CashEntry.objects.count()), (cash_before, entries_before),
                         "the lot was paid for once, at release")
        self.assertEqual(self.last_log().action, "partitionReturned")

    def test_returning_the_last_partition_makes_the_lot_read_as_never_partitioned(self):
        lot = self.lot()
        only = self.draw(lot["id"], "20", 800000).data
        restored = self.delete(ARNEL, f"/partitions/{only['id']}", expect=200).data["lot"]
        self.assertFalse(restored["has_partitions"])
        self.assertEqual((restored["effective_remaining_grams"], restored["effective_remaining_amount_centavos"]),
                         ("50.000", 2000000))
        parent = Item.objects.get(pk=lot["id"])
        self.assertIsNone(parent.original_grams)

    def test_a_lot_recorded_at_its_remainder_keeps_its_full_original_figures(self):
        # How the app's seed lot X2P7LN arrives: weight is the 27.5g remainder
        # of a 42.5g lot, so original/remaining are the only record of the whole.
        lot = self.lot(grams="42.5", amount=16500000)
        piece = self.draw(lot["id"], "15", 6000000).data
        Item.objects.filter(pk=lot["id"]).update(weight_grams=Decimal("27.5"), capital_amount_centavos=10500000)
        restored = self.delete(ARNEL, f"/partitions/{piece['id']}", expect=200).data["lot"]
        self.assertEqual((restored["effective_remaining_grams"], restored["effective_remaining_amount_centavos"],
                          restored["effective_original_grams"]), ("42.500", 16500000, "42.500"))

    def test_only_a_partition_in_stock_can_be_returned(self):
        lot = self.lot()
        self.assertEqual(self.refusal(self.delete(ARNEL, f"/partitions/{lot['id']}")),
                         "Only a partition can be returned to a parent lot")
        piece = self.draw(lot["id"], "10", 400000).data
        Item.objects.filter(pk=piece["id"]).update(item_status="sold")
        self.assertEqual(self.refusal(self.delete(ARNEL, f"/partitions/{piece['id']}")),
                         "A sold partition can no longer be returned to its lot")
        self.assertEqual(self.remaining(lot["id"]), (Decimal("40"), 1600000))
        self.refusal(self.delete(LIZA, f"/partitions/{piece['id']}"), 403)

    def test_a_partition_stays_the_same_metal_as_its_lot(self):
        lot = self.released_item(type="silver", karat=999, grams="50", amount=300000)
        self.assertEqual(self.refusal(self.draw(lot["id"], "5", 30000, type="goods", expect=None)),
                         "A partition is the same metal as its lot")
        child = self.draw(lot["id"], "5", 30000, type="silver").data
        self.assertEqual(child["karat"], 999)

    def test_an_unreleased_lot_cannot_be_partitioned(self):
        item = self.purchase().data["items"][0]
        self.assertEqual(self.refusal(self.draw(item["id"], "1", 1, expect=None)),
                         "Only a verified lot can be partitioned — release its purchase first")

    def test_changing_a_partition_takes_the_difference_from_its_lot(self):
        lot = self.lot()
        piece = self.draw(lot["id"], "20", 800000).data
        response = self.patch(ARNEL, f"/items/{piece['id']}", {"weight_grams": "22", "amount_centavos": 900000},
                              expect=200).data
        self.assertEqual(self.remaining(lot["id"]), (Decimal("28"), 1100000))
        self.assertEqual(Item.objects.get(pk=lot["id"]).effective_original_grams, Decimal("50"))
        self.assertIn(f"Lot {lot['id']} remaining", [c["field"] for c in response["changes"]])

    def test_a_partition_correction_cannot_take_more_than_the_lot_has_left(self):
        lot = self.lot()
        piece = self.draw(lot["id"], "45", 1800000).data
        message = self.refusal(self.patch(ARNEL, f"/items/{piece['id']}", {"weight_grams": "60"}))
        self.assertEqual(message, f"Lot {lot['id']} only has 5.000g and ₱2,000.00 left to give")
        self.assertEqual(Item.objects.get(pk=piece["id"]).weight_grams, Decimal("45"))
        self.assertEqual(self.remaining(lot["id"]), (Decimal("5"), 200000))

    def test_correcting_a_partitioned_lot_keeps_what_was_drawn(self):
        lot = self.lot()
        self.draw(lot["id"], "20", 800000)
        self.patch(ARNEL, f"/items/{lot['id']}", {"weight_grams": "52", "amount_centavos": 2100000}, expect=200)
        fixed = Item.objects.get(pk=lot["id"])
        self.assertEqual((fixed.effective_original_grams, fixed.effective_remaining_grams,
                          fixed.effective_remaining_amount), (Decimal("52"), Decimal("32"), 1300000))
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{lot['id']}", {"weight_grams": "10"})),
                         "More than that has already been drawn out of this lot into partitions")

    def test_a_lots_karat_carries_to_its_partitions_and_a_partition_cannot_set_its_own(self):
        lot = self.lot()
        piece = self.draw(lot["id"], "10", 400000).data
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{piece['id']}", {"karat": 21})),
                         "A partition takes its karat from its lot — change it on the lot")
        self.patch(ARNEL, f"/items/{lot['id']}", {"karat": 21}, expect=200)
        self.assertEqual(Item.objects.get(pk=piece["id"]).karat, 21)
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/items/{lot['id']}", {"type": "silver", "karat": 925})),
                         "A lot with partitions cannot change metal — its pieces are already drawn")
