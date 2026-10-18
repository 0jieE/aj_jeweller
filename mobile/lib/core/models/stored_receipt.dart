import 'dart:typed_data';

import 'branch.dart';

/// What kind of transaction a receipt documents.
enum ReceiptKind {
  purchase,
  sale;

  String get label {
    switch (this) {
      case ReceiptKind.purchase:
        return 'Purchase';
      case ReceiptKind.sale:
        return 'Sale';
    }
  }
}

/// A receipt the shop has issued, kept inside the app.
///
/// Generating a PDF and handing it straight to a share sheet leaves the shop
/// with no copy of what the customer was given — so every receipt is filed
/// here as it is issued, and can be reopened, re-shared, or reprinted from
/// the Receipts page afterwards.
class StoredReceipt {
  final String id;

  /// The purchase batch or sale this documents.
  final String recordId;

  final ReceiptKind kind;
  final BranchId branch;

  /// Who the receipt was made out to.
  final String counterparty;

  final int totalCentavos;
  final DateTime issuedAt;
  final Uint8List bytes;

  /// The same receipt as plain text, for sending in a chat or SMS where a
  /// PDF attachment is awkward to open.
  final String text;

  const StoredReceipt({
    required this.id,
    required this.recordId,
    required this.kind,
    required this.branch,
    required this.counterparty,
    required this.totalCentavos,
    required this.issuedAt,
    required this.bytes,
    this.text = '',
  });

  String get filename => '${kind.name}-$recordId.pdf';
}
