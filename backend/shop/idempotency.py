"""Idempotency-Key handling for every write.

A phone on a bad connection — or replaying its offline outbox — may send the
same write twice. Sent with the same `Idempotency-Key`, the second copy gets
the first copy's response back (with `Idempotent-Replayed: true`) and nothing
happens twice. Keys are scoped to the signed-in user. Reusing a key for a
different request is refused rather than silently answered with the wrong
result.

Business refusals (4xx) are remembered too: "the first result" includes a
"no". A 5xx is not remembered, so a retry after a server fault runs again.
"""

import hashlib
import json

from rest_framework.utils.encoders import JSONEncoder

from .models import IdempotencyRecord

HEADER = "Idempotency-Key"
MAX_KEY_LENGTH = 128


def fingerprint(method: str, path: str, body: bytes, user_id: str) -> str:
    digest = hashlib.sha256()
    for part in (method.upper(), path, user_id):
        digest.update(part.encode())
        digest.update(b"\0")
    digest.update(body or b"")
    return digest.hexdigest()


def find(user, key: str) -> IdempotencyRecord | None:
    return IdempotencyRecord.objects.filter(user=user, key=key).first()


def store(*, user, key: str, method: str, path: str, fp: str, response) -> None:
    body = json.loads(json.dumps(response.data, cls=JSONEncoder)) if response.data is not None else None
    IdempotencyRecord.objects.update_or_create(
        user=user, key=key,
        defaults={"method": method, "path": path, "fingerprint": fp,
                  "status_code": response.status_code, "body": body},
    )
