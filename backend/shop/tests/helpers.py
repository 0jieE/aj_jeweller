"""Shared test scaffolding: the app's seven staff, signed-in clients, and
small builders for the records most tests start from."""

import base64
import io
from decimal import Decimal

from django.test import TestCase
from PIL import Image
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from accounts.models import User
from shop.models import TransactionLog

API = "/api/v1"
PIN = "1234"

# StaffDirectory.seed in the app.
STAFF = [
    ("USR-AJ01", "Arnel Javier", "admin", None),
    ("USR-K-APR", "Liza Mendoza", "assistantAppraiser", "kidapawan"),
    ("USR-K-REP", "Rhea Castillo", "salesRep", "kidapawan"),
    ("USR-K-CSH", "Grace Ramos", "cashier", "kidapawan"),
    ("USR-D-APR", "Joel Bautista", "assistantAppraiser", "davao"),
    ("USR-D-REP", "Paolo Delos Reyes", "salesRep", "davao"),
    ("USR-D-CSH", "Ben Soriano", "cashier", "davao"),
]

ARNEL, LIZA, RHEA, GRACE, JOEL, PAOLO, BEN = (s[0] for s in STAFF)


def make_staff() -> dict[str, User]:
    from shop.models import RecordId

    people = {}
    for user_id, name, role, branch in STAFF:
        user = User(id=user_id, name=name, role=role, home_branch=branch)
        user.set_password(PIN)
        user.save()
        RecordId.objects.get_or_create(id=user_id, defaults={"kind": "user"})
        people[user_id] = user
    return people


def png_bytes(color=(200, 160, 40)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (4, 4), color).save(buffer, format="PNG")
    return buffer.getvalue()


def png_b64(color=(200, 160, 40)) -> str:
    return base64.b64encode(png_bytes(color)).decode()


class ApiTestCase(TestCase):
    """Each test gets the seven staff; `self.api(user_id)` is a client signed
    in as that person."""

    def setUp(self):
        super().setUp()
        self.staff = make_staff()
        self._clients = {}

    def api(self, user_id: str) -> APIClient:
        if user_id not in self._clients:
            client = APIClient()
            token = RefreshToken.for_user(User.objects.get(pk=user_id))
            client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.access_token}")
            self._clients[user_id] = client
        return self._clients[user_id]

    # --- request helpers ---------------------------------------------------
    def post(self, user_id, path, data=None, *, fmt="json", expect=None, **headers):
        response = self.api(user_id).post(f"{API}{path}", data or {}, format=fmt, headers=headers or None)
        return self._check(response, expect)

    def patch(self, user_id, path, data=None, *, expect=None, **headers):
        response = self.api(user_id).patch(f"{API}{path}", data or {}, format="json", headers=headers or None)
        return self._check(response, expect)

    def put(self, user_id, path, data=None, *, fmt="json", expect=None, **headers):
        response = self.api(user_id).put(f"{API}{path}", data or {}, format=fmt, headers=headers or None)
        return self._check(response, expect)

    def delete(self, user_id, path, data=None, *, expect=None, **headers):
        response = self.api(user_id).delete(f"{API}{path}", data or {}, format="json", headers=headers or None)
        return self._check(response, expect)

    def get(self, user_id, path, params=None, *, expect=200):
        response = self.api(user_id).get(f"{API}{path}", params or {})
        return self._check(response, expect)

    def _check(self, response, expect):
        if expect is not None:
            self.assertEqual(response.status_code, expect, getattr(response, "data", response.content))
        return response

    def refusal(self, response, status=422) -> str:
        """Asserts a refusal in the shop's envelope and returns its message."""
        self.assertEqual(response.status_code, status, getattr(response, "data", None))
        self.assertIn("error", response.data)
        self.assertTrue(response.data["error"]["message"])
        return response.data["error"]["message"]

    def log_count(self) -> int:
        return TransactionLog.objects.count()

    def last_log(self) -> TransactionLog:
        return TransactionLog.objects.order_by("-received_at", "-at").first()

    # --- record builders ---------------------------------------------------
    def purchase(self, *, by=LIZA, branch="kidapawan", customer="Walk-in", lines=None, expect=201, **extra):
        if lines is None:
            lines = [{"description": "Test piece", "weight_grams": "10.000", "karat": 18,
                      "type": "goods", "amount_centavos": 500000}]
        body = {"branch": branch, "customer": {"name": customer}, "lines": lines, **extra}
        return self.post(by, "/purchases", body, expect=expect)

    def release(self, batch_id, *, by=GRACE, expect=200):
        return self.post(by, f"/purchases/{batch_id}/release", {"proof_photo": png_b64()}, expect=expect)

    def released_item(self, *, type="goods", grams="10.000", amount=500000, karat=18, branch="kidapawan",
                      by=None, cashier=None) -> dict:
        by = by or (LIZA if branch == "kidapawan" else JOEL)
        cashier = cashier or (GRACE if branch == "kidapawan" else BEN)
        batch = self.purchase(by=by, branch=branch, lines=[{
            "description": f"Test {type}", "weight_grams": grams, "karat": karat, "type": type,
            "amount_centavos": amount,
        }]).data
        self.release(batch["id"], by=cashier)
        return self.get(ARNEL, f"/items/{batch['items'][0]['id']}").data

    @staticmethod
    def grams(value) -> Decimal:
        return Decimal(str(value))
