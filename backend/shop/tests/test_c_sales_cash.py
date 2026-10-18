"""Stage (c): sales and the three-account cash ledger. Ported from the app's
sell_repository_test, cash_ledger_test, cash_entry_edit_test,
customer_test (split settlement) and cart_state_test."""

from shop.enums import CashAccount
from shop.models import Branch, CashEntry, Item, Sale
from shop.services import cash

from .helpers import ARNEL, BEN, D_SUP, GRACE, JOEL, K_SUP, PAOLO, RHEA, ApiTestCase


def balance(branch, account) -> int:
    return cash.account_balance(branch, account)


class SaleFlowMixin:
    def goods(self, **kwargs):
        return self.released_item(type="goods", **kwargs)

    def order(self, item_ids, price=900000, *, by=RHEA, branch="kidapawan", payment=None, expect=201, **extra):
        prices = price if isinstance(price, list) else [price] * len(item_ids)
        body = {"branch": branch, "customer": {"name": "Test Customer"},
                "lines": [{"item_id": i, "negotiated_price_centavos": p} for i, p in zip(item_ids, prices)],
                "payment": payment or {"cash_centavos": sum(prices)}, **extra}
        return self.post(by, "/sales", body, expect=expect)

    def pay(self, sale_id, cash_c=0, bank_c=0, *, by=GRACE, expect=200):
        return self.post(by, f"/sales/{sale_id}/complete", {"cash_centavos": cash_c, "bank_centavos": bank_c},
                         expect=expect)


class SaleTests(SaleFlowMixin, ApiTestCase):
    def test_sellable_goods_exclude_scrap_and_unverified_pieces(self):
        goods = self.goods()
        scrap = self.released_item(type="scrap")
        unverified = self.purchase().data["items"][0]
        ids = [i["id"] for i in self.get(RHEA, "/items/sellable").data["results"]]
        self.assertIn(goods["id"], ids)
        self.assertNotIn(scrap["id"], ids)
        self.assertNotIn(unverified["id"], ids)

    def test_checkout_holds_the_pieces_and_moves_no_cash(self):
        item = self.goods()
        before = {a: balance("kidapawan", a) for a in CashAccount.values}
        sale = self.order([item["id"]]).data
        self.assertEqual(sale["verification_status"], "awaitingVerification")
        self.assertEqual(Item.objects.get(pk=item["id"]).item_status, "reserved")
        self.assertEqual({a: balance("kidapawan", a) for a in CashAccount.values}, before)
        self.assertEqual(CashEntry.objects.filter(linked_record_id=sale["id"]).count(), 0)
        ids = [i["id"] for i in self.get(RHEA, "/items/sellable").data["results"]]
        self.assertNotIn(item["id"], ids)

    def test_completing_marks_pieces_sold_and_credits_sales_cash_only(self):
        item = self.goods()
        sale = self.order([item["id"]]).data
        float_before, bank_before = balance("kidapawan", "purchase"), balance("kidapawan", "bank")
        done = self.pay(sale["id"], cash_c=900000).data
        self.assertEqual(done["verification_status"], "verified")
        self.assertEqual(done["received_by"]["id"], GRACE)
        self.assertEqual(done["submitted_by"]["id"], RHEA)
        self.assertEqual(Item.objects.get(pk=item["id"]).item_status, "sold")
        self.assertEqual(balance("kidapawan", "sales"), 900000)
        self.assertEqual(balance("kidapawan", "purchase"), float_before, "sale takings never top up the float")
        self.assertEqual(balance("kidapawan", "bank"), bank_before)
        entry = CashEntry.objects.get(linked_record_id=sale["id"])
        self.assertEqual((entry.type, entry.account, entry.source_type), ("cashIn", "sales", "sale"))

    def test_a_bank_payment_credits_only_the_bank(self):
        sale = self.order([self.goods()["id"]], payment={"bank_centavos": 900000}).data
        self.pay(sale["id"], bank_c=900000)
        self.assertEqual((balance("kidapawan", "sales"), balance("kidapawan", "bank")), (0, 900000))
        self.assertEqual(list(CashEntry.objects.filter(linked_record_id=sale["id"]).values_list("account", flat=True)),
                         ["bank"])

    # Acceptance 2 -----------------------------------------------------------
    def test_a_split_payment_puts_cash_in_sales_and_the_transfer_in_bank_and_leaves_purchase_alone(self):
        sale = self.order([self.goods()["id"]], price=1000000).data
        float_before = balance("kidapawan", "purchase")
        self.pay(sale["id"], cash_c=400000, bank_c=600000)
        self.assertEqual(balance("kidapawan", "sales"), 400000)
        self.assertEqual(balance("kidapawan", "bank"), 600000)
        self.assertEqual(balance("kidapawan", "purchase"), float_before)
        entries = {e.account: e for e in CashEntry.objects.filter(linked_record_id=sale["id"])}
        self.assertEqual(set(entries), {"sales", "bank"})
        self.assertEqual((entries["sales"].amount_centavos, entries["bank"].amount_centavos), (400000, 600000))
        self.assertTrue(entries["sales"].note.endswith("(cash portion)"))
        self.assertIn("(₱4,000.00 cash, ₱6,000.00 bank)", self.last_log().summary)

    def test_payment_must_add_up_to_the_order(self):
        sale = self.order([self.goods()["id"]], price=1000000).data
        self.assertEqual(self.refusal(self.pay(sale["id"], cash_c=400000, expect=None)),
                         "Payment of ₱4,000.00 does not match the order total of ₱10,000.00")
        self.assertEqual(Sale.objects.get(pk=sale["id"]).verification_status, "awaitingVerification")
        self.pay(sale["id"], cash_c=1000000)
        self.assertEqual(self.refusal(self.pay(sale["id"], cash_c=1000000, expect=None)),
                         "Payment for this order was already received")

    def test_a_returned_order_keeps_its_pieces_and_resubmitting_clears_the_note(self):
        item = self.goods()
        sale = self.order([item["id"]]).data
        self.refusal(self.post(GRACE, f"/sales/{sale['id']}/return", {"note": ""}))
        returned = self.post(GRACE, f"/sales/{sale['id']}/return", {"note": "Price looks wrong, please recheck"},
                             expect=200).data
        self.assertEqual(returned["verification_status"], "returnedForCorrection")
        self.assertEqual(Item.objects.get(pk=item["id"]).item_status, "reserved", "still held")
        self.refusal(self.pay(sale["id"], cash_c=900000, expect=None))

        resubmitted = self.post(RHEA, f"/sales/{sale['id']}/resubmit", {
            "lines": [{"item_id": item["id"], "negotiated_price_centavos": 950000}],
            "payment": {"cash_centavos": 950000},
        }, expect=200).data
        self.assertEqual((resubmitted["verification_status"], resubmitted["verification_note"],
                          resubmitted["total_centavos"]), ("awaitingVerification", None, 950000))
        self.assertIn({"field": "Total", "before": "₱9,000.00", "after": "₱9,500.00"}, self.last_log().changes)

    def test_resubmitting_without_a_piece_puts_it_back_on_sale(self):
        a, b = self.goods(), self.goods()
        sale = self.order([a["id"], b["id"]]).data
        self.post(GRACE, f"/sales/{sale['id']}/return", {"note": "Drop the second piece"}, expect=200)
        self.post(RHEA, f"/sales/{sale['id']}/resubmit",
                  {"lines": [{"item_id": a["id"], "negotiated_price_centavos": 900000}]}, expect=200)
        self.assertEqual(Item.objects.get(pk=b["id"]).item_status, "listed")
        self.assertEqual(Item.objects.get(pk=a["id"]).item_status, "reserved")

    def test_a_piece_cannot_be_in_two_open_orders(self):
        item = self.goods()
        sale = self.order([item["id"]]).data
        message = self.refusal(self.order([item["id"]], expect=None))
        self.assertEqual(message, f'"Test goods" is already held for order {sale["id"]}')

    def test_scrap_is_never_sold_over_the_counter(self):
        scrap = self.released_item(type="scrap")
        self.assertEqual(self.refusal(self.order([scrap["id"]], expect=None)),
                         "Scrap is never sold over the counter — it leaves through a disposal batch")

    def test_every_piece_in_an_order_comes_from_the_same_branch(self):
        davao = self.goods(branch="davao")
        self.assertEqual(self.refusal(self.order([davao["id"]], by=ARNEL, expect=None)),
                         "Every piece in an order has to come from the same branch")

    def test_counter_work_is_shared_but_stays_inside_the_branch(self):
        item = self.goods()
        self.refusal(self.order([item["id"]], by=PAOLO, expect=None), 403)  # Davao staff, Kidapawan piece
        sale = self.order([item["id"]], by=GRACE).data  # a Cashier may build an order
        self.refusal(self.pay(sale["id"], cash_c=900000, by=BEN, expect=None), 403)  # the other branch
        self.pay(sale["id"], cash_c=900000, by=RHEA)  # a Sales Rep may take the payment

    def test_a_customer_history_spans_both_directions_of_trade(self):
        batch = self.purchase(customer="Two-way Tina").data
        self.release(batch["id"])
        sale = self.post(RHEA, "/sales", {"branch": "kidapawan", "customer": {"name": "two-way tina"},
                                          "lines": [{"item_id": batch["items"][0]["id"],
                                                     "negotiated_price_centavos": 800000}]}, expect=201).data
        detail = self.get(RHEA, f"/customers/{batch['customer']['id']}").data
        self.assertEqual([p["id"] for p in detail["purchases"]], [batch["id"]])
        self.assertEqual([s["id"] for s in detail["sales"]], [sale["id"]])

    def test_a_completed_sale_still_shows_what_was_sold_after_a_correction(self):
        item = self.goods()
        sale = self.order([item["id"]]).data
        self.pay(sale["id"], cash_c=900000)
        Item.objects.filter(pk=item["id"]).update(description="Renamed later")
        line = self.get(GRACE, f"/sales/{sale['id']}").data["lines"][0]
        self.assertEqual((line["item"]["description"], line["item"]["as_sold"]), ("Test goods", True))


class CartHoldTests(SaleFlowMixin, ApiTestCase):
    def test_holding_and_releasing_a_piece(self):
        item = self.goods()
        held = self.post(RHEA, f"/items/{item['id']}/reserve", expect=200).data
        self.assertEqual(held["item_status"], "reserved")
        self.assertEqual(self.last_log().action, "itemReserved")
        self.refusal(self.post(RHEA, f"/items/{item['id']}/reserve"))
        released = self.post(RHEA, f"/items/{item['id']}/release-reservation", expect=200).data
        self.assertEqual(released["item_status"], "listed")
        self.assertEqual(self.refusal(self.post(RHEA, f"/items/{item['id']}/release-reservation")),
                         '"Test goods" is not being held')

    def test_a_cart_hold_becomes_the_order_and_an_order_hold_cannot_be_dropped(self):
        item = self.goods()
        self.post(RHEA, f"/items/{item['id']}/reserve", expect=200)
        sale = self.order([item["id"]]).data
        message = self.refusal(self.post(RHEA, f"/items/{item['id']}/release-reservation"))
        self.assertIn(f"held by order {sale['id']}", message)


class CashLedgerTests(ApiTestCase):
    """The cash ledger belongs to whoever runs the branch: Kim (Kidapawan
    Supervisor), Dan (Davao Supervisor), and Arnel (Admin) at both."""

    def setUp(self):
        super().setUp()
        self.add_supervisors()
        Branch.objects.filter(pk="kidapawan").update(
            starting_purchase_cash_centavos=159840300, starting_sales_cash_centavos=0, starting_bank_centavos=25850000)
        Branch.objects.filter(pk="davao").update(
            starting_purchase_cash_centavos=128776900, starting_bank_centavos=18420000)

    def entry(self, *, by=K_SUP, branch="kidapawan", type="cashIn", account="purchase", amount=500000, note="Owner capital",
              category=None, expect=201):
        body = {"branch": branch, "type": type, "account": account, "amount_centavos": amount, "note": note}
        if category is not None:
            body["category"] = category
        return self.post(by, "/cash/entries", body, expect=expect)

    def transfer(self, *, by=ARNEL, from_branch="kidapawan", to_branch="davao", from_account="purchase",
                 to_account="purchase", amount=300000, note="Rebalancing", expect=201):
        return self.post(by, "/cash/transfers", {"from_branch": from_branch, "to_branch": to_branch,
                                                  "from_account": from_account, "to_account": to_account,
                                                  "amount_centavos": amount, "note": note}, expect=expect)

    def test_cash_in_raises_and_expense_and_withdrawal_lower_the_balance(self):
        self.entry(amount=500000)
        self.assertEqual(balance("kidapawan", "purchase"), 159840300 + 500000)
        self.entry(by=D_SUP, branch="davao", type="expense", amount=200000, note="Electricity", category="Utilities")
        self.entry(by=D_SUP, branch="davao", type="withdrawal", amount=100000, note="Owner withdrawal")
        self.assertEqual(balance("davao", "purchase"), 128776900 - 300000)
        self.assertEqual(self.last_log().action, "cashEntryRecorded")

    def test_manual_entries_need_a_note_an_amount_and_for_expenses_a_category(self):
        self.assertEqual(self.refusal(self.entry(note=" ", expect=None)), "An entry needs a note")
        self.assertEqual(self.refusal(self.entry(amount=0, expect=None)), "Amount must be above zero")
        self.assertEqual(self.refusal(self.entry(type="expense", expect=None)), "An expense needs a category")
        self.assertEqual(self.refusal(self.entry(type="transferOut", expect=None)),
                         "Transfers must go through a transfer so both sides stay matched")

    def test_a_transfer_moves_money_as_one_matched_pair(self):
        kid, dav = balance("kidapawan", "purchase"), balance("davao", "purchase")
        combined = kid + dav
        pair = self.transfer().data
        self.assertEqual(pair["out"]["transfer_pair_id"], pair["in"]["transfer_pair_id"])
        self.assertEqual((pair["out"]["type"], pair["in"]["type"]), ("transferOut", "transferIn"))
        self.assertEqual(balance("kidapawan", "purchase"), kid - 300000)
        self.assertEqual(balance("davao", "purchase"), dav + 300000)
        self.assertEqual(balance("kidapawan", "purchase") + balance("davao", "purchase"), combined)

    def test_a_transfer_can_move_between_pots_of_one_branch_but_must_go_somewhere(self):
        self.entry(account="sales", amount=6000000, note="Takings")
        self.transfer(from_branch="kidapawan", to_branch="kidapawan", from_account="sales", to_account="purchase",
                      amount=5000000)
        self.assertEqual(balance("kidapawan", "sales"), 1000000)
        self.assertEqual(self.refusal(self.transfer(from_branch="davao", to_branch="davao", from_account="bank",
                                                    to_account="bank", amount=100, expect=None)),
                         "A transfer needs a different branch or a different cash source")

    def test_balances_endpoint_reports_opening_current_and_today(self):
        self.entry(account="sales", amount=300000, note="Walk-in")
        self.entry(type="expense", account="sales", amount=50000, note="Snacks", category="Other")
        data = self.get(GRACE, "/cash/balances").data["kidapawan"]["sales"]
        self.assertEqual((data["opening_centavos"], data["current_centavos"], data["today_in_centavos"],
                          data["today_out_centavos"]), (0, 250000, 300000, 50000))

    # Acceptance 3 -----------------------------------------------------------
    def test_each_branch_balance_is_always_opening_plus_its_own_entries(self):
        def check():
            for branch in Branch.objects.all():
                for account in CashAccount.values:
                    entries = CashEntry.objects.filter(branch=branch, account=account)
                    expected = branch.starting_balance(account) + sum(e.signed_amount_centavos for e in entries)
                    self.assertEqual(cash.account_balance(branch, account), expected, f"{branch.id} {account}")
                    reported = self.get(ARNEL, "/branches").data
                    shown = next(b for b in reported if b["id"] == branch.id)["accounts"][account]["current_centavos"]
                    self.assertEqual(shown, expected)

        check()
        batch = self.purchase().data
        check()
        self.release(batch["id"])
        check()
        item = self.released_item(type="goods")
        sale = self.post(RHEA, "/sales", {"branch": "kidapawan", "customer": {"name": "B"},
                                          "lines": [{"item_id": item["id"], "negotiated_price_centavos": 1000000}]},
                         expect=201).data
        self.post(GRACE, f"/sales/{sale['id']}/complete", {"cash_centavos": 300000, "bank_centavos": 700000},
                  expect=200)
        check()
        self.transfer(to_account="bank", amount=123456)
        self.entry(by=D_SUP, branch="davao", type="expense", account="bank", amount=1500, note="Bank charges",
                   category="Other")
        check()
        manual = self.entry(amount=777).data
        self.patch(K_SUP, f"/cash/entries/{manual['id']}", {"amount_centavos": 999, "account": "sales"}, expect=200)
        check()
        self.delete(K_SUP, f"/cash/entries/{manual['id']}", {"reason": "typo"}, expect=204)
        check()
        # No stored balance anywhere: the branch row holds only opening figures.
        branch_columns = {f.name for f in Branch._meta.get_fields()}
        self.assertFalse({c for c in branch_columns if "balance" in c or "current" in c})

    # Acceptance 7 -----------------------------------------------------------
    def test_a_linked_entry_cannot_be_edited_or_deleted_but_a_manual_one_can(self):
        batch = self.purchase().data
        linked = self.release(batch["id"]).data["cash_entry"]
        message = self.refusal(self.patch(K_SUP, f"/cash/entries/{linked['id']}", {"amount_centavos": 1}))
        self.assertEqual(message, f"This entry was written by a purchase ({batch['id']}). "
                                  "Correct it on that record, not in the cash history.")
        self.refusal(self.delete(K_SUP, f"/cash/entries/{linked['id']}"))
        self.assertTrue(CashEntry.objects.filter(pk=linked["id"]).exists())

        before = balance("davao", "purchase")
        manual = self.entry(by=D_SUP, branch="davao", type="expense", amount=500000, note="Electric bill",
                            category="Utilities").data
        response = self.patch(D_SUP, f"/cash/entries/{manual['id']}",
                              {"amount_centavos": 50000, "note": "Electric bill (typo fixed)"}, expect=200).data
        self.assertEqual({c["field"] for c in response["changes"]}, {"Amount", "Note"})
        self.assertEqual(balance("davao", "purchase"), before - 50000)
        log = self.last_log()
        self.assertEqual((log.action, log.record_id), ("cashEntryEdited", manual["id"]))
        self.assertIn("5,000", next(c for c in log.changes if c["field"] == "Amount")["before"])

        self.delete(D_SUP, f"/cash/entries/{manual['id']}", {"reason": "entered twice"}, expect=204)
        self.assertEqual(balance("davao", "purchase"), before)
        log = self.last_log()
        self.assertEqual(log.action, "cashEntryDeleted")
        self.assertIn("entered twice", log.summary)
        self.assertTrue(log.changes)

    def test_both_halves_of_a_transfer_move_together(self):
        kid, dav_bank = balance("kidapawan", "purchase"), balance("davao", "bank")
        pair = self.transfer(to_account="bank", amount=300000, note="Deposit").data
        self.patch(ARNEL, f"/cash/entries/{pair['in']['id']}", {"amount_centavos": 200000}, expect=200)
        self.assertEqual(CashEntry.objects.get(pk=pair["out"]["id"]).amount_centavos, 200000)
        self.assertEqual(CashEntry.objects.get(pk=pair["in"]["id"]).amount_centavos, 200000)
        self.assertEqual(balance("kidapawan", "purchase"), kid - 200000)
        self.assertEqual(self.refusal(self.patch(ARNEL, f"/cash/entries/{pair['out']['id']}", {"type": "expense"})),
                         "A transfer stays a transfer — delete it and record a new entry instead")
        self.delete(ARNEL, f"/cash/entries/{pair['out']['id']}", expect=204)
        self.assertFalse(CashEntry.objects.filter(pk=pair["in"]["id"]).exists())
        self.assertEqual((balance("kidapawan", "purchase"), balance("davao", "bank")), (kid, dav_bank))

    def test_moving_an_entry_to_another_pot_moves_the_money_and_type_change_drops_category(self):
        manual = self.entry(by=D_SUP, branch="davao", type="expense", amount=500000, note="Bill",
                            category="Utilities").data
        float_before, sales_before = balance("davao", "purchase"), balance("davao", "sales")
        self.patch(D_SUP, f"/cash/entries/{manual['id']}", {"account": "sales"}, expect=200)
        self.assertEqual(balance("davao", "purchase"), float_before + 500000)
        self.assertEqual(balance("davao", "sales"), sales_before - 500000)
        self.patch(D_SUP, f"/cash/entries/{manual['id']}", {"type": "withdrawal"}, expect=200)
        updated = CashEntry.objects.get(pk=manual["id"])
        self.assertEqual((updated.type, updated.category), ("withdrawal", None))

    def test_cash_roles_and_branches(self):
        self.refusal(self.entry(by=RHEA, expect=None), 403)
        self.refusal(self.entry(by=D_SUP, branch="kidapawan", expect=None), 403)
        self.refusal(self.transfer(by=JOEL, expect=None), 403)
        manual = self.entry().data
        self.refusal(self.delete(D_SUP, f"/cash/entries/{manual['id']}"), 403)
