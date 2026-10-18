"""Firebase Cloud Messaging, HTTP v1 API, with a service-account credential.

https://fcm.googleapis.com/v1/projects/{project}/messages:send

The credential file is named by FIREBASE_CREDENTIALS_FILE and never read into
the repository or printed. If it is missing or unreadable, `get_client()`
returns None: notifications are off, a warning is logged once, and the shop
carries on — nothing a person does at the counter may fail because Firebase is
unreachable or unconfigured.
"""

import logging
import threading
from dataclasses import dataclass
from pathlib import Path

from django.conf import settings

log = logging.getLogger("notifications")

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
ENDPOINT = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
TIMEOUT_SECONDS = 10
CHANNEL_ID = "aj_jeweler"

# FCM error codes meaning "this token will never work again".
DEAD_TOKEN_CODES = frozenset({"UNREGISTERED", "INVALID_ARGUMENT"})
# Worth trying again later.
TRANSIENT_CODES = frozenset({"UNAVAILABLE", "INTERNAL", "QUOTA_EXCEEDED", "NETWORK"})


@dataclass
class SendResult:
    ok: bool
    status: int  # HTTP status; 0 when the request never got an answer
    error_code: str = ""  # FCM's errorCode (UNREGISTERED, ...) or our own NETWORK
    message: str = ""
    message_id: str = ""

    @property
    def token_is_dead(self) -> bool:
        return self.error_code in DEAD_TOKEN_CODES

    @property
    def transient(self) -> bool:
        return self.error_code in TRANSIENT_CODES or self.status >= 500 or self.status == 429


def build_message(token: str, title: str, body: str, data: dict[str, str]) -> dict:
    """Both a `notification` block (Android shows it with the app closed) and a
    `data` block the app routes on. Data values must be strings — an FCM rule."""
    return {
        "message": {
            "token": token,
            "notification": {"title": title, "body": body},
            "data": {str(k): str(v) for k, v in data.items()},
            "android": {"priority": "high", "notification": {"channel_id": CHANNEL_ID}},
        }
    }


def _error_code(payload: dict) -> str:
    error = payload.get("error") or {}
    for detail in error.get("details") or []:
        if isinstance(detail, dict) and detail.get("errorCode"):
            return str(detail["errorCode"])
    return str(error.get("status") or "")


def _about_the_token(payload: dict) -> bool:
    """INVALID_ARGUMENT means a bad token only when FCM says the token is the
    problem. A malformed message also comes back INVALID_ARGUMENT, and treating
    that as a dead token would delete every phone in the shop."""
    error = payload.get("error") or {}
    if "registration token" in str(error.get("message", "")).lower():
        return True
    for detail in error.get("details") or []:
        for violation in (detail or {}).get("fieldViolations", []) if isinstance(detail, dict) else []:
            if str(violation.get("field", "")).endswith("token"):
                return True
    return False


class FcmClient:
    def __init__(self, session, project_id: str):
        self.session = session
        self.project_id = project_id
        self.url = ENDPOINT.format(project=project_id)

    def send(self, token: str, title: str, body: str, data: dict[str, str]) -> SendResult:
        import requests

        try:
            response = self.session.post(self.url, json=build_message(token, title, body, data),
                                         timeout=TIMEOUT_SECONDS)
        except (requests.RequestException, OSError) as error:
            return SendResult(ok=False, status=0, error_code="NETWORK", message=str(error)[:300])
        if response.status_code == 200:
            return SendResult(ok=True, status=200, message_id=str(response.json().get("name", "")))
        try:
            payload = response.json()
        except ValueError:
            payload = {}
        code = _error_code(payload)
        if code == "INVALID_ARGUMENT" and not _about_the_token(payload):
            code = "INVALID_MESSAGE"  # our mistake, not the handset's — keep the token
        message = str((payload.get("error") or {}).get("message", response.text[:300]))
        return SendResult(ok=False, status=response.status_code, error_code=code, message=message[:300])


_lock = threading.Lock()
_cached: tuple[tuple[str, str], FcmClient | None] | None = None
_warned = False
_reason = ""


def get_client() -> FcmClient | None:
    """The configured client, or None when notifications are off."""
    global _cached, _warned, _reason
    path = (settings.FIREBASE_CREDENTIALS_FILE or "").strip()
    project = settings.FIREBASE_PROJECT_ID
    key = (path, project)
    with _lock:
        if _cached is not None and _cached[0] == key:
            return _cached[1]
        client = None
        reason = ""
        if not path:
            reason = "FIREBASE_CREDENTIALS_FILE is not set"
        elif not Path(path).is_file():
            reason = "the file named by FIREBASE_CREDENTIALS_FILE does not exist"
        else:
            try:
                from google.auth.transport.requests import AuthorizedSession
                from google.oauth2 import service_account

                credentials = service_account.Credentials.from_service_account_file(path, scopes=[SCOPE])
                client = FcmClient(AuthorizedSession(credentials), project)
            except Exception as error:  # a broken key file must not take the server down
                reason = f"the service-account key could not be loaded ({type(error).__name__})"
        _reason = reason
        if client is None and not _warned:
            log.warning("Push notifications are off: %s. Every shop action still works.", reason)
            _warned = True
        _cached = (key, client)
        return client


def off_reason() -> str:
    """Why notifications are off ("" when they are on)."""
    get_client()
    return _reason


def reset() -> None:
    """Forget the cached client (tests, or after changing settings)."""
    global _cached, _warned
    with _lock:
        _cached = None
        _warned = False
