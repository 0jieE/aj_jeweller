"""Customer receipts — the shop's own filed copy of every one it issues.

The plain-text version follows ReceiptService.purchaseText / saleText line for
line; the PDF is laid out on an 80mm roll, the width a counter thermal printer
takes. One current receipt per record: re-issuing replaces the document and
keeps the receipt's id.
"""

import io
from pathlib import Path

from django.core.files.base import ContentFile
from reportlab.lib.colors import Color
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

from ..enums import LogAction, LogRecordKind, ReceiptKind, VerificationStatus
from ..errors import NotFound, Refusal
from ..ids import claim, new_id
from ..models import PurchaseBatch, Sale, StoredReceipt
from ..text import date_time_short, grams, karat_text, peso
from .base import Ctx, require_branch, write_log

SHOP_NAME = "AJ JEWELER"
_FONTS = Path(__file__).resolve().parent.parent / "fonts"
_registered = False


def _fonts() -> None:
    # The PDF base fonts are ASCII-only and drop the peso sign; Roboto has it.
    global _registered
    if not _registered:
        pdfmetrics.registerFont(TTFont("Roboto", str(_FONTS / "Roboto-Regular.ttf")))
        pdfmetrics.registerFont(TTFont("Roboto-Bold", str(_FONTS / "Roboto-Bold.ttf")))
        _registered = True


# --- what the receipt says ---------------------------------------------------

def _purchase_lines(batch: PurchaseBatch):
    from .purchases import lines_of

    return lines_of(batch)


def _releaser(batch: PurchaseBatch) -> str:
    return batch.released_by.name if batch.released_by else "the Cashier"


def purchase_text(batch: PurchaseBatch) -> str:
    lots = _purchase_lines(batch)
    total = sum(i.effective_original_amount for i in lots)
    out = [SHOP_NAME, f"{batch.branch.label} Branch", "PURCHASE RECEIPT", f"Receipt No. {batch.id}",
           f"Date: {date_time_short(batch.released_at or batch.date)}", "", f"Sold to us by: {batch.customer_name}"]
    if batch.customer_contact_number:
        out.append(batch.customer_contact_number)
    out.append("")
    for item in lots:
        out.append(item.description)
        out.append(f"  {karat_text(item.karat)} · {grams(item.effective_original_grams)} net"
                   f" — {peso(item.effective_original_amount)}")
    out += ["", f"TOTAL PAID: {peso(total)}", f"Cash released by {_releaser(batch)}."]
    return "\n".join(out).strip()


def _sale_lines(sale: Sale):
    return list(sale.lines.select_related("item").order_by("position"))


def _line_item(line) -> tuple[str, int]:
    snap = line.item_snapshot or {}
    return snap.get("description") or line.item.description, snap.get("karat") or line.item.karat


def sale_text(sale: Sale) -> str:
    out = [SHOP_NAME, f"{sale.branch.label} Branch", "SALES RECEIPT", f"Receipt No. {sale.id}",
           f"Date: {date_time_short(sale.date)}", "", f"Sold to: {sale.customer_name}", ""]
    for line in _sale_lines(sale):
        description, karat = _line_item(line)
        out.append(description)
        out.append(f"  {karat_text(karat)} · {grams(line.effective_final_grams)} — {peso(line.negotiated_price_centavos)}")
    out += ["", f"TOTAL: {peso(sale.total_centavos)}"]
    if sale.cash_centavos > 0:
        out.append(f"Cash: {peso(sale.cash_centavos)}")
    if sale.bank_centavos > 0:
        out.append(f"Bank transfer: {peso(sale.bank_centavos)}")
    out.append("Thank you for your purchase.")
    return "\n".join(out).strip()


# --- the PDF -------------------------------------------------------------------

GREY = Color(0.38, 0.38, 0.38)


class _Roll:
    """Collects rows, then draws them on a page exactly as tall as they need."""

    WIDTH = 80 * mm
    MARGIN = 12

    def __init__(self):
        self.rows: list[tuple] = []

    def text(self, value, size=8, bold=False, center=False, color=None, gap=2):
        self.rows.append(("text", value, size, bold, center, color, gap))

    def pair(self, left, right, size=8, bold=False, right_size=None):
        self.rows.append(("pair", left, right, size, bold, right_size or size))

    def rule(self):
        self.rows.append(("rule",))

    def space(self, points):
        self.rows.append(("space", points))

    @staticmethod
    def _height(row) -> float:
        kind = row[0]
        if kind == "text":
            return row[2] + row[6] + 1
        if kind == "pair":
            return max(row[3], row[5]) + 3
        if kind == "rule":
            return 9
        return row[1]

    def render(self) -> bytes:
        _fonts()
        height = sum(self._height(r) for r in self.rows) + 2 * self.MARGIN
        buffer = io.BytesIO()
        pdf = canvas.Canvas(buffer, pagesize=(self.WIDTH, height))
        y = height - self.MARGIN
        left, right = self.MARGIN, self.WIDTH - self.MARGIN
        for row in self.rows:
            kind = row[0]
            if kind == "text":
                _, value, size, bold, center, color, _gap = row
                y -= size
                pdf.setFont("Roboto-Bold" if bold else "Roboto", size)
                pdf.setFillColor(color or Color(0, 0, 0))
                if center:
                    pdf.drawCentredString(self.WIDTH / 2, y, value)
                else:
                    pdf.drawString(left, y, value)
                y -= self._height(row) - size
            elif kind == "pair":
                _, a, b, size, bold, right_size = row
                y -= max(size, right_size)
                pdf.setFillColor(Color(0, 0, 0))
                pdf.setFont("Roboto-Bold" if bold else "Roboto", size)
                pdf.drawString(left, y, a)
                pdf.setFont("Roboto-Bold" if bold else "Roboto", right_size)
                pdf.drawRightString(right, y, b)
                y -= 3
            elif kind == "rule":
                y -= 4.5
                pdf.setStrokeColor(GREY)
                pdf.setLineWidth(0.6)
                pdf.line(left, y, right, y)
                y -= 4.5
            else:
                y -= row[1]
        pdf.showPage()
        pdf.save()
        return buffer.getvalue()


def _header(roll: _Roll, title: str, branch_label: str, receipt_no: str, when) -> None:
    roll.text(SHOP_NAME, 16, bold=True, center=True)
    roll.text(f"{branch_label} Branch", 9, center=True, gap=6)
    roll.text(title, 11, bold=True, center=True, gap=6)
    roll.pair("Receipt No.", receipt_no)
    roll.pair("Date", date_time_short(when))


def _footer(roll: _Roll, note: str) -> None:
    roll.space(6)
    roll.text(note, 7, color=GREY)
    roll.space(18)
    roll.rule()
    roll.text("Customer signature", 7, gap=8)
    roll.text("This is a system-generated receipt.", 6, center=True, color=GREY)


def _customer_block(roll: _Roll, label: str, name: str, contact=None, address=None) -> None:
    roll.text(label.upper(), 7)
    roll.text(name, 10, bold=True)
    if contact:
        roll.text(contact, 8)
    if address:
        roll.text(address, 8)


def purchase_pdf(batch: PurchaseBatch) -> bytes:
    roll = _Roll()
    lots = _purchase_lines(batch)
    _header(roll, "PURCHASE RECEIPT", batch.branch.label, batch.id, batch.released_at or batch.date)
    roll.rule()
    _customer_block(roll, "Sold to us by", batch.customer_name, batch.customer_contact_number, batch.customer_address)
    roll.rule()
    for item in lots:
        roll.space(4)
        roll.text(item.description, 9)
        roll.pair(f"{karat_text(item.karat)} · {grams(item.effective_original_grams)} net",
                  peso(item.effective_original_amount))
        if item.deducted_grams > 0:
            roll.text(f"gross {grams(item.effective_gross_grams)}, less {grams(item.deducted_grams)}", 7, color=GREY)
        roll.text(f"Item {item.id}", 7, color=GREY)
    roll.rule()
    roll.pair("TOTAL PAID", peso(sum(i.effective_original_amount for i in lots)), 10, bold=True, right_size=12)
    roll.rule()
    _footer(roll, f"Cash released by {_releaser(batch)}. Weights shown are net of stones and fittings.")
    return roll.render()


def sale_pdf(sale: Sale) -> bytes:
    roll = _Roll()
    _header(roll, "SALES RECEIPT", sale.branch.label, sale.id, sale.date)
    roll.rule()
    _customer_block(roll, "Sold to", sale.customer_name)
    roll.rule()
    for line in _sale_lines(sale):
        description, karat = _line_item(line)
        roll.space(4)
        roll.text(description, 9)
        roll.pair(f"{karat_text(karat)} · {grams(line.effective_final_grams)}", peso(line.negotiated_price_centavos))
        roll.text(f"{peso(line.price_per_gram_centavos)} per gram", 7, color=GREY)
        roll.text(f"Item {line.item_id}", 7, color=GREY)
    roll.rule()
    roll.pair("TOTAL DUE", peso(sale.total_centavos), 10, bold=True, right_size=12)
    roll.space(2)
    if sale.cash_centavos > 0:
        roll.pair("Cash", peso(sale.cash_centavos))
    if sale.bank_centavos > 0:
        roll.pair("Bank transfer", peso(sale.bank_centavos))
    roll.rule()
    _footer(roll, sale.note or "Thank you for your purchase.")
    return roll.render()


# --- issuing -------------------------------------------------------------------

def issue(ctx: Ctx, record_id: str, kind: str | None = None, receipt_id: str | None = None) -> StoredReceipt:
    """Generates and files the receipt for a released purchase or a paid sale."""
    batch = PurchaseBatch.objects.select_related("branch", "released_by").filter(pk=record_id).first()
    sale = None if batch else Sale.objects.select_related("branch").filter(pk=record_id).first()
    if batch is None and sale is None:
        raise NotFound("No purchase or sale has that id")
    found = ReceiptKind.PURCHASE if batch else ReceiptKind.SALE
    if kind and kind != found:
        raise Refusal(f"{record_id} is a {found}, not a {kind}", code="wrong_kind")
    record = batch or sale
    require_branch(ctx, record.branch_id)

    if batch:
        if batch.verification_status != VerificationStatus.VERIFIED:
            raise Refusal("The receipt is issued once a Cashier releases the cash.", code="not_released")
        pdf, text = purchase_pdf(batch), purchase_text(batch)
        total = sum(i.effective_original_amount for i in _purchase_lines(batch))
    else:
        if sale.verification_status != VerificationStatus.VERIFIED:
            raise Refusal("The receipt is issued once payment is received.", code="not_paid")
        pdf, text = sale_pdf(sale), sale_text(sale)
        total = sale.total_centavos

    receipt = StoredReceipt.objects.filter(record_id=record_id).first()
    reissue = receipt is not None
    if receipt is None:
        receipt = StoredReceipt(id=claim(receipt_id, "receipt") if receipt_id else new_id("receipt"),
                                record_id=record_id)
    receipt.kind = found
    receipt.branch_id = record.branch_id
    receipt.counterparty = record.customer_name
    receipt.total_centavos = total
    receipt.issued_at = ctx.now
    receipt.text = text
    receipt.pdf.save(f"{found}-{record_id}.pdf", ContentFile(pdf), save=False)
    receipt.save()
    write_log(
        ctx, LogAction.RECEIPT_ISSUED,
        f"{'Re-issued' if reissue else 'Issued'} the {found} receipt for {record.customer_name} ({peso(total)})",
        branch=record.branch_id, record_id=record_id,
        record_kind=LogRecordKind.PURCHASE_BATCH if batch else LogRecordKind.SALE, amount_centavos=total,
    )
    return receipt
