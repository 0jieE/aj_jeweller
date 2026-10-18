import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_service.dart';

/// The file an export is handed over as.
enum ExportFormat {
  csv,
  excel,
  pdf;

  String get label {
    switch (this) {
      case ExportFormat.csv:
        return 'CSV';
      case ExportFormat.excel:
        return 'Excel';
      case ExportFormat.pdf:
        return 'PDF';
    }
  }

  String get extension {
    switch (this) {
      case ExportFormat.csv:
        return 'csv';
      case ExportFormat.excel:
        return 'xlsx';
      case ExportFormat.pdf:
        return 'pdf';
    }
  }

  String get mimeType {
    switch (this) {
      case ExportFormat.csv:
        return 'text/csv';
      case ExportFormat.excel:
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case ExportFormat.pdf:
        return 'application/pdf';
    }
  }

  String get description {
    switch (this) {
      case ExportFormat.csv:
        return 'Opens anywhere — any spreadsheet or accounting app';
      case ExportFormat.excel:
        return 'Excel workbook with a header row and real numbers';
      case ExportFormat.pdf:
        return 'For printing or sending as a read-only report';
    }
  }

  IconData get icon {
    switch (this) {
      case ExportFormat.csv:
        return Icons.description_outlined;
      case ExportFormat.excel:
        return Icons.table_chart_outlined;
      case ExportFormat.pdf:
        return Icons.picture_as_pdf_outlined;
    }
  }
}

/// Turns a built [ExportTable] into the chosen file.
///
/// The spreadsheet is written as a minimal .xlsx by hand — a zip of the few
/// XML parts Excel needs — rather than pulling in a spreadsheet library for
/// what is only ever a header row and plain rows. Numbers are written as
/// numbers so totals can be summed on arrival, not as text.
class ExportFormats {
  ExportFormats._();

  static const _shopName = 'AJ JEWELER';

  static Future<Uint8List> build(
    ExportTable table,
    ExportFormat format, {
    required String title,
    required String subtitle,
  }) async {
    switch (format) {
      case ExportFormat.csv:
        return table.toCsvBytes();
      case ExportFormat.excel:
        return _xlsx(table, sheetName: title);
      case ExportFormat.pdf:
        return _pdf(table, title: title, subtitle: subtitle);
    }
  }

  // --- Excel ------------------------------------------------------------------

  /// True for a cell Excel should treat as a number (amounts, weights).
  static bool _isNumeric(String value) =>
      value.isNotEmpty && RegExp(r'^-?\d+(\.\d+)?$').hasMatch(value);

  static String _escape(String v) => const HtmlEscape(HtmlEscapeMode.element).convert(v);

  static String _column(int index) {
    var i = index;
    final buffer = StringBuffer();
    do {
      buffer.write(String.fromCharCode(65 + (i % 26)));
      i = (i ~/ 26) - 1;
    } while (i >= 0);
    return buffer.toString().split('').reversed.join();
  }

  static Uint8List _xlsx(ExportTable table, {required String sheetName}) {
    final rows = StringBuffer();

    void writeRow(int rowIndex, List<String> cells, {bool header = false}) {
      rows.write('<row r="${rowIndex + 1}">');
      for (var c = 0; c < cells.length; c++) {
        final ref = '${_column(c)}${rowIndex + 1}';
        final value = cells[c];
        if (!header && _isNumeric(value)) {
          rows.write('<c r="$ref"><v>$value</v></c>');
        } else {
          rows.write('<c r="$ref" t="inlineStr" s="${header ? 1 : 0}">'
              '<is><t xml:space="preserve">${_escape(value)}</t></is></c>');
        }
      }
      rows.write('</row>');
    }

    writeRow(0, table.headers, header: true);
    for (var r = 0; r < table.rows.length; r++) {
      writeRow(r + 1, table.rows[r]);
    }

    // Columns sized from the longest value in each, so nothing opens as ####.
    final widths = StringBuffer('<cols>');
    for (var c = 0; c < table.headers.length; c++) {
      var longest = table.headers[c].length;
      for (final row in table.rows) {
        if (c < row.length && row[c].length > longest) longest = row[c].length;
      }
      widths.write('<col min="${c + 1}" max="${c + 1}" width="${(longest + 2).clamp(9, 42)}" customWidth="1"/>');
    }
    widths.write('</cols>');

    final sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetViews><sheetView workbookViewId="0">'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>'
        '$widths<sheetData>$rows</sheetData></worksheet>';

    final workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="${_escape(_sheetName(sheetName))}" sheetId="1" r:id="rId1"/></sheets></workbook>';

    const workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>';

    const rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>';

    // Two formats: plain, and bold for the header row.
    const styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
        '<borders count="1"><border/></borders>'
        '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="2"><xf xfId="0"/><xf fontId="1" applyFont="1" xfId="0"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>';

    const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>';

    final archive = Archive();
    void add(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('[Content_Types].xml', contentTypes);
    add('_rels/.rels', rootRels);
    add('xl/workbook.xml', workbook);
    add('xl/_rels/workbook.xml.rels', workbookRels);
    add('xl/styles.xml', styles);
    add('xl/worksheets/sheet1.xml', sheet);

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Excel refuses sheet names over 31 characters or containing []:*?/\.
  static String _sheetName(String title) {
    final cleaned = title.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    return cleaned.length <= 31 ? cleaned : cleaned.substring(0, 31);
  }

  // --- PDF --------------------------------------------------------------------

  static pw.ThemeData? _pdfTheme;

  /// The bundled Roboto, not the built-in Helvetica: shop data is full of
  /// en dashes and ñ, which the built-in font cannot draw.
  static Future<pw.ThemeData> _theme() async {
    final cached = _pdfTheme;
    if (cached != null) return cached;
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    return _pdfTheme = pw.ThemeData.withFont(base: regular, bold: bold);
  }

  static Future<Uint8List> _pdf(ExportTable table, {required String title, required String subtitle}) async {
    final doc = pw.Document(theme: await _theme());
    // Landscape: these tables are wide, and a squeezed portrait page is what
    // makes printed reports unreadable.
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox()
            : pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 8),
                child: pw.Text('$title (continued)', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
              ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
        build: (context) => [
          pw.Text(_shopName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text(title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text(subtitle, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: table.headers,
            data: table.rows,
            cellStyle: const pw.TextStyle(fontSize: 7),
            headerStyle: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            rowDecoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.4)),
            ),
            cellHeight: 14,
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          ),
        ],
      ),
    );
    return doc.save();
  }
}
