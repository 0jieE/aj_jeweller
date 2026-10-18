"""The Cloudinary storage backend, with the SDK's network calls mocked."""

from unittest import mock

from django.core.files.base import ContentFile
from django.test import SimpleTestCase, override_settings

from shop.storage import CloudinaryStorage

CREDENTIALS = {"CLOUDINARY_URL": "cloudinary://123456:secret-value@democloud", "CLOUDINARY_FOLDER": "aj-test"}


@override_settings(**CREDENTIALS)
class CloudinaryStorageTests(SimpleTestCase):
    def setUp(self):
        self.storage = CloudinaryStorage()

    def test_a_photo_is_an_authenticated_image_named_after_its_django_path(self):
        with mock.patch("cloudinary.uploader.upload") as upload:
            name = self.storage.save("items/7H3M2Q-20261018.jpg", ContentFile(b"jpeg-bytes"))
        self.assertEqual(name, "items/7H3M2Q-20261018.jpg", "the database keeps Django's name")
        data, = upload.call_args.args
        options = upload.call_args.kwargs
        self.assertEqual(data, b"jpeg-bytes")
        self.assertEqual((options["public_id"], options["resource_type"], options["type"]),
                         ("aj-test/items/7H3M2Q-20261018", "image", "authenticated"))

    def test_a_receipt_pdf_is_a_raw_asset_keeping_its_extension(self):
        with mock.patch("cloudinary.uploader.upload") as upload:
            self.storage.save("receipts/R7X2KQ-20261018.pdf", ContentFile(b"%PDF-1.4"))
        self.assertEqual((upload.call_args.kwargs["public_id"], upload.call_args.kwargs["resource_type"]),
                         ("aj-test/receipts/R7X2KQ-20261018.pdf", "raw"))

    def test_urls_are_signed_and_never_public(self):
        url = self.storage.url("customers/CUS001-1.png")
        self.assertTrue(url.startswith("https://res.cloudinary.com/democloud/image/authenticated/s--"), url)
        self.assertTrue(url.endswith("/aj-test/customers/CUS001-1.png"), url)
        pdf = self.storage.url("receipts/X.pdf")
        self.assertIn("/raw/authenticated/s--", pdf)

    def test_open_downloads_through_the_signed_url(self):
        response = mock.Mock(status_code=200, content=b"photo-bytes")
        with mock.patch("requests.get", return_value=response) as get:
            with self.storage.open("items/A.jpg") as handle:
                self.assertEqual(handle.read(), b"photo-bytes")
        self.assertIn("/image/authenticated/s--", get.call_args.args[0])

    def test_a_missing_asset_is_file_not_found(self):
        with mock.patch("requests.get", return_value=mock.Mock(status_code=404)):
            with self.assertRaises(FileNotFoundError):
                self.storage.open("items/gone.jpg")

    def test_delete_destroys_the_right_asset(self):
        with mock.patch("cloudinary.uploader.destroy") as destroy:
            self.storage.delete("release-proofs/A3T8QD-1.jpg")
        self.assertEqual(destroy.call_args.args, ("aj-test/release-proofs/A3T8QD-1",))
        self.assertEqual(destroy.call_args.kwargs["type"], "authenticated")

    @override_settings(CLOUDINARY_URL="https://wrong")
    def test_a_malformed_url_is_refused_clearly(self):
        with self.assertRaisesMessage(ValueError, "cloudinary://<api_key>:<api_secret>@<cloud_name>"):
            CloudinaryStorage()
