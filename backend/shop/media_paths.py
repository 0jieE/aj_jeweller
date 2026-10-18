"""Where photos and receipt PDFs are filed: kind / branch / year / month.

    release-proofs/kidapawan/2026/10/A3T8QD-20261018143022123456.jpg
    items/davao/2026/10/L2M8XK-20261018090501000001.jpg
    receipts/kidapawan/2026/10/S3W9NL-20261018101500000002.pdf
    customers/shop/2026/09/CUS005-20260912110000000003.jpg

Under CLOUDINARY_FOLDER on Cloudinary, under MEDIA_ROOT on local disk — the
same layout, so a development machine looks like the Media Library.

* **Kind** first — what someone looks for ("show me the release proofs").
* **Branch** next: `kidapawan` or `davao`; `shop` for a record with none (a
  customer, a company-wide loan) and for anything unexpected. Working out the
  folder never raises: a photo that cannot be saved means cash cannot be
  released.
* **Year/month** from the record's own date (see KINDS), else now.
* **File name** `<record-id>-<timestamp>.<ext>`: unique, sorts by time, and
  carries ids only — never a name, number or address, because a path travels
  in URLs and shows in the Media Library.

Rows saved before this layout keep their old flat paths ("items/A3T8QD-….jpg")
and keep working: storage resolves whatever name a row holds.
"""

import re
from dataclasses import dataclass
from datetime import datetime

from django.utils import timezone

BRANCHES = frozenset({"kidapawan", "davao"})
NO_BRANCH = "shop"


@dataclass(frozen=True)
class Kind:
    folder: str
    model: str  # "app_label.ModelName"
    field: str
    date_field: str | None  # the record's own date; None = the time of upload
    why: str


# Which date files each kind — the record's own date where it has one.
KINDS = {
    k.folder: k
    for k in (
        # A person's photo can be taken or replaced at any visit; their
        # first_seen does not date it, so the upload time does.
        Kind("customers", "shop.Customer", "photo", None, "time of upload"),
        # The piece's purchase date (a partition's is when it was drawn), so a
        # photo added later still files with the piece.
        Kind("items", "shop.Item", "photo", "purchase_date", "the piece's purchase date"),
        # When the cash was handed over.
        Kind("release-proofs", "shop.PurchaseBatch", "release_proof_photo", "released_at", "when cash was released"),
        # When the loan cash arrived.
        Kind("loan-proofs", "shop.Commitment", "received_proof_photo", "date_received", "when the loan was received"),
        # The settlement date.
        Kind("disposals", "shop.DisposalBatch", "photo", "date", "the settlement date"),
        # When the receipt was (last) issued.
        Kind("receipts", "shop.StoredReceipt", "pdf", "issued_at", "when the receipt was issued"),
    )
}

_NEW_LAYOUT = re.compile(r"^(?P<kind>[a-z-]+)/(?P<branch>kidapawan|davao|shop)/\d{4}/\d{2}/[^/]+$")
_SAFE_EXT = re.compile(r"^[a-z0-9]{1,5}$")
_SAFE_ID = re.compile(r"[^A-Za-z0-9_-]")


def branch_of(instance) -> str:
    try:
        branch = getattr(instance, "branch_id", None)
    except Exception:
        return NO_BRANCH
    return branch if isinstance(branch, str) and branch in BRANCHES else NO_BRANCH


def month_of(instance, kind: Kind) -> tuple[int, int]:
    when = None
    if kind.date_field:
        try:
            when = getattr(instance, kind.date_field, None)
        except Exception:
            when = None
    if not isinstance(when, datetime):
        when = timezone.now()
    if timezone.is_aware(when):
        when = timezone.localtime(when)  # the shop's month, in Manila
    return when.year, when.month


def folder_for(kind_name: str, instance) -> str:
    kind = KINDS[kind_name]
    year, month = month_of(instance, kind)
    return f"{kind.folder}/{branch_of(instance)}/{year:04d}/{month:02d}"


def upload_path(kind_name: str, instance, filename: str) -> str:
    """The `upload_to` body for every file field."""
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if not _SAFE_EXT.match(ext):
        ext = "bin"
    record_id = _SAFE_ID.sub("", str(getattr(instance, "pk", "") or "")) or "new"
    return f"{folder_for(kind_name, instance)}/{record_id}-{timezone.now():%Y%m%d%H%M%S%f}.{ext}"


def in_new_layout(name: str, kind_name: str) -> bool:
    match = _NEW_LAYOUT.match(name or "")
    return bool(match) and match.group("kind") == kind_name


def relocated(name: str, kind_name: str, instance) -> str:
    """Where an existing file belongs in the new layout, keeping its file name."""
    return f"{folder_for(kind_name, instance)}/{name.rsplit('/', 1)[-1]}"
