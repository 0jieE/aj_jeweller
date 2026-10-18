// Unit tests for the three export files: CSV, Excel workbook, and PDF.

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/services/export_formats.dart';
import 'package:davao_aj_jewellers/core/services/export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ExportTable purchases() => ExportService.build(
        AppRepository(),
        ExportKind.purchases,
        branch: BranchId.kidapawan,
        range: null,
      );

  test('every kind can be built in every format', () async {
    final repo = AppRepository();
    for (final kind in ExportKind.values) {
      final table = ExportService.build(repo, kind, branch: null, range: null);
      for (final format in ExportFormat.values) {
        final bytes = await ExportFormats.build(table, format, title: '${kind.label} export', subtitle: 'test');
        expect(bytes, isNotEmpty, reason: '${kind.name} as ${format.name}');
      }
    }
  });

  test('the Excel file is a workbook with a header row and numeric amounts', () async {
    final table = purchases();
    final bytes = await ExportFormats.build(table, ExportFormat.excel, title: 'Purchases export', subtitle: 'test');

    final zip = ZipDecoder().decodeBytes(bytes);
    final names = zip.files.map((f) => f.name).toSet();
    expect(names, containsAll(['[Content_Types].xml', 'xl/workbook.xml', 'xl/worksheets/sheet1.xml', 'xl/styles.xml']));

    final sheet = utf8.decode(zip.files.firstWhere((f) => f.name == 'xl/worksheets/sheet1.xml').content as List<int>);
    expect(sheet, contains(table.headers.first));
    // One row per record plus the header.
    expect('<row '.allMatches(sheet).length, table.rows.length + 1);
    // Amounts are written as numbers, not text, so a spreadsheet can total them.
    expect(sheet, contains('<v>'));
  });

  test('the PDF is a real PDF document', () async {
    final table = purchases();
    final bytes = await ExportFormats.build(table, ExportFormat.pdf, title: 'Purchases export', subtitle: 'Kidapawan');
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  test('the filename carries the chosen format', () {
    final range = DateTimeRange(start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 30));
    expect(ExportService.filename(ExportKind.sales, BranchId.davao, range, ExportFormat.excel), endsWith('.xlsx'));
    expect(ExportService.filename(ExportKind.sales, null, range, ExportFormat.pdf), contains('all-branches'));
    expect(ExportService.filename(ExportKind.expenses, null, null, ExportFormat.csv), endsWith('all-dates.csv'));
  });

  test('an empty table still produces a valid workbook and PDF', () async {
    final repo = AppRepository()..resetToEmpty();
    final table = ExportService.build(repo, ExportKind.withdrawals, branch: null, range: null);
    expect(table.rows, isEmpty);
    expect(await ExportFormats.build(table, ExportFormat.excel, title: 'Withdrawals', subtitle: ''), isNotEmpty);
    expect(await ExportFormats.build(table, ExportFormat.pdf, title: 'Withdrawals', subtitle: ''), isNotEmpty);
  });
}
