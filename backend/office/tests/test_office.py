"""The back office at /administrator/: Superuser only, on every page; it never
shadows the Flutter app, the API or Django's admin; and a write made on a page
is the same write — same log entry, same sync change — as through the API."""

import json
import tempfile
from pathlib import Path

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client, override_settings
from django.urls import URLPattern, reverse

from accounts.models import User
from office import urls as office_urls
from office.access import REFUSED
from shop.models import CashEntry, Commitment, DisposalBatch, Item, SyncChange, TransactionLog
from shop.models import RecordId
from shop.tests.helpers import ARNEL, BEN, GRACE, K_SUP, PIN, ApiTestCase, png_bytes
from shop.tests.test_m_webapp import INDEX, fake_build

SAM = "USR-SU01"  # the Superuser: whoever maintains the system
FIXTURE = Path(__file__).resolve().parents[2] / "shop" / "tests" / "fixtures" / "app_demo_snapshot.json"


def page_paths() -> list[str]:
    """One address for every guarded page, with placeholder ids — the guard
    answers before any record is looked up."""
    args = {"pk": "NOPE42", "karat": 18, "fmt": "csv"}
    paths = []
    for pattern in office_urls.pages:
        assert isinstance(pattern, URLPattern)
        if pattern.name == "not-found":
            paths.append("/administrator/no/such/page/")
            continue
        kwargs = {name: args[name] for name in pattern.pattern.converters}
        paths.append(reverse(f"office:{pattern.name}", kwargs=kwargs))
    return paths


class OfficeTestCase(ApiTestCase):
    def setUp(self):
        super().setUp()
        user = User(id=SAM, name="Sam Superuser", role="superuser")
        user.set_password(PIN)
        user.save()
        RecordId.objects.get_or_create(id=SAM, defaults={"kind": "user"})
        self.staff[SAM] = user
        self.office = self.browser_for(SAM)

    def browser_for(self, user_id) -> Client:
        browser = Client()
        browser.force_login(User.objects.get(pk=user_id), backend="accounts.backends.PinBackend")
        return browser


class WhoGetsInTests(OfficeTestCase):
    def assert_refused_kindly(self, response, path):
        self.assertEqual(response.status_code, 403, path)
        self.assertContains(response, "This is the back office", status_code=403)
        self.assertContains(response, REFUSED, status_code=403)
        self.assertContains(response, 'href="/"', status_code=403, msg_prefix=f"{path} points to the app")
        self.assertNotContains(response, "Traceback", status_code=403)

    def test_the_admin_the_owner_is_refused_on_every_page_not_just_the_first(self):
        owner = self.browser_for(ARNEL)
        logged = TransactionLog.objects.count()
        paths = page_paths()
        self.assertGreater(len(paths), 30)
        with self.assertLogs("django.request", "WARNING"):  # each refusal is logged as a 403
            for path in paths:
                self.assert_refused_kindly(owner.get(path), path)
                self.assert_refused_kindly(owner.post(path, {"amount": "100", "note": "x"}), path)
        self.assertEqual(TransactionLog.objects.count(), logged, "a refused person changed nothing")

    def test_a_supervisor_and_a_cashier_are_refused_too(self):
        self.add_supervisors()
        for user_id in (K_SUP, GRACE, BEN):
            browser = self.browser_for(user_id)
            with self.assertLogs("django.request", "WARNING"):
                for path in page_paths():
                    self.assert_refused_kindly(browser.get(path), path)

    def test_the_superuser_is_let_in(self):
        response = self.office.get("/administrator/")
        self.assertContains(response, "The shop today")
        self.assertContains(response, "Kidapawan")
        self.assertContains(response, "Sam Superuser")

    def test_every_page_carries_the_guard(self):
        for pattern in office_urls.pages:
            self.assertTrue(getattr(pattern.callback, "superuser_only", False), pattern.name)

    def test_the_owner_cannot_sign_in_and_is_told_where_their_work_is(self):
        response = Client().post(reverse("office:login"), {"username": "Arnel Javier", "password": PIN})
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, REFUSED)
        self.assertContains(response, "Open the app")
        self.assertNotIn("_auth_user_id", response.wsgi_request.session)

    def test_the_superuser_signs_in_with_name_and_pin(self):
        browser = Client()
        response = browser.post(reverse("office:login"), {"username": "sam superuser", "password": PIN})
        self.assertRedirects(response, "/administrator/", fetch_redirect_response=False)
        self.assertEqual(browser.get("/administrator/staff/").status_code, 200)
        wrong = Client().post(reverse("office:login"), {"username": SAM, "password": "0000"})
        self.assertContains(wrong, "That name and PIN don&#x27;t match")

    def test_signed_out_people_are_sent_to_the_sign_in(self):
        response = Client().get("/administrator/cash/?branch=davao")
        self.assertEqual(response.status_code, 302)
        self.assertTrue(response["Location"].startswith("/administrator/login/?next="))
        htmx = Client().get("/administrator/cash/", HTTP_HX_REQUEST="true")
        self.assertEqual(htmx.status_code, 204)
        self.assertIn("/administrator/login/", htmx["HX-Redirect"])

    def test_a_superuser_made_admin_mid_session_is_refused_on_the_next_page(self):
        from shop.admin_tools import run
        from shop.services.base import Ctx

        from accounts.services import update_user

        other = User(id="USR-SU02", name="Second Superuser", role="superuser")
        other.set_password(PIN)
        other.save()
        RecordId.objects.get_or_create(id="USR-SU02", defaults={"kind": "user"})
        self.assertEqual(self.office.get("/administrator/").status_code, 200)
        run(lambda: update_user(Ctx.for_user(other), SAM, role="admin"))
        self.assertEqual(self.office.get("/administrator/").status_code, 403)


class WhereItSitsTests(OfficeTestCase):
    """Next to the desktop app, the API and Django's admin, shadowing none of them."""

    def setUp(self):
        super().setUp()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = fake_build(Path(tmp.name) / "web")
        override = override_settings(WEB_APP_ROOT=str(root), WHITENOISE_ROOT=str(root))
        override.enable()
        self.addCleanup(override.disable)

    def test_administrator_is_the_office_not_the_apps_index_html(self):
        page = self.office.get("/administrator/")
        self.assertEqual(page.status_code, 200)
        self.assertNotEqual(page.content, INDEX)
        self.assertContains(page, "The shop today")
        anonymous = Client().get("/administrator/")
        self.assertEqual(anonymous.status_code, 302)
        self.assertIn("/administrator/login/", anonymous["Location"])
        self.assertEqual(Client().get("/administrator/login/").status_code, 200)
        self.assertRedirects(Client().get("/administrator"), "/administrator/", fetch_redirect_response=False)

    def test_an_unknown_office_address_is_the_offices_404(self):
        response = self.office.get("/administrator/cash/what/is/this")
        self.assertEqual(response.status_code, 404)
        self.assertNotEqual(response.content, INDEX)
        self.assertContains(response, "Nothing here", status_code=404)

    def test_the_api_and_django_admin_still_work(self):
        browser = Client()
        self.assertEqual(len(browser.get("/api/v1/auth/staff").json()), 8)
        admin = browser.get("/admin/")
        self.assertEqual(admin.status_code, 302)
        self.assertIn("/admin/login/", admin["Location"])
        self.assertEqual(self.get(SAM, "/cash/balances").status_code, 200)

    def test_the_flutter_app_is_untouched(self):
        browser = Client()
        for path in ("/", "/cash", "/purchases/A3T8QD", "/administratorish"):
            response = browser.get(path)
            self.assertEqual((response.status_code, response.content), (200, INDEX), path)
            self.assertEqual(response["Cache-Control"], "no-store", path)


@override_settings(WEB_APP_ROOT="", WHITENOISE_ROOT=None)
class WithoutTheAppTests(OfficeTestCase):
    def test_the_office_works_with_no_app_deployed(self):
        self.assertContains(self.office.get("/administrator/"), "The shop today")
        self.assertContains(Client().get("/"), "No desktop app has been deployed")


class SameWriteAsTheApiTests(OfficeTestCase):
    """A page write and the API write leave the same trail. This is the thing
    that would rot silently, so both the log row and the sync rows are compared."""

    def trail(self, do):
        """What one write leaves: its log row, and the sync rows it added."""
        last_log = set(TransactionLog.objects.values_list("id", flat=True))
        last_seq = SyncChange.objects.order_by("-seq").values_list("seq", flat=True).first() or 0
        do()
        new_logs = TransactionLog.objects.exclude(id__in=last_log)
        self.assertEqual(new_logs.count(), 1, "exactly one log row per write")
        log = new_logs.get()
        sync = list(SyncChange.objects.filter(seq__gt=last_seq).order_by("seq").values_list("kind", "record_id"))
        return log, sync

    @staticmethod
    def shape(log, sync, record_ids):
        """The trail with this write's own ids taken out, so two writes compare."""
        names = {log.id: "<log>", **{rid: f"<record{i}>" for i, rid in enumerate(record_ids)}}
        return ({"action": log.action, "category": log.category, "summary": log.summary, "branch": log.branch_id,
                 "record_kind": log.record_kind, "amount": log.amount_centavos, "user": log.user_id,
                 "role": log.role, "changes": log.changes, "record": names.get(log.record_id)},
                [(kind, names.get(rid, rid)) for kind, rid in sync])

    def test_a_cash_entry_from_a_page_matches_one_from_the_api(self):
        page_log, page_sync = self.trail(lambda: self.assertEqual(self.office.post(reverse("office:cash-new"), {
            "branch": "kidapawan", "type": "expense", "account": "purchase", "amount": "1,500.50",
            "note": "Light bulbs", "category": "Supplies"}).status_code, 302))
        api_log, api_sync = self.trail(lambda: self.post(SAM, "/cash/entries", {
            "branch": "kidapawan", "type": "expense", "account": "purchase", "amount_centavos": 150050,
            "note": "Light bulbs", "category": "Supplies"}, expect=201))
        page_entry, api_entry = page_log.record_id, api_log.record_id
        self.assertEqual(CashEntry.objects.get(pk=page_entry).amount_centavos, 150050)
        self.assertEqual(self.shape(page_log, page_sync, [page_entry]), self.shape(api_log, api_sync, [api_entry]))
        self.assertIn(("cashEntries", "<record0>"), self.shape(page_log, page_sync, [page_entry])[1])
        self.assertEqual(page_log.user_id, SAM)

    def test_an_item_correction_from_a_page_matches_one_from_the_api(self):
        first = self.released_item()
        second = self.released_item()
        form = {"description": "Corrected ring", "type": "goods", "karat": 18, "weight_grams": "9.500",
                "gross_weight_grams": "9.500", "amount": "4800"}
        page_log, page_sync = self.trail(lambda: self.office.post(
            reverse("office:item-correct", args=[first["id"]]), form))
        api_log, api_sync = self.trail(lambda: self.patch(SAM, f"/items/{second['id']}", {
            "description": "Corrected ring", "weight_grams": "9.500", "amount_centavos": 480000}, expect=200))
        self.assertEqual(self.shape(page_log, page_sync, [first["id"]]), self.shape(api_log, api_sync, [second["id"]]))
        self.assertEqual(Item.objects.get(pk=first["id"]).description, "Corrected ring")

    def test_a_commitment_and_its_cash_from_pages_match_the_api(self):
        page_log, page_sync = self.trail(lambda: self.office.post(reverse("office:commitment-new"), {
            "lender": "Golden Lending", "amount": "50000", "rate": "3000", "branch": "davao"}))
        api_log, api_sync = self.trail(lambda: self.post(SAM, "/commitments", {
            "lender": "Golden Lending", "amount_centavos": 5000000, "rate_per_gram_centavos": 300000,
            "branch": "davao"}, expect=201))
        page_id, api_id = page_log.record_id, api_log.record_id
        self.assertEqual(self.shape(page_log, page_sync, [page_id]), self.shape(api_log, api_sync, [api_id]))

        photo = SimpleUploadedFile("cash.png", png_bytes(), content_type="image/png")
        page_log, page_sync = self.trail(lambda: self.office.post(
            reverse("office:commitment-receive", args=[page_id]), {"photo": photo}))
        api_log, api_sync = self.trail(lambda: self.post(SAM, f"/commitments/{api_id}/receive",
                                                         {"proof_photo": SimpleUploadedFile(
                                                             "cash.png", png_bytes(), content_type="image/png")},
                                                         fmt="multipart", expect=200))
        page_cash = CashEntry.objects.get(linked_record_id=page_id).id
        api_cash = CashEntry.objects.get(linked_record_id=api_id).id
        self.assertEqual(self.shape(page_log, page_sync, [page_id, page_cash]),
                         self.shape(api_log, api_sync, [api_id, api_cash]))


class DeskWritesTests(OfficeTestCase):
    def test_a_refusal_is_the_services_own_sentence_and_saves_nothing(self):
        count = CashEntry.objects.count()
        response = self.office.post(reverse("office:cash-new"), {
            "branch": "davao", "type": "cashIn", "account": "sales", "amount": "0", "note": "Float"})
        self.assertContains(response, "Amount must be above zero", status_code=422)
        response = self.office.post(reverse("office:cash-new"), {
            "branch": "davao", "type": "expense", "account": "sales", "amount": "20", "note": "Snacks"})
        self.assertContains(response, "An expense needs a category", status_code=422)
        self.assertEqual(CashEntry.objects.count(), count)

    def test_a_transfer_correction_and_delete_go_through_the_ledger(self):
        response = self.office.post(reverse("office:cash-transfer"), {
            "from_branch": "kidapawan", "from_account": "sales", "to_branch": "davao", "to_account": "purchase",
            "amount": "2000", "note": "Float for Davao"})
        self.assertEqual(response.status_code, 302)
        out = CashEntry.objects.get(type="transferOut")
        edit = self.office.get(reverse("office:cash-edit", args=[out.id]))
        self.assertContains(edit, "Float for Davao")
        response = self.office.post(reverse("office:cash-edit", args=[out.id]), {
            "account": "sales", "destination_account": "purchase", "amount": "2500.00", "note": "Float for Davao",
            "date": edit.context["form"]["date"].value()})
        self.assertEqual(response.status_code, 302)
        self.assertEqual(set(CashEntry.objects.values_list("amount_centavos", flat=True)), {250000})
        log = TransactionLog.objects.filter(action="cashEntryEdited").get()
        self.assertEqual([c["field"] for c in log.changes], ["Amount"], "an untouched date is not a correction")
        response = self.office.post(reverse("office:cash-delete", args=[out.id]), {"reason": "Typed twice"})
        self.assertEqual(response.status_code, 302)
        self.assertFalse(CashEntry.objects.exists())
        self.assertIn("Typed twice", TransactionLog.objects.get(action="cashEntryDeleted").summary)

    def test_a_linked_entry_is_not_editable_by_hand(self):
        item = self.released_item()
        entry = CashEntry.objects.get(linked_record_id=item["batch_id"])
        response = self.office.get(reverse("office:cash-edit", args=[entry.id]), follow=True)
        self.assertContains(response, "Correct it on that record")

    def test_a_disposal_runs_from_the_pool_against_a_received_loan(self):
        scrap = self.released_item(type="scrap", grams="20.000", amount=1000000)
        self.office.post(reverse("office:commitment-new"), {"lender": "Metro Gold", "amount": "100000",
                                                            "rate": "3000", "branch": "kidapawan"})
        loan = Commitment.objects.get()
        self.office.post(reverse("office:commitment-receive", args=[loan.id]),
                         {"photo": SimpleUploadedFile("cash.png", png_bytes(), content_type="image/png")})
        page = self.office.get(reverse("office:disposal-new"), {"branch": "kidapawan"})
        self.assertContains(page, scrap["id"])
        self.assertContains(page, "Metro Gold")
        response = self.office.post(f"{reverse('office:disposal-new')}?branch=kidapawan", {
            "items": [scrap["id"]], "commitment": loan.id, "gross_grams": "19.500", "gross_amount": "11000"})
        self.assertEqual(response.status_code, 302, response.content[:2000])
        batch = DisposalBatch.objects.get()
        self.assertEqual(batch.gross_amount_centavos, 1100000)
        self.assertEqual(TransactionLog.objects.filter(action="disposalCompleted", user_id=SAM).count(), 1)

    def test_staff_are_managed_within_the_role_rules(self):
        response = self.office.post(reverse("office:staff-new"), {
            "name": "Nina Cruz", "role": "cashier", "home_branch": "davao", "pin": "4321"})
        self.assertEqual(response.status_code, 302)
        nina = User.objects.get(name="Nina Cruz")
        self.assertTrue(nina.check_password("4321"))
        self.office.post(reverse("office:staff-edit", args=[nina.id]), {
            "name": "Nina Cruz", "role": "cashier", "home_branch": "kidapawan", "contact_number": ""})
        self.assertEqual(User.objects.get(pk=nina.id).home_branch, "kidapawan")
        self.office.post(reverse("office:staff-pin", args=[nina.id]), {"pin": "9876", "again": "9876"})
        self.assertTrue(User.objects.get(pk=nina.id).check_password("9876"))
        self.office.post(reverse("office:staff-active", args=[nina.id]), {"active": "0"})
        self.assertFalse(User.objects.get(pk=nina.id).active)
        refused = self.office.post(reverse("office:staff-active", args=[SAM]), {"active": "0"})
        self.assertContains(refused, "You can&#x27;t deactivate yourself", status_code=422)

    def test_rates_change_and_keep_their_history(self):
        self.post(SAM, "/rates", {"karat": 18, "price_per_gram_centavos": 300000}, expect=201)
        response = self.office.post(reverse("office:rate-update", args=[18]), {"price": "3,250"})
        self.assertEqual(response.status_code, 302)
        page = self.office.get(reverse("office:rates"))
        self.assertContains(page, "₱3,250.00")
        self.assertContains(page, "₱3,000.00")  # the history keeps the old price


class EveryPageOpensTests(OfficeTestCase):
    """With the app's demo data imported, every list, detail and report renders."""

    def setUp(self):
        super().setUp()
        self.post(ARNEL, "/sync/import", json.loads(FIXTURE.read_text(encoding="utf-8")), expect=200)

    def test_lists_details_reports_and_the_log(self):
        from shop.models import Customer, PurchaseBatch, Sale

        for name in ("today", "purchases", "sales", "items", "cash-entries", "customers", "commitments",
                     "disposals", "reports", "log", "staff", "rates", "cash-new", "cash-transfer",
                     "commitment-new", "disposal-new", "staff-new"):
            response = self.office.get(reverse(f"office:{name}"))
            self.assertEqual(response.status_code, 200, name)
        details = {
            "purchase": PurchaseBatch, "sale": Sale, "item": Item, "cash-entry": CashEntry, "customer": Customer,
            "commitment": Commitment, "disposal": DisposalBatch, "staff-member": User,
        }
        for name, model in details.items():
            for record in model.objects.all()[:5]:
                response = self.office.get(reverse(f"office:{name}", args=[record.pk]))
                self.assertEqual(response.status_code, 200, f"{name} {record.pk}")
        self.assertEqual(self.office.get(reverse("office:purchase", args=["NOPE42"])).status_code, 404)

    def test_filters_answer_htmx_with_the_table(self):
        response = self.office.get(reverse("office:items"), {"status": "listed", "type": "goods", "q": "ring"},
                                   HTTP_HX_REQUEST="true")
        self.assertContains(response, 'id="results"')
        log = self.office.get(reverse("office:log"), {"person": ARNEL, "type": "purchase", "from": "2020-01-01"})
        self.assertEqual(log.status_code, 200)
        self.assertEqual(self.office.get(reverse("office:cash-entries"), {"from": "garbage"}).status_code, 200)

    def test_reports_preview_and_download(self):
        preview = self.office.get(reverse("office:reports"), {"kind": "purchases", "branch": "kidapawan"})
        self.assertContains(preview, "Purchase ID")
        self.assertContains(preview, "Download PDF")
        for fmt, mime in (("csv", "text/csv"), ("xlsx", "spreadsheetml"), ("pdf", "application/pdf")):
            response = self.office.get(reverse("office:report-download", args=[fmt]),
                                       {"kind": "sales", "from": "2020-01-01", "to": "2030-12-31"})
            self.assertEqual(response.status_code, 200, fmt)
            self.assertIn(mime, response["Content-Type"])
            self.assertIn("aj-jeweler_sales_all-branches_2020-01-01_to_2030-12-31", response["Content-Disposition"])


class PagesAndLayoutTests(OfficeTestCase):
    def record_entries(self, count):
        from shop.admin_tools import run
        from shop.services import cash
        from shop.services.base import Ctx

        sam = User.objects.get(pk=SAM)
        for n in range(count):
            run(lambda n=n: cash.record_entry(Ctx.for_user(sam), branch_id="davao", type="cashIn", account="sales",
                                              amount_centavos=100 + n, note=f"Float {n}"))

    def test_a_long_table_comes_a_page_at_a_time_without_repeats(self):
        self.record_entries(30)
        first = self.office.get(reverse("office:cash-entries"), {"per": 25})
        self.assertContains(first, "Showing <strong>1–25</strong> of <strong>30</strong>", html=False)
        self.assertEqual(len(first.context["page"]), 25)
        second = self.office.get(reverse("office:cash-entries"), {"per": 25, "page": 2})
        self.assertEqual(len(second.context["page"]), 5)
        ids = [e.id for e in first.context["page"]] + [e.id for e in second.context["page"]]
        self.assertEqual(len(set(ids)), 30, "every entry once, none twice")
        self.assertContains(first, "page=2")
        self.assertEqual(len(self.office.get(reverse("office:cash-entries"), {"per": 999}).context["page"]), 30,
                         "an unknown size falls back to 50 a page")

    def test_the_sidebar_folds_to_icons_and_stays_folded(self):
        open_ = self.office.get(reverse("office:today"))
        self.assertNotContains(open_, 'class="nav-mini"')
        self.assertContains(open_, 'data-nav-toggle')
        self.assertContains(open_, '<span class="nav-label">Purchases</span>', html=False)
        self.office.cookies["office_nav"] = "mini"
        folded = self.office.get(reverse("office:items"))
        self.assertContains(folded, '<html lang="en" class="nav-mini">', html=False)
        self.assertContains(folded, 'aria-pressed="true"')

    def test_reports_open_on_this_month_and_download_what_was_previewed(self):
        from django.utils import timezone

        today = timezone.localdate()
        page = self.office.get(reverse("office:reports"))
        self.assertEqual((page.context["f"].date_from, page.context["f"].date_to), (today.replace(day=1), today))
        self.assertContains(page, f"from={today.replace(day=1).isoformat()}")
        everything = self.office.get(reverse("office:reports"), {"kind": "sales", "from": "", "to": ""})
        self.assertIsNone(everything.context["f"].date_from)


class LoanStatusFilterTests(OfficeTestCase):
    def setUp(self):
        super().setUp()
        self.post(ARNEL, "/sync/import", json.loads(FIXTURE.read_text(encoding="utf-8")), expect=200)

    def test_the_database_status_filter_agrees_with_the_ledger(self):
        from shop.services.commitments import ledger

        for status in ("loanPending", "loanReceived", "loanPaid"):
            listed = {row.commitment.id for row in
                      self.office.get(reverse("office:commitments"), {"status": status}).context["page"]}
            expected = {c.id for c in Commitment.objects.all() if ledger(c).status == status}
            self.assertEqual(listed, expected, status)
            self.assertTrue(expected, f"the demo data has a {status} loan")
