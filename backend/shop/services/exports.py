"""Spreadsheets for the bookkeeper — the same tables as the app's
ExportService, offered server-side as a convenience.

Amounts are plain pesos (no ₱, no grouping) so a spreadsheet can total them;
dates are ISO so they sort.
"""

import csv
import io
from dataclasses import dataclass
from datetime import datetime

from django.utils import timezone

from ..enums import BranchId, CashAccount, CashEntryType, ItemType, Role, VerificationStatus, label
from ..models import CashEntry, PurchaseBatch, Sale
from ..text import peso_plain, purity_text

KINDS = ("purchases", "sales", "expenses", "withdrawals")
TITLES = {"purchases": "Purchases", "sales": "Sales", "expenses": "Expenses", "withdrawals": "Withdrawals"}


@dataclass
class Table:
    headers: list[str]
    rows: list[list[str]]
    total_centavos: int


def _when(d: datetime) -> str:
    return f"{timezone.localtime(d):%Y-%m-%d %H:%M}"


def _person(user, fallback: str = "") -> str:
    return user.name if user else fallback


def _ranged(queryset, field, start, end):
    if start is not None:
        queryset = queryset.filter(**{f"{field}__gte": start})
    if end is not None:
        queryset = queryset.filter(**{f"{field}__lt": end})
    return queryset


def purchases(branch, start, end) -> Table:
    from .purchases import lines_of

    batches = PurchaseBatch.objects.select_related("submitted_by", "released_by").order_by("date")
    if branch:
        batches = batches.filter(branch_id=branch)
    rows, total = [], 0
    for batch in _ranged(batches, "date", start, end):
        for item in lines_of(batch):
            amount = item.effective_original_amount
            total += amount
            rows.append([
                _when(batch.date), batch.id, item.id, BranchId(batch.branch_id).label, batch.customer_name,
                batch.customer_contact_number or "", item.description, ItemType(item.type).label,
                purity_text(item.karat), f"{item.effective_gross_grams:.3f}", f"{item.effective_original_grams:.3f}",
                peso_plain(amount), VerificationStatus(batch.verification_status).label,
                _person(batch.submitted_by), _person(batch.released_by),
            ])
    return Table(["Date", "Purchase ID", "Item ID", "Branch", "Customer", "Contact", "Description", "Type",
                  "Karat/Purity", "Original weight (g)", "Net weight (g)", "Amount (PHP)", "Status",
                  "Encoded by", "Cash released by"], rows, total)


def sales(branch, start, end) -> Table:
    queryset = Sale.objects.select_related("submitted_by", "received_by").order_by("date")
    if branch:
        queryset = queryset.filter(branch_id=branch)
    rows, total = [], 0
    for sale in _ranged(queryset, "date", start, end):
        for line in sale.lines.select_related("item").order_by("position"):
            snap = line.item_snapshot or {}
            total += line.negotiated_price_centavos
            rows.append([
                _when(sale.date), sale.id, line.item_id, BranchId(sale.branch_id).label, sale.customer_name,
                sale.customer_contact_number or "", snap.get("description") or line.item.description,
                ItemType(snap.get("type") or line.item.type).label, purity_text(snap.get("karat") or line.item.karat),
                f"{line.effective_final_grams:.3f}", peso_plain(line.price_per_gram_centavos),
                peso_plain(line.negotiated_price_centavos), peso_plain(sale.cash_centavos),
                peso_plain(sale.bank_centavos), VerificationStatus(sale.verification_status).label,
                _person(sale.submitted_by), _person(sale.received_by),
            ])
    return Table(["Date", "Sale ID", "Item ID", "Branch", "Customer", "Contact", "Description", "Type",
                  "Karat/Purity", "Weight (g)", "Price per gram (PHP)", "Line amount (PHP)", "Order cash paid (PHP)",
                  "Order bank paid (PHP)", "Status", "Sales rep", "Received by"], rows, total)


def cash_table(branch, start, end, entry_type: str) -> Table:
    queryset = CashEntry.objects.select_related("recorded_by").filter(type=entry_type).order_by("date")
    if branch:
        queryset = queryset.filter(branch_id=branch)
    expense = entry_type == CashEntryType.EXPENSE
    rows, total = [], 0
    for e in _ranged(queryset, "date", start, end):
        total += e.amount_centavos
        row = [_when(e.date), e.id, BranchId(e.branch_id).label, CashAccount(e.account).label]
        if expense:
            row.append(e.category or "")
        row += [e.note, peso_plain(e.amount_centavos), "Manual" if e.is_manual else f"Linked ({e.source_type})",
                _person(e.recorded_by, label(Role, e.recorded_by_role))]
        rows.append(row)
    headers = ["Date", "Entry ID", "Branch", "Cash source"] + (["Category"] if expense else []) + [
        "Note", "Amount (PHP)", "Origin", "Recorded by"]
    return Table(headers, rows, total)


def build(kind: str, branch: str | None, start, end) -> Table:
    if kind == "purchases":
        return purchases(branch, start, end)
    if kind == "sales":
        return sales(branch, start, end)
    if kind == "expenses":
        return cash_table(branch, start, end, CashEntryType.EXPENSE)
    return cash_table(branch, start, end, CashEntryType.WITHDRAWAL)


def filename(kind: str, branch: str | None, raw_from: str | None, raw_to: str | None, ext: str) -> str:
    """'aj-jeweler_sales_davao_2026-10-01_to_2026-10-18.csv', as the app names it."""
    scope = branch or "all-branches"
    if raw_from or raw_to:
        period = f"{(raw_from or 'start')[:10]}_to_{(raw_to or 'today')[:10]}"
    else:
        period = "all-dates"
    return f"aj-jeweler_{kind}_{scope}_{period}.{ext}"


def to_csv(table: Table) -> bytes:
    """UTF-8 with a byte-order mark, so Excel opens names with ñ correctly."""
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(table.headers)
    writer.writerows(table.rows)
    return b"\xef\xbb\xbf" + buffer.getvalue().encode("utf-8")


def to_xlsx(table: Table, title: str) -> bytes:
    from openpyxl import Workbook
    from openpyxl.styles import Font

    book = Workbook()
    sheet = book.active
    sheet.title = title[:31]
    sheet.append(table.headers)
    for cell in sheet[1]:
        cell.font = Font(bold=True)
    money_columns = {i for i, h in enumerate(table.headers) if "(PHP)" in h}
    gram_columns = {i for i, h in enumerate(table.headers) if "(g)" in h}
    for row in table.rows:
        values = []
        for i, value in enumerate(row):
            if i in money_columns or i in gram_columns:
                try:
                    values.append(float(value))
                    continue
                except ValueError:
                    pass
            values.append(value)
        sheet.append(values)
    buffer = io.BytesIO()
    book.save(buffer)
    return buffer.getvalue()


def to_pdf(table: Table, title: str, subtitle: str) -> bytes:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer
    from reportlab.platypus import Table as PdfTable
    from reportlab.platypus import TableStyle

    from .receipts import _fonts

    _fonts()
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=landscape(A4), leftMargin=24, rightMargin=24, topMargin=24,
                            bottomMargin=24)
    cell = ParagraphStyle("cell", fontName="Roboto", fontSize=6.5, leading=8)
    head = ParagraphStyle("head", parent=cell, fontName="Roboto-Bold")
    data = [[Paragraph(h, head) for h in table.headers]] + [[Paragraph(str(v), cell) for v in r] for r in table.rows]
    grid = PdfTable(data, repeatRows=1)
    grid.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.25, colors.grey),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EEEEEE")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story = [Paragraph(title, ParagraphStyle("t", fontName="Roboto-Bold", fontSize=14, leading=18)),
             Paragraph(subtitle, ParagraphStyle("s", fontName="Roboto", fontSize=8, leading=11)),
             Spacer(1, 8), grid]
    doc.build(story)
    return buffer.getvalue()
