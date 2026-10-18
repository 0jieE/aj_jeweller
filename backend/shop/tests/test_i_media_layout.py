"""Media folders: kind / branch / YYYY / MM. Local disk in tests (the layout is
storage-agnostic); Cloudinary mocked where it matters."""

import base64
import io
from datetime import datetime
from datetime import timezone as dt_timezone
from types import SimpleNamespace
from unittest import mock

from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from django.core.management import call_command
from django.test import override_settings
from django.utils import timezone

from shop.media_paths import upload_path
from shop.models import Commitment, Customer, DisposalBatch, Item, PurchaseBatch, StoredReceipt
from shop.storage import CloudinaryStorage

from .helpers import ARNEL, GRACE, LIZA, ApiTestCase, png_b64, png_bytes


def this_month() -> str:
    now = timezone.localtime()
    return f"{now.year:04d}/{now.month:02d}"


class LayoutTests(ApiTestCase):
    def test_each_kind_lands_under_kind_branch_year_month(self):
        customer = self.post(LIZA, "/customers", {"name": "Nora Salcedo", "photo": png_b64()}, expect=201).data
        batch = self.post(LIZA, "/purchases", {
            "branch": "kidapawan", "date": "2026-03-05T10:00:00", "customer": {"name": "Rico"},
            "lines": [{"description": "Lot", "weight_grams": "10", "karat": 18, "type": "scrap",
                       "amount_centavos": 400000, "photo": png_b64()}]}, expect=201).data
        self.release(batch["id"])
        loan = self.post(ARNEL, "/commitments", {"lender": "Metro", "amount_centavos": 5000000,
                                                 "rate_per_gram_centavos": 500000, "branch": "kidapawan"},
                         expect=201).data
        self.post(ARNEL, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        self.post(ARNEL, "/disposal", {"branch": "kidapawan", "item_ids": [batch["items"][0]["id"]],
                                       "gross_grams": "10", "gross_amount_centavos": 500000,
                                       "commitment_id": loan["id"], "date": "2026-02-10T09:00:00",
                                       "photo": png_b64()}, expect=201)
        self.post(GRACE, "/receipts", {"record_id": batch["id"]}, expect=201)

        now = this_month()
        names = {
            "customer": Customer.objects.get(pk=customer["id"]).photo.name,
            "item": Item.objects.get(pk=batch["items"][0]["id"]).photo.name,
            "release": PurchaseBatch.objects.get(pk=batch["id"]).release_proof_photo.name,
            "loan": Commitment.objects.get(pk=loan["id"]).received_proof_photo.name,
            "disposal": DisposalBatch.objects.get().photo.name,
            "receipt": StoredReceipt.objects.get().pdf.name,
        }
        self.assertTrue(names["customer"].startswith(f"customers/shop/{now}/{customer['id']}-"), names)
        self.assertTrue(names["item"].startswith(f"items/kidapawan/2026/03/{batch['items'][0]['id']}-"), names)
        self.assertTrue(names["release"].startswith(f"release-proofs/kidapawan/{now}/{batch['id']}-"), names)
        self.assertTrue(names["loan"].startswith(f"loan-proofs/kidapawan/{now}/{loan['id']}-"), names)
        self.assertTrue(names["disposal"].startswith("disposals/kidapawan/2026/02/"), names)
        self.assertTrue(names["receipt"].startswith(f"receipts/kidapawan/{now}/"), names)
        self.assertTrue(names["receipt"].endswith(".pdf"))
        for name in names.values():
            self.assertTrue(default_storage.exists(name), name)

    def test_a_record_with_no_branch_lands_under_shop(self):
        loan = self.post(ARNEL, "/commitments", {"lender": "Golden Circle", "amount_centavos": 5000000,
                                                 "rate_per_gram_centavos": 500000}, expect=201).data
        self.post(ARNEL, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        self.assertTrue(Commitment.objects.get(pk=loan["id"]).received_proof_photo.name
                        .startswith(f"loan-proofs/shop/{this_month()}/"))

    def test_a_missing_or_unexpected_branch_or_date_still_gives_a_path_under_shop(self):
        now = this_month()

        class Broken:
            pk = "A3T8QD"

            @property
            def branch_id(self):
                raise RuntimeError("no branch here")

        cases = [
            SimpleNamespace(pk="A3T8QD", branch_id="manila", purchase_date="not a date"),
            SimpleNamespace(pk="A3T8QD"),
            SimpleNamespace(pk=None, branch_id=None, purchase_date=None),
            Broken(),
        ]
        for instance in cases:
            path = upload_path("items", instance, "photo.jpg")
            self.assertTrue(path.startswith(f"items/shop/{now}/"), path)
        self.assertTrue(upload_path("items", SimpleNamespace(pk="../x", branch_id="davao"), "a.weird!ext")
                        .endswith(".bin"))
        self.assertNotIn("..", upload_path("items", SimpleNamespace(pk="../x"), "a.jpg"))

    def test_the_date_comes_from_the_record(self):
        when = timezone.make_aware(datetime(2025, 12, 31, 23, 30))
        record = SimpleNamespace(pk="Q7MNP3", branch_id="davao", purchase_date=when, released_at=when,
                                 date_received=when, date=when, issued_at=when)
        for kind in ("items", "release-proofs", "loan-proofs", "disposals", "receipts"):
            self.assertTrue(upload_path(kind, record, "f.jpg").startswith(f"{kind}/davao/2025/12/"), kind)
        # Manila time decides the month: 23:30 on 31 Dec UTC is already January there.
        utc = datetime(2025, 12, 31, 23, 30, tzinfo=dt_timezone.utc)
        self.assertTrue(upload_path("items", SimpleNamespace(pk="X", branch_id="davao", purchase_date=utc), "a.jpg")
                        .startswith("items/davao/2026/01/"))
        # A customer photo is filed when it is taken.
        self.assertTrue(upload_path("customers", SimpleNamespace(pk="CUS005", first_seen=when), "a.jpg")
                        .startswith(f"customers/shop/{this_month()}/"))

    def test_no_path_carries_a_customers_name_or_number(self):
        self.post(LIZA, "/purchases", {
            "branch": "kidapawan",
            "customer": {"name": "Grace Palma", "contact_number": "0917 555 0142", "address": "Poblacion",
                         "photo": png_b64()},
            "lines": [{"description": "Grace's ring", "weight_grams": "3", "karat": 18, "type": "goods",
                       "amount_centavos": 150000, "photo": png_b64()}]}, expect=201)
        names = [Customer.objects.get().photo.name, Item.objects.get().photo.name]
        for name in names:
            for leak in ("Grace", "Palma", "0917", "555", "Poblacion", "ring"):
                self.assertNotIn(leak.lower(), name.lower(), name)


class OldLayoutTests(ApiTestCase):
    def test_an_asset_under_the_old_flat_layout_still_opens_downloads_and_deletes(self):
        item = self.purchase().data["items"][0]
        old = default_storage.save(f"items/{item['id']}-20260101000000000000.png", ContentFile(png_bytes()))
        Item.objects.filter(pk=item["id"]).update(photo=old)

        detail = self.get(LIZA, f"/items/{item['id']}").data
        self.assertTrue(detail["photo_url"].endswith(old))
        with Item.objects.get(pk=item["id"]).photo.open("rb") as handle:
            self.assertEqual(handle.read(), png_bytes())
        snapshot = self.get(ARNEL, "/sync/snapshot").data
        sent = next(i for i in snapshot["items"] if i["id"] == item["id"])
        self.assertEqual(base64.b64decode(sent["photo"]), png_bytes(), "phones still get base64")
        default_storage.delete(old)
        self.assertFalse(default_storage.exists(old))

    @override_settings(CLOUDINARY_URL="cloudinary://123456:secret@democloud", CLOUDINARY_FOLDER="aj-test")
    def test_on_cloudinary_an_old_flat_name_maps_to_its_original_asset(self):
        storage = CloudinaryStorage()
        old = "items/A3T8QD-20261018143022123456.jpg"
        self.assertTrue(storage.url(old).endswith("/aj-test/items/A3T8QD-20261018143022123456.jpg"))
        with mock.patch("requests.get", return_value=mock.Mock(status_code=200, content=b"x")):
            self.assertEqual(storage.open(old).read(), b"x")
        with mock.patch("cloudinary.uploader.destroy") as destroy:
            storage.delete(old)
        self.assertEqual(destroy.call_args.args, ("aj-test/items/A3T8QD-20261018143022123456",))


class ReorganiseMediaTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        batch = self.post(LIZA, "/purchases", {
            "branch": "kidapawan", "date": "2026-04-20T10:00:00", "customer": {"name": "R"},
            "lines": [{"description": "A", "weight_grams": "1", "karat": 18, "type": "goods",
                       "amount_centavos": 1000},
                      {"description": "B", "weight_grams": "1", "karat": 18, "type": "goods",
                       "amount_centavos": 1000}]}, expect=201).data
        self.a, self.b = batch["items"][0]["id"], batch["items"][1]["id"]
        self.old_a = default_storage.save(f"items/{self.a}-1.png", ContentFile(png_bytes()))
        Item.objects.filter(pk=self.a).update(photo=self.old_a)
        # B's row points at a file that is not there.
        Item.objects.filter(pk=self.b).update(photo=f"items/{self.b}-gone.png")
        self.customer = self.post(LIZA, "/customers", {"name": "Old Photo"}, expect=201).data["id"]
        self.old_c = default_storage.save(f"customers/{self.customer}-1.png", ContentFile(png_bytes((1, 1, 1))))
        Customer.objects.filter(pk=self.customer).update(photo=self.old_c)

    def run_command(self, *args):
        out, err = io.StringIO(), io.StringIO()
        call_command("reorganise_media", *args, stdout=out, stderr=err)
        return out.getvalue(), err.getvalue()

    def test_a_dry_run_moves_nothing(self):
        out, _ = self.run_command()
        self.assertIn("Dry run", out)
        self.assertIn(f"would move {self.old_a} -> items/kidapawan/2026/04/{self.a}-1.png", out)
        self.assertEqual(Item.objects.get(pk=self.a).photo.name, self.old_a)
        self.assertTrue(default_storage.exists(self.old_a))
        self.run_command("--dry-run", "--apply")  # --dry-run wins
        self.assertEqual(Item.objects.get(pk=self.a).photo.name, self.old_a)

    def test_a_real_run_leaves_every_row_pointing_at_something_that_exists(self):
        out, err = self.run_command("--apply")
        moved = Item.objects.get(pk=self.a).photo.name
        self.assertEqual(moved, f"items/kidapawan/2026/04/{self.a}-1.png")
        self.assertTrue(default_storage.exists(moved))
        self.assertFalse(default_storage.exists(self.old_a), "the old copy goes once the row points at the new one")
        customer = Customer.objects.get(pk=self.customer).photo.name
        self.assertTrue(customer.startswith(f"customers/shop/{this_month()}/"))
        self.assertTrue(default_storage.exists(customer))
        # The unreadable one is reported and untouched.
        self.assertIn(f"cannot read items/{self.b}-gone.png", err)
        self.assertEqual(Item.objects.get(pk=self.b).photo.name, f"items/{self.b}-gone.png")
        for item in Item.objects.exclude(photo=""):
            if item.pk != self.b:
                self.assertTrue(default_storage.exists(item.photo.name), item.photo.name)

        # Running it again moves nothing new.
        out, _ = self.run_command("--apply")
        self.assertEqual(Item.objects.get(pk=self.a).photo.name, moved)
        self.assertIn("items: 1 in place", out)

    def test_one_kind_at_a_time(self):
        self.run_command("--apply", "--kind", "customers")
        self.assertEqual(Item.objects.get(pk=self.a).photo.name, self.old_a, "items left for another run")
        self.assertTrue(Customer.objects.get(pk=self.customer).photo.name.startswith("customers/shop/"))
