"""Six-character record ids, e.g. "A7K2M9", shared by every record type.

The alphabet leaves out 0/O and 1/I so a handwritten id is never ambiguous
(`IdGenerator` in the app). The client normally chooses the id — that is what
lets a phone create records offline — and the server accepts it as the
primary key after checking nobody holds it. The server mints ids itself for
the records it writes as side effects (log rows, ledger entries).
"""

import re
import secrets

from .errors import Conflict, Refusal
from .models import RecordId

ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
LENGTH = 6
RECORD_ID_RE = re.compile(rf"^[{ALPHABET}]{{{LENGTH}}}$")
USER_ID_RE = re.compile(rf"^USR-[{ALPHABET}A-Z0-9-]{{2,24}}$")
# Imported data predates the alphabet in places (the demo data's "CUS001",
# "LOG001", "USR-K-APR"), so an import accepts any short plain code.
LEGACY_ID_RE = re.compile(r"^[A-Za-z0-9-]{1,32}$")


def _raw() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(LENGTH))


def is_taken(record_id: str) -> bool:
    return RecordId.objects.filter(id=record_id).exists()


def new_id(kind: str, prefix: str = "") -> str:
    """A fresh id nobody holds, registered to `kind` before it is returned."""
    for _ in range(1000):
        candidate = f"{prefix}{_raw()}"
        if not is_taken(candidate):
            RecordId.objects.create(id=candidate, kind=kind)
            return candidate
    raise RuntimeError("Could not allocate an unused record id")


def claim(record_id: str | None, kind: str, *, legacy: bool = False) -> str:
    """Registers a client-chosen id (or mints one when none was sent).

    Refuses with 409 when the code already identifies another record — of any
    kind — since one code must point at exactly one thing.
    """
    if record_id is None or record_id == "":
        return new_id(kind)
    pattern = LEGACY_ID_RE if legacy else RECORD_ID_RE
    if not pattern.match(record_id):
        raise Refusal(
            f'"{record_id}" is not a record id — ids are {LENGTH} characters from {ALPHABET}',
            code="invalid_id",
        )
    existing = RecordId.objects.filter(id=record_id).first()
    if existing is not None:
        raise Conflict(f"{record_id} is already used by another record", existing_kind=existing.kind)
    RecordId.objects.create(id=record_id, kind=kind)
    return record_id


def claim_user_id(record_id: str | None) -> str:
    if not record_id:
        return new_id("user", prefix="USR-")
    if not USER_ID_RE.match(record_id):
        raise Refusal(f'"{record_id}" is not a user id — user ids look like USR-AJ01', code="invalid_id")
    if is_taken(record_id):
        raise Conflict(f"{record_id} is already used by another record")
    RecordId.objects.create(id=record_id, kind="user")
    return record_id
