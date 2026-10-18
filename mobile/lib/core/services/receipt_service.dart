import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../data/staff_directory.dart';
import '../models/item.dart';
import '../models/purchase_batch.dart';
import '../models/sale.dart';
import '../widgets/formatters.dart';

/// Builds the shop's customer-facing receipts as real PDFs — one for a
/// purchase (the shop paying a customer for gold) and one for a sale.
///
/// Laid out on an 80mm roll, the width a counter thermal printer actually
/// takes, so what gets shared looks like the slip a customer would be handed
/// rather than a screenshot of an app.
class ReceiptService {
  ReceiptService._();

  static const _shopName = 'AJ JEWELER';

  /// The pdf package's built-in Helvetica is ASCII-only and silently drops
  /// the peso sign, which would leave every amount on the receipt unlabelled.
  /// A bundled Unicode face is the fix; it is loaded once and reused.
  static pw.ThemeData? _theme;

  static Future<pw.ThemeData> _receiptTheme() async {
    final cached = _theme;
    if (cached != null) return cached;
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    return _theme = pw.ThemeData.withFont(base: regular, bold: bold);
  }

  /// Receipt for gold bought from a customer.
  static Future<Uint8List> purchase({
    required PurchaseBatch batch,
    required List<Item> items,
  }) async {
    final total = items.fold<int>(0, (sum, i) => sum + i.capitalAmountCentavos);
    final doc = pw.Document(theme: await _receiptTheme());

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(12),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            ..._header(
              title: 'PURCHASE RECEIPT',
              branchLabel: batch.branch.label,
              receiptNo: batch.id,
              date: batch.releasedAt ?? batch.date,
            ),
            _divider(),
            ..._customerBlock(
              label: 'Sold to us by',
              name: batch.customer.name,
              contact: batch.customer.contactNumber,
              address: batch.customer.address,
            ),
            _divider(),
            for (final item in items) ..._purchaseLine(item),
            _divider(),
            _totalRow('TOTAL PAID', total),
            _divider(),
            ..._footer(
              note: 'Cash released by ${StaffDirectory.byId(batch.releasedByUserId)?.name ?? 'the Cashier'}. '
                  'Weights shown are net of stones and fittings.',
            ),
          ],
        ),
      ),
    );

    return doc.save();
  }

  /// Receipt for gold sold to a customer.
  static Future<Uint8List> sale({required Sale sale}) async {
    final doc = pw.Document(theme: await _receiptTheme());

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(12),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            ..._header(
              title: 'SALES RECEIPT',
              branchLabel: sale.branch.label,
              receiptNo: sale.id,
              date: sale.date,
            ),
            _divider(),
            ..._customerBlock(label: 'Sold to', name: sale.customerName),
            _divider(),
            for (final line in sale.lineItems) ..._saleLine(line),
            _divider(),
            _totalRow('TOTAL DUE', sale.totalAmountCentavos),
            pw.SizedBox(height: 2),
            // Spelled out per tender: a customer who paid part in cash needs
            // the slip to say how much of it was cash.
            if (sale.payment.cashCentavos > 0)
              _row('Cash', AppFormat.peso(sale.payment.cashCentavos)),
            if (sale.payment.bankCentavos > 0)
              _row('Bank transfer', AppFormat.peso(sale.payment.bankCentavos)),
            _divider(),
            ..._footer(
              note: sale.note == null || sale.note!.isEmpty
                  ? 'Thank you for your purchase.'
                  : sale.note!,
            ),
          ],
        ),
      ),
    );

    return doc.save();
  }

  /// The purchase receipt as plain text — what goes into a chat message.
  static String purchaseText({required PurchaseBatch batch, required List<Item> items}) {
    final lots = items.where((i) => !i.isPartitioned).toList();
    final total = lots.fold<int>(0, (sum, i) => sum + i.effectiveOriginalAmountCentavos);
    final b = StringBuffer()
      ..writeln(_shopName)
      ..writeln('${batch.branch.label} Branch')
      ..writeln('PURCHASE RECEIPT')
      ..writeln('Receipt No. ${batch.id}')
      ..writeln('Date: ${AppFormat.dateTimeShort(batch.releasedAt ?? batch.date)}')
      ..writeln('')
      ..writeln('Sold to us by: ${batch.customer.name}');
    if ((batch.customer.contactNumber ?? '').isNotEmpty) b.writeln(batch.customer.contactNumber);
    b.writeln('');
    for (final item in lots) {
      b
        ..writeln(item.description)
        ..writeln('  ${AppFormat.karat(item.karat)} · ${AppFormat.grams(item.effectiveOriginalGrams)} net'
            ' — ${AppFormat.peso(item.effectiveOriginalAmountCentavos)}');
    }
    b
      ..writeln('')
      ..writeln('TOTAL PAID: ${AppFormat.peso(total)}')
      ..writeln('Cash released by ${StaffDirectory.byId(batch.releasedByUserId)?.name ?? 'the Cashier'}.');
    return b.toString().trim();
  }

  /// The sale receipt as plain text — what goes into a chat message.
  static String saleText({required Sale sale}) {
    final b = StringBuffer()
      ..writeln(_shopName)
      ..writeln('${sale.branch.label} Branch')
      ..writeln('SALES RECEIPT')
      ..writeln('Receipt No. ${sale.id}')
      ..writeln('Date: ${AppFormat.dateTimeShort(sale.date)}')
      ..writeln('')
      ..writeln('Sold to: ${sale.customerName}')
      ..writeln('');
    for (final line in sale.lineItems) {
      b
        ..writeln(line.item.description)
        ..writeln('  ${AppFormat.karat(line.item.karat)} · ${AppFormat.grams(line.effectiveFinalGrams)}'
            ' — ${AppFormat.peso(line.negotiatedPriceCentavos)}');
    }
    b
      ..writeln('')
      ..writeln('TOTAL: ${AppFormat.peso(sale.totalAmountCentavos)}');
    if (sale.payment.cashCentavos > 0) b.writeln('Cash: ${AppFormat.peso(sale.payment.cashCentavos)}');
    if (sale.payment.bankCentavos > 0) b.writeln('Bank transfer: ${AppFormat.peso(sale.payment.bankCentavos)}');
    b.writeln('Thank you for your purchase.');
    return b.toString().trim();
  }

  /// Sends the receipt as a real PDF file attachment.
  static Future<void> sharePdf(Uint8List bytes, String filename, {String? subject}) {
    return SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/pdf', name: filename)],
        fileNameOverrides: [filename],
        subject: subject ?? filename,
      ),
    );
  }

  /// Sends the receipt as a text message.
  static Future<void> shareText(String text, {String? subject}) {
    return SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  /// Opens the system print dialog for the receipt.
  static Future<void> print(Uint8List bytes, String filename) {
    return Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
  }

  // --- building blocks -------------------------------------------------------

  static List<pw.Widget> _header({
    required String title,
    required String branchLabel,
    required String receiptNo,
    required DateTime date,
  }) {
    return [
      pw.Center(
        child: pw.Text(
          _shopName,
          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.Center(child: pw.Text('$branchLabel Branch', style: const pw.TextStyle(fontSize: 9))),
      pw.SizedBox(height: 6),
      pw.Center(
        child: pw.Text(title, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      ),
      pw.SizedBox(height: 6),
      _row('Receipt No.', receiptNo),
      _row('Date', AppFormat.dateTimeShort(date)),
    ];
  }

  static List<pw.Widget> _customerBlock({
    required String label,
    required String name,
    String? contact,
    String? address,
  }) {
    return [
      pw.Text(label.toUpperCase(), style: const pw.TextStyle(fontSize: 7)),
      pw.Text(name, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      if (contact != null && contact.isNotEmpty)
        pw.Text(contact, style: const pw.TextStyle(fontSize: 8)),
      if (address != null && address.isNotEmpty)
        pw.Text(address, style: const pw.TextStyle(fontSize: 8)),
    ];
  }

  static List<pw.Widget> _purchaseLine(Item item) {
    return [
      pw.SizedBox(height: 4),
      pw.Text(item.description, style: const pw.TextStyle(fontSize: 9)),
      _row(
        '${AppFormat.karat(item.karat)} · ${AppFormat.grams(item.weightGrams)} net',
        AppFormat.peso(item.capitalAmountCentavos),
      ),
      if (item.deductedGrams > 0.0005)
        pw.Text(
          'gross ${AppFormat.grams(item.effectiveGrossWeightGrams)}, '
          'less ${AppFormat.grams(item.deductedGrams)}',
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
      pw.Text('Item ${item.id}', style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
    ];
  }

  static List<pw.Widget> _saleLine(SaleLineItem line) {
    return [
      pw.SizedBox(height: 4),
      pw.Text(line.item.description, style: const pw.TextStyle(fontSize: 9)),
      _row(
        '${AppFormat.karat(line.item.karat)} · ${AppFormat.grams(line.effectiveFinalGrams)}',
        AppFormat.peso(line.negotiatedPriceCentavos),
      ),
      pw.Text(
        '${AppFormat.peso(line.pricePerGramCentavos)} per gram',
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
      ),
      pw.Text('Item ${line.item.id}', style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
    ];
  }

  static List<pw.Widget> _footer({required String note}) {
    return [
      pw.SizedBox(height: 6),
      pw.Text(note, style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
      pw.SizedBox(height: 18),
      pw.Container(height: 0.6, color: PdfColors.grey600),
      pw.Text('Customer signature', style: const pw.TextStyle(fontSize: 7)),
      pw.SizedBox(height: 8),
      pw.Center(
        child: pw.Text(
          'This is a system-generated receipt.',
          style: const pw.TextStyle(fontSize: 6, color: PdfColors.grey700),
        ),
      ),
    ];
  }

  static pw.Widget _row(String left, String right) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: pw.Text(left, style: const pw.TextStyle(fontSize: 8))),
        pw.Text(right, style: const pw.TextStyle(fontSize: 8)),
      ],
    );
  }

  static pw.Widget _totalRow(String label, int centavos) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Text(
          AppFormat.peso(centavos),
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
        ),
      ],
    );
  }

  static pw.Widget _divider() {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Container(height: 0.6, color: PdfColors.grey500),
    );
  }
}
