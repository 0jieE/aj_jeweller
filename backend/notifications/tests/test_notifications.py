"""Push notifications: device registration, who is told what, FCM error
handling, and the guarantees around transactions and replays.

FCM is always mocked — no test touches the network (settings force the
credential off and delivery inline while testing).
"""

import io
from datetime import timedelta
from unittest import mock

from django.core.management import CommandError, call_command
from django.test import override_settings
from django.utils import timezone

from notifications import fcm
from notifications.models import Device, PushNotification
from shop.tests.helpers import ARNEL, BEN, GRACE, JOEL, LIZA, PAOLO, RHEA, ApiTestCase, png_b64


class FakeFcm:
    """Stands in for FcmClient. `answers` maps a token to the SendResult it gets."""

    project_id = "aj-jeweler-notification"

    def __init__(self, answers=None):
        self.sent = []
        self.answers = answers or {}

    def send(self, token, title, body, data):
        self.sent.append({"token": token, "title": title, "body": body, "data": data})
        return self.answers.get(token, fcm.SendResult(ok=True, status=200, message_id=f"projects/x/messages/{len(self.sent)}"))

    def tokens(self):
        return [s["token"] for s in self.sent]


def dead(code="UNREGISTERED"):
    return fcm.SendResult(ok=False, status=404, error_code=code, message="Requested entity was not found.")


class NotificationTestCase(ApiTestCase):
    def setUp(self):
        super().setUp()
        fcm.reset()
        self.fcm = FakeFcm()
        patcher = mock.patch("notifications.fcm.get_client", return_value=self.fcm)
        patcher.start()
        self.addCleanup(patcher.stop)
        # Belt and braces: any real HTTP call fails the test.
        guard = mock.patch("requests.Session.request", side_effect=AssertionError("network used in a test"))
        guard.start()
        self.addCleanup(guard.stop)
        for user_id in (ARNEL, LIZA, RHEA, GRACE, JOEL, PAOLO, BEN):
            Device.objects.create(token=f"tok-{user_id}", user_id=user_id)

    def commit(self, call, *args, **kwargs):
        """Runs a request and then what would run after its transaction commits."""
        with self.captureOnCommitCallbacks(execute=True):
            return call(*args, **kwargs)


class DeviceRegistrationTests(ApiTestCase):
    def test_registering_a_token_twice_keeps_one_row(self):
        first = self.post(GRACE, "/devices", {"token": "fcm-abc", "platform": "android"}, expect=201).data
        again = self.post(GRACE, "/devices", {"token": "fcm-abc"}, expect=200).data
        self.assertEqual(Device.objects.filter(token="fcm-abc").count(), 1)
        self.assertEqual((first["user_id"], again["user_id"]), (GRACE, GRACE))

    def test_a_token_registered_under_someone_else_moves_to_the_signed_in_person(self):
        self.post(GRACE, "/devices", {"token": "counter-phone"}, expect=201)
        moved = self.post(BEN, "/devices", {"token": "counter-phone"}, expect=200).data
        self.assertEqual(moved["user_id"], BEN)
        self.assertEqual(Device.objects.get(token="counter-phone").user_id, BEN)

    def test_the_owner_comes_from_the_token_never_the_body(self):
        self.post(GRACE, "/devices", {"token": "t1", "user": ARNEL, "user_id": ARNEL}, expect=201)
        self.assertEqual(Device.objects.get(token="t1").user_id, GRACE)

    def test_deleting_a_device_is_idempotent(self):
        self.post(GRACE, "/devices", {"token": "fcm:abc-123_x"}, expect=201)
        self.delete(GRACE, "/devices/fcm:abc-123_x", expect=204)
        self.delete(GRACE, "/devices/fcm:abc-123_x", expect=204)
        self.assertFalse(Device.objects.exists())

    def test_signing_out_does_not_remove_someone_elses_registration(self):
        self.post(BEN, "/devices", {"token": "bens-phone"}, expect=201)
        self.delete(GRACE, "/devices/bens-phone", expect=204)
        self.assertTrue(Device.objects.filter(token="bens-phone").exists())

    def test_registration_needs_a_signed_in_person_and_a_token(self):
        from rest_framework.test import APIClient

        self.assertEqual(APIClient().post("/api/v1/devices", {"token": "x"}, format="json").status_code, 401)
        self.assertEqual(self.post(GRACE, "/devices", {"token": ""}).status_code, 400)

    def test_registering_a_device_writes_no_shop_log(self):
        before = self.log_count()
        self.post(GRACE, "/devices", {"token": "t2"}, expect=201)
        self.assertEqual(self.log_count(), before)


class WhoIsToldTests(NotificationTestCase):
    def test_a_purchase_for_release_notifies_that_branchs_cashiers_and_nobody_else(self):
        batch = self.commit(self.post, LIZA, "/purchases", {
            "branch": "kidapawan", "customer": {"name": "Rico Dela Cruz"},
            "lines": [{"description": "Ring", "weight_grams": "3.2", "karat": 18, "type": "goods",
                       "amount_centavos": 1350000},
                      {"description": "Bar", "weight_grams": "2.1", "karat": 24, "type": "goods",
                       "amount_centavos": 1260000}]}, expect=201).data
        self.assertEqual(self.fcm.tokens(), [f"tok-{GRACE}"], "Kidapawan's Cashier only — not Ben, not Liza")
        sent = self.fcm.sent[0]
        self.assertEqual(sent["title"], "Cash to release")
        self.assertEqual(sent["body"], "Rico Dela Cruz · 2 item(s) · ₱26,100.00")
        self.assertEqual(sent["data"], {"kind": "purchase", "record_id": batch["id"], "branch": "kidapawan"})
        self.assertTrue(all(isinstance(v, str) for v in sent["data"].values()))
        self.assertEqual(PushNotification.objects.get().status, "sent")

    def test_the_author_is_never_told_about_their_own_action(self):
        # An Admin encodes a purchase: the Cashier hears of it, the Admin does not.
        self.commit(self.purchase, by=ARNEL)
        self.assertEqual(self.fcm.tokens(), [f"tok-{GRACE}"])
        # A Cashier who is also the only Cashier releases: nobody needs telling.
        self.fcm.sent.clear()
        batch = self.purchase().data
        self.commit(self.release, batch["id"])
        self.assertEqual(self.fcm.sent, [])

    def test_a_returned_purchase_tells_the_appraiser_who_encoded_it(self):
        batch = self.purchase().data
        self.fcm.sent.clear()
        self.commit(self.post, GRACE, f"/purchases/{batch['id']}/return", {"note": "Recheck the ring weight"},
                    expect=200)
        self.assertEqual(self.fcm.tokens(), [f"tok-{LIZA}"])
        self.assertEqual((self.fcm.sent[0]["title"], self.fcm.sent[0]["body"]),
                         ("Purchase returned", "Walk-in · Recheck the ring weight"))

    def test_a_resubmitted_purchase_is_back_in_the_cashiers_queue(self):
        batch = self.purchase().data
        self.post(GRACE, f"/purchases/{batch['id']}/return", {"note": "Fix"}, expect=200)
        self.fcm.sent.clear()
        self.commit(self.post, LIZA, f"/purchases/{batch['id']}/resubmit", {}, expect=200)
        self.assertEqual(self.fcm.tokens(), [f"tok-{GRACE}"])
        self.assertEqual(self.fcm.sent[0]["title"], "Cash to release")

    def test_an_order_for_payment_tells_cashiers_and_a_returned_one_tells_its_rep(self):
        item = self.released_item()
        self.fcm.sent.clear()
        sale = self.commit(self.post, RHEA, "/sales", {
            "branch": "kidapawan", "customer": {"name": "Teresa Lim"},
            "lines": [{"item_id": item["id"], "negotiated_price_centavos": 11500000}]}, expect=201).data
        self.assertEqual(self.fcm.tokens(), [f"tok-{GRACE}"])
        self.assertEqual((self.fcm.sent[0]["title"], self.fcm.sent[0]["body"], self.fcm.sent[0]["data"]["kind"]),
                         ("Payment to receive", "Teresa Lim · ₱115,000.00", "sale"))
        self.fcm.sent.clear()
        self.commit(self.post, GRACE, f"/sales/{sale['id']}/return", {"note": "Price looks wrong"}, expect=200)
        self.assertEqual(self.fcm.tokens(), [f"tok-{RHEA}"])
        self.assertEqual(self.fcm.sent[0]["body"], "Teresa Lim · Price looks wrong")

    def test_loan_events_tell_the_other_admins(self):
        second = self.post(ARNEL, "/users", {"name": "Second Admin", "role": "admin", "pin": "2468"},
                           expect=201).data["id"]
        Device.objects.create(token="tok-second", user_id=second)
        loan = self.post(ARNEL, "/commitments", {"lender": "Metro Pawnshop", "amount_centavos": 5000000,
                                                 "rate_per_gram_centavos": 500000, "branch": "kidapawan"},
                         expect=201).data
        self.commit(self.post, ARNEL, f"/commitments/{loan['id']}/receive", {"proof_photo": png_b64()}, expect=200)
        self.assertEqual(self.fcm.tokens(), ["tok-second"], "Admins, but not the Admin who recorded it")
        self.assertEqual((self.fcm.sent[0]["title"], self.fcm.sent[0]["body"], self.fcm.sent[0]["data"]["kind"]),
                         ("Loan received", "Metro Pawnshop · ₱50,000.00", "commitment"))

        scrap = self.released_item(type="scrap")
        self.fcm.sent.clear()
        self.commit(self.post, ARNEL, "/disposal", {"branch": "kidapawan", "item_ids": [scrap["id"]],
                                                    "gross_grams": "10", "gross_amount_centavos": 2000000,
                                                    "commitment_id": loan["id"]}, expect=201)
        self.assertEqual(self.fcm.sent, [], "a partial payment clears nothing")
        scrap = self.released_item(type="scrap")
        self.commit(self.post, ARNEL, "/disposal", {"branch": "kidapawan", "item_ids": [scrap["id"]],
                                                    "gross_grams": "10", "gross_amount_centavos": 3000000,
                                                    "commitment_id": loan["id"]}, expect=201)
        self.assertEqual(self.fcm.tokens(), ["tok-second"])
        self.assertEqual((self.fcm.sent[0]["title"], self.fcm.sent[0]["body"]), ("Loan cleared", "Metro Pawnshop"))

    def test_a_branch_without_an_active_cashier_tells_its_admins(self):
        self.post(ARNEL, f"/users/{BEN}/deactivate", expect=200)
        self.commit(self.purchase, by=JOEL, branch="davao")
        self.assertEqual(self.fcm.tokens(), [f"tok-{ARNEL}"])

    def test_deactivated_staff_are_not_told(self):
        second = self.post(ARNEL, "/users", {"name": "Second Cashier", "role": "cashier", "home_branch": "kidapawan",
                                             "pin": "2468"}, expect=201).data["id"]
        Device.objects.create(token="tok-second-cashier", user_id=second)
        self.post(ARNEL, f"/users/{second}/deactivate", expect=200)
        self.commit(self.purchase)
        self.assertEqual(self.fcm.tokens(), [f"tok-{GRACE}"])

    def test_a_refused_write_notifies_nobody(self):
        response = self.commit(self.post, LIZA, "/purchases", {
            "branch": "kidapawan", "customer": {"name": "X"},
            "lines": [{"description": "Chain", "weight_grams": "20", "karat": 18, "type": "silver",
                       "amount_centavos": 100}]})
        self.assertEqual(response.status_code, 422)
        self.assertEqual(self.fcm.sent, [])
        self.assertFalse(PushNotification.objects.exists())

    def test_someone_with_no_registered_phone_is_simply_skipped(self):
        Device.objects.filter(user_id=GRACE).delete()
        self.commit(self.purchase)
        self.assertEqual(PushNotification.objects.get().status, "no_device")


class DeliveryTests(NotificationTestCase):
    def test_an_unregistered_token_is_deleted_and_the_rest_still_get_it(self):
        Device.objects.create(token="grace-old-phone", user_id=GRACE)
        self.fcm.answers["grace-old-phone"] = dead("UNREGISTERED")
        self.commit(self.purchase)
        self.assertFalse(Device.objects.filter(token="grace-old-phone").exists())
        self.assertTrue(Device.objects.filter(token=f"tok-{GRACE}").exists())
        row = PushNotification.objects.get()
        self.assertEqual((row.status, row.devices_reached), ("sent", 1))

    def test_an_invalid_token_is_deleted_but_a_malformed_message_keeps_the_token(self):
        self.fcm.answers[f"tok-{GRACE}"] = dead("INVALID_ARGUMENT")
        self.commit(self.purchase)
        self.assertFalse(Device.objects.filter(token=f"tok-{GRACE}").exists())

        Device.objects.create(token="grace-new", user_id=GRACE)
        self.fcm.answers["grace-new"] = fcm.SendResult(ok=False, status=400, error_code="INVALID_MESSAGE",
                                                       message="Invalid JSON payload")
        self.commit(self.purchase)
        self.assertTrue(Device.objects.filter(token="grace-new").exists())
        self.assertEqual(PushNotification.objects.order_by("-pk").first().status, "failed")

    def test_a_transient_failure_stays_pending_and_send_notifications_retries_it(self):
        self.fcm.answers[f"tok-{GRACE}"] = fcm.SendResult(ok=False, status=503, error_code="UNAVAILABLE")
        self.commit(self.purchase)
        row = PushNotification.objects.get()
        self.assertEqual((row.status, row.attempts), ("pending", 1))
        del self.fcm.answers[f"tok-{GRACE}"]
        call_command("send_notifications", stdout=io.StringIO())
        row.refresh_from_db()
        self.assertEqual((row.status, row.attempts), ("sent", 2))

    def test_old_unsent_notifications_expire_instead_of_arriving_in_a_burst(self):
        with override_settings(PUSH_DELIVERY="command"):
            self.commit(self.purchase)
        PushNotification.objects.update(created_at=timezone.now() - timedelta(hours=13))
        out = io.StringIO()
        call_command("send_notifications", stdout=out)
        self.assertEqual(PushNotification.objects.get().status, "expired")
        self.assertEqual(self.fcm.sent, [])

    def test_a_replayed_sync_push_does_not_notify_twice(self):
        ops = [{"key": "offline-1", "method": "POST", "path": "/api/v1/purchases", "body": {
            "id": "Q7MNP3", "branch": "kidapawan", "customer": {"name": "Offline Olivia"},
            "lines": [{"id": "Q7MNP4", "description": "Ring", "weight_grams": 3.5, "karat": 18, "type": "goods",
                       "amount_centavos": 180000}]}}]
        self.commit(self.post, LIZA, "/sync/push", {"operations": ops}, expect=200)
        self.assertEqual(len(self.fcm.sent), 1, "the first arrival is news")
        again = self.commit(self.post, LIZA, "/sync/push", {"operations": ops}, expect=200).data
        self.assertTrue(again["results"][0]["replayed"])
        self.assertEqual(len(self.fcm.sent), 1, "the replay is not")
        self.assertEqual(PushNotification.objects.count(), 1)

    def test_the_message_has_a_tray_notification_a_data_block_and_the_android_channel(self):
        message = fcm.build_message("tok", "Cash to release", "Rico · 2 item(s)", {"kind": "purchase", "n": 2})
        self.assertEqual(message["message"]["notification"], {"title": "Cash to release", "body": "Rico · 2 item(s)"})
        self.assertEqual(message["message"]["data"], {"kind": "purchase", "n": "2"})
        self.assertEqual(message["message"]["android"],
                         {"priority": "high", "notification": {"channel_id": "aj_jeweler"}})


class NotificationsOffTests(ApiTestCase):
    """No credential configured: the real get_client(), not a fake."""

    def setUp(self):
        super().setUp()
        fcm.reset()
        guard = mock.patch("requests.Session.request", side_effect=AssertionError("network used in a test"))
        guard.start()
        self.addCleanup(guard.stop)
        Device.objects.create(token=f"tok-{GRACE}", user_id=GRACE)

    @override_settings(FIREBASE_CREDENTIALS_FILE="")
    def test_with_no_credential_the_write_succeeds_and_nothing_is_sent(self):
        self.assertIsNone(fcm.get_client())
        with self.captureOnCommitCallbacks(execute=True):
            self.purchase(expect=201)
        row = PushNotification.objects.get()
        self.assertEqual(row.status, "off")
        self.assertEqual(row.attempts, 0)

    @override_settings(FIREBASE_CREDENTIALS_FILE=r"C:\does\not\exist.json")
    def test_a_missing_key_file_also_just_turns_notifications_off(self):
        self.assertIsNone(fcm.get_client())
        self.assertIn("does not exist", fcm.off_reason())
        with self.captureOnCommitCallbacks(execute=True):
            self.purchase(expect=201)

    @override_settings(FIREBASE_CREDENTIALS_FILE="")
    def test_the_test_command_says_notifications_are_off(self):
        with self.assertRaisesMessage(CommandError, "Notifications are off"):
            call_command("send_test_notification", "--user", GRACE, stdout=io.StringIO())


class TestCommandTests(NotificationTestCase):
    def test_sends_to_every_device_of_the_user_and_prints_what_fcm_said(self):
        Device.objects.create(token="grace-second-phone", user_id=GRACE)
        self.fcm.answers["grace-second-phone"] = dead()
        out = io.StringIO()
        call_command("send_test_notification", "--user", GRACE, stdout=out)
        text = out.getvalue()
        self.assertEqual(sorted(self.fcm.tokens()), sorted([f"tok-{GRACE}", "grace-second-phone"]))
        self.assertIn("sent (projects/x/messages/", text)
        self.assertIn("UNREGISTERED", text)
        self.assertIn("token removed", text)
        self.assertFalse(Device.objects.filter(token="grace-second-phone").exists())

    def test_someone_with_no_phone_gets_a_plain_answer(self):
        Device.objects.filter(user_id=BEN).delete()
        with self.assertRaisesMessage(CommandError, "Ben Soriano has no registered phone"):
            call_command("send_test_notification", "--user", BEN, stdout=io.StringIO())


class FcmClientTests(ApiTestCase):
    """The HTTP v1 call itself, against a fake session."""

    class Response:
        def __init__(self, status, payload):
            self.status_code, self._payload, self.text = status, payload, str(payload)

        def json(self):
            return self._payload

    def client_returning(self, status, payload):
        session = mock.Mock()
        session.post.return_value = self.Response(status, payload)
        return fcm.FcmClient(session, "aj-jeweler-notification"), session

    def test_posts_to_the_v1_endpoint_of_the_project(self):
        client, session = self.client_returning(200, {"name": "projects/aj/messages/1"})
        result = client.send("tok", "T", "B", {"kind": "sale"})
        self.assertTrue(result.ok)
        url = session.post.call_args.args[0]
        self.assertEqual(url, "https://fcm.googleapis.com/v1/projects/aj-jeweler-notification/messages:send")
        self.assertEqual(session.post.call_args.kwargs["json"]["message"]["token"], "tok")

    def test_reads_the_fcm_error_code(self):
        client, _ = self.client_returning(404, {"error": {"code": 404, "status": "NOT_FOUND", "message": "gone",
                                                          "details": [{"@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                                                                       "errorCode": "UNREGISTERED"}]}})
        result = client.send("tok", "T", "B", {})
        self.assertTrue(result.token_is_dead)

    def test_invalid_argument_counts_as_a_dead_token_only_when_about_the_token(self):
        bad_token = {"error": {"status": "INVALID_ARGUMENT", "message": "The registration token is not a valid FCM "
                                                                         "registration token",
                               "details": [{"errorCode": "INVALID_ARGUMENT"}]}}
        bad_payload = {"error": {"status": "INVALID_ARGUMENT", "message": "Invalid value at 'message.data'",
                                 "details": [{"errorCode": "INVALID_ARGUMENT",
                                              "fieldViolations": [{"field": "message.data[0].value"}]}]}}
        self.assertTrue(self.client_returning(400, bad_token)[0].send("t", "T", "B", {}).token_is_dead)
        self.assertFalse(self.client_returning(400, bad_payload)[0].send("t", "T", "B", {}).token_is_dead)

    def test_a_network_failure_is_transient_not_an_exception(self):
        import requests

        session = mock.Mock()
        session.post.side_effect = requests.ConnectionError("unreachable")
        result = fcm.FcmClient(session, "p").send("tok", "T", "B", {})
        self.assertFalse(result.ok)
        self.assertTrue(result.transient)
