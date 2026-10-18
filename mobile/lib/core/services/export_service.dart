import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_repository.dart';
import '../data/staff_directory.dart';
import '../models/branch.dart';
import '../models/cash_entry.dart';
import 'export_formats.dart';

/// What can be exported from the app grid.
enum ExportKind {
  purchases,
  sales,
  expenses,
  withdrawals;

  String get label {
    switch (this) {
      case ExportKind.purchases:
        return 'Purchases';
      case ExportKind.sales:
        return 'Sales';
      case ExportKind.expenses:
        return 'Expenses';
      case ExportKind.withdrawals:
        return 'Withdrawals';
    }
  }

  IconData get icon {
    switch (this) {
      case ExportKind.purchases:
        return Icons.add_shopping_cart_rounded;
      case ExportKind.sales:
        return Icons.storefront_rounded;
      case ExportKind.expenses:
        return Icons.receipt_long_rounded;
      case ExportKind.withdrawals:
        return Icons.north_east_rounded;
    }
  }
}

/// A built export: the table, plus what the screen needs to describe it.
class ExportTable {
  final List<String> headers;
  final List<List<String>> rows;

  /// Sum of the amount column, in centavos.
  final int totalCentavos;

  const ExportTable({required this.headers, required this.rows, required this.totalCentavos});

  /// CSV with a UTF-8 byte-order mark, so Excel opens names with ñ correctly
  /// instead of guessing the wrong encoding.
  Uint8List toCsvBytes() {
    final buffer = StringBuffer();
    buffer.writeln(headers.map(_cell).join(','));
    for (final row in rows) {
      buffer.writeln(row.map(_cell).join(','));
    }
    return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(buffer.toString())]);
  }

  static String _cell(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}

/// Turns the shop's records into spreadsheets for the bookkeeper.
///
/// Amounts are plain numbers in pesos (no ₱, no thousands separators) so a
/// spreadsheet can total them; dates are ISO so they sort.
class ExportService {
  ExportService._();

  static ExportTable build(
    AppRepository repo,
    ExportKind kind, {
    required BranchId? branch,
    required DateTimeRange? range,
  }) {
    switch (kind) {
      case ExportKind.purchases:
        return _purchases(repo, branch, range);
      case ExportKind.sales:
        return _sales(repo, branch, range);
      case ExportKind.expenses:
        return _cash(repo, branch, range, CashEntryType.expense);
      case ExportKind.withdrawals:
        return _cash(repo, branch, range, CashEntryType.withdrawal);
    }
  }

  static String filename(ExportKind kind, BranchId? branch, DateTimeRange? range, ExportFormat format) {
    final scope = branch?.name ?? 'all-branches';
    final period = range == null ? 'all-dates' : '${_date(range.start)}_to_${_date(range.end)}';
    return 'aj-jeweler_${kind.name}_${scope}_$period.${format.extension}';
  }

  /// What the file says it covers, under its title.
  static String subtitle(ExportKind kind, BranchId? branch, DateTimeRange? range) {
    final scope = branch?.label ?? 'Both branches';
    final period = range == null
        ? 'All dates'
        : '${_date(range.start)} to ${_date(range.end)}';
    return '$scope · $period · exported ${_dateTime(DateTime.now())}';
  }

  /// Builds the file in [format] and hands it to the share sheet.
  static Future<void> share(
    ExportTable table,
    String filename, {
    required ExportKind kind,
    required ExportFormat format,
    required BranchId? branch,
    required DateTimeRange? range,
  }) async {
    final bytes = await ExportFormats.build(
      table,
      format,
      title: '${kind.label} export',
      subtitle: subtitle(kind, branch, range),
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: format.mimeType, name: filename)],
        fileNameOverrides: [filename],
        subject: filename,
      ),
    );
  }

  // --- tables ---------------------------------------------------------------

  static ExportTable _purchases(AppRepository repo, BranchId? branch, DateTimeRange? range) {
    final batches = repo.purchaseBatchesForBranch(branch).where((b) => _inRange(b.date, range)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final rows = <List<String>>[];
    var total = 0;
    for (final batch in batches) {
      // The lots the customer handed over — partitions are later splits of
      // them and were never paid for separately.
      for (final item in repo.itemsInBatch(batch.id).where((i) => !i.isPartitioned)) {
        final amount = item.effectiveOriginalAmountCentavos;
        total += amount;
        rows.add([
          _dateTime(batch.date),
          batch.id,
          item.id,
          batch.branch.label,
          batch.customer.name,
          batch.customer.contactNumber ?? '',
          item.description,
          item.type.label,
          _purity(item.karat),
          (item.grossWeightGrams ?? item.weightGrams).toStringAsFixed(3),
          item.effectiveOriginalGrams.toStringAsFixed(3),
          _pesos(amount),
          batch.verificationStatus.label,
          _person(batch.submittedByUserId),
          _person(batch.releasedByUserId),
        ]);
      }
    }
    return ExportTable(
      headers: const [
        'Date', 'Purchase ID', 'Item ID', 'Branch', 'Customer', 'Contact', 'Description', 'Type',
        'Karat/Purity', 'Original weight (g)', 'Net weight (g)', 'Amount (PHP)', 'Status',
        'Encoded by', 'Cash released by',
      ],
      rows: rows,
      totalCentavos: total,
    );
  }

  static ExportTable _sales(AppRepository repo, BranchId? branch, DateTimeRange? range) {
    final sales = repo.salesForBranch(branch).where((s) => _inRange(s.date, range)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final rows = <List<String>>[];
    var total = 0;
    for (final sale in sales) {
      for (final line in sale.lineItems) {
        total += line.negotiatedPriceCentavos;
        rows.add([
          _dateTime(sale.date),
          sale.id,
          line.item.id,
          sale.branch.label,
          sale.customerName,
          sale.customer.contactNumber ?? '',
          line.item.description,
          line.item.type.label,
          _purity(line.item.karat),
          line.effectiveFinalGrams.toStringAsFixed(3),
          _pesos(line.pricePerGramCentavos),
          _pesos(line.negotiatedPriceCentavos),
          _pesos(sale.payment.cashCentavos),
          _pesos(sale.payment.bankCentavos),
          sale.verificationStatus.label,
          _person(sale.submittedByUserId),
          _person(sale.receivedByUserId),
        ]);
      }
    }
    return ExportTable(
      headers: const [
        'Date', 'Sale ID', 'Item ID', 'Branch', 'Customer', 'Contact', 'Description', 'Type',
        'Karat/Purity', 'Weight (g)', 'Price per gram (PHP)', 'Line amount (PHP)',
        'Order cash paid (PHP)', 'Order bank paid (PHP)', 'Status', 'Sales rep', 'Received by',
      ],
      rows: rows,
      totalCentavos: total,
    );
  }

  static ExportTable _cash(AppRepository repo, BranchId? branch, DateTimeRange? range, CashEntryType type) {
    final entries = repo
        .cashEntriesForBranch(branch)
        .where((e) => e.type == type && _inRange(e.date, range))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    var total = 0;
    final rows = <List<String>>[];
    for (final e in entries) {
      total += e.amountCentavos;
      rows.add([
        _dateTime(e.date),
        e.id,
        e.branch.label,
        e.account.label,
        if (type == CashEntryType.expense) e.category ?? '',
        e.note,
        _pesos(e.amountCentavos),
        e.isManual ? 'Manual' : 'Linked (${e.sourceType.name})',
        _person(e.recordedByUserId, fallback: e.recordedByRole.label),
      ]);
    }
    return ExportTable(
      headers: [
        'Date', 'Entry ID', 'Branch', 'Cash source',
        if (type == CashEntryType.expense) 'Category',
        'Note', 'Amount (PHP)', 'Origin', 'Recorded by',
      ],
      rows: rows,
      totalCentavos: total,
    );
  }

  // --- formatting -----------------------------------------------------------

  static bool _inRange(DateTime at, DateTimeRange? range) {
    if (range == null) return true;
    final d = DateTime(at.year, at.month, at.day);
    return !d.isBefore(range.start) && !d.isAfter(range.end);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static String _dateTime(DateTime d) => '${_date(d)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _pesos(int centavos) => (centavos / 100).toStringAsFixed(2);
  static String _purity(int karat) => karat >= 100 ? '$karat silver' : '${karat}K';
  static String _person(String? userId, {String fallback = ''}) => StaffDirectory.byId(userId)?.name ?? fallback;
}
