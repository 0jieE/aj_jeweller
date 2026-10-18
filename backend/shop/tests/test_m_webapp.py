"""The desktop app (Flutter web build) served at the site root, same origin as the API."""

import io
import tempfile
from pathlib import Path

from django.core.management import CommandError, call_command
from django.core.signals import request_finished
from django.db import close_old_connections
from django.test import Client, override_settings

from .helpers import ApiTestCase

INDEX = b"<!doctype html><html><body>AJ desktop app</body></html>"


def fake_build(root: Path, *, local_canvaskit=False) -> Path:
    (root / "assets").mkdir(parents=True)
    (root / "canvaskit").mkdir()
    (root / "index.html").write_bytes(INDEX)
    (root / "main.dart.js").write_text("console.log('app')")
    (root / "flutter_service_worker.js").write_text("// sw")
    config = '{"engineRevision":"abc"' + (',"useLocalCanvasKit":true' if local_canvaskit else '') + "}"
    (root / "flutter_bootstrap.js").write_text(f"_flutter.buildConfig = {config};")
    (root / "assets" / "AssetManifest.bin").write_bytes(b"\x00manifest")
    (root / "canvaskit" / "canvaskit.wasm").write_bytes(b"\x00wasm")
    (root / "main.dart.js.symbols").write_text("debug")
    (root / ".last_build_id").write_text("x")
    return root


class WebAppTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = fake_build(Path(tmp.name) / "web")
        override = override_settings(WEB_APP_ROOT=str(self.root), WHITENOISE_ROOT=str(self.root))
        override.enable()
        self.addCleanup(override.disable)
        self.browser = Client()  # a fresh client, so WhiteNoise reads this WEB_APP_ROOT

    def test_the_root_returns_the_app_uncached(self):
        response = self.browser.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, INDEX)
        self.assertEqual(response["Cache-Control"], "no-store")

    def test_an_app_route_returns_index_html_not_a_404(self):
        for path in ("/cash", "/purchases/A3T8QD", "/sell/checkout?step=2"):
            response = self.browser.get(path)
            self.assertEqual((response.status_code, response.content), (200, INDEX), path)
            self.assertEqual(response["Cache-Control"], "no-store")

    def test_the_app_never_shadows_the_api_or_the_admin(self):
        staff = self.browser.get("/api/v1/auth/staff")
        self.assertEqual(staff.status_code, 200)
        self.assertEqual(len(staff.json()), 7)
        self.assertEqual(self.browser.get("/api/v1/nothing-here").status_code, 404)
        self.assertNotEqual(self.browser.get("/api/v1/nothing-here").content, INDEX)
        admin = self.browser.get("/admin/")
        self.assertEqual(admin.status_code, 302)
        self.assertIn("/admin/login/", admin["Location"])
        self.assertEqual(self.browser.get("/admin").status_code, 302)

    def test_a_missing_file_is_a_404_not_the_app(self):
        for path in ("/assets/missing.png", "/canvaskit/nope.wasm", "/icons/Icon-1024.png", "/old.dart.js"):
            response = self.browser.get(path)
            self.assertEqual(response.status_code, 404, path)
            self.assertNotEqual(response.content, INDEX, path)

    def fetch(self, path, **headers):
        """A WhiteNoise file response, read and closed (Windows keeps open files locked)."""
        response = self.browser.get(path, **headers)
        body = b"".join(response.streaming_content) if response.streaming else response.content
        # Closing fires request_finished, which would close the test's database
        # connection; the test client detaches that handler the same way.
        request_finished.disconnect(close_old_connections)
        try:
            response.close()
        finally:
            request_finished.connect(close_old_connections)
        return response, body

    def test_real_files_are_served_and_revalidated_entry_points_never_cached(self):
        asset, body = self.fetch("/assets/AssetManifest.bin")
        self.assertEqual((asset.status_code, body), (200, b"\x00manifest"))
        self.assertEqual(asset["Cache-Control"], "no-cache")
        self.assertIn("ETag", asset)
        again, _ = self.fetch("/assets/AssetManifest.bin", HTTP_IF_NONE_MATCH=asset["ETag"])
        self.assertEqual(again.status_code, 304, "unchanged files cost a 304, not a download")
        self.assertEqual(self.fetch("/main.dart.js")[0]["Cache-Control"], "no-cache")
        for entry in ("/flutter_service_worker.js", "/flutter_bootstrap.js", "/index.html"):
            self.assertEqual(self.fetch(entry)[0]["Cache-Control"], "no-store", entry)


@override_settings(WEB_APP_ROOT="", WHITENOISE_ROOT=None)
class NoWebAppTests(ApiTestCase):
    def test_without_an_app_the_root_explains_itself_and_the_api_is_unaffected(self):
        browser = Client()
        root = browser.get("/")
        self.assertEqual(root.status_code, 200)
        self.assertContains(root, "No desktop app has been deployed on this server")
        self.assertEqual(browser.get("/cash").status_code, 404)
        self.assertEqual(browser.get("/api/v1/auth/staff").status_code, 200)
        self.assertEqual(browser.get("/admin/").status_code, 302)

    def test_a_directory_without_index_html_counts_as_no_app(self):
        with tempfile.TemporaryDirectory() as empty, override_settings(WEB_APP_ROOT=empty):
            self.assertContains(Client().get("/"), "No desktop app has been deployed")


class PublishWebAppTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

    def publish(self, source, target):
        out = io.StringIO()
        call_command("publish_webapp", "--from", str(source), "--to", str(target), stdout=out)
        return out.getvalue()

    def test_copies_the_build_without_symbols_or_the_cdn_canvaskit(self):
        build = fake_build(self.tmp / "build")
        target = self.tmp / "webapp"
        out = self.publish(build, target)
        self.assertTrue((target / "index.html").is_file())
        self.assertTrue((target / "assets" / "AssetManifest.bin").is_file())
        self.assertFalse((target / "main.dart.js.symbols").exists())
        self.assertFalse((target / ".last_build_id").exists())
        self.assertFalse((target / "canvaskit").exists(), "CanvasKit comes from the CDN in this build")
        self.assertIn("CanvasKit comes from the CDN", out)

    def test_keeps_canvaskit_when_the_build_loads_it_locally_and_replaces_the_old_copy(self):
        target = self.tmp / "webapp"
        target.mkdir()
        (target / "stale.js").write_text("old")
        self.publish(fake_build(self.tmp / "build", local_canvaskit=True), target)
        self.assertTrue((target / "canvaskit" / "canvaskit.wasm").is_file())
        self.assertFalse((target / "stale.js").exists(), "a new build replaces the old one whole")
        self.assertFalse((self.tmp / "webapp.incoming").exists())

    def test_refuses_a_folder_that_is_not_a_web_build(self):
        with self.assertRaisesMessage(CommandError, "No web build"):
            self.publish(self.tmp / "nothing", self.tmp / "webapp")
