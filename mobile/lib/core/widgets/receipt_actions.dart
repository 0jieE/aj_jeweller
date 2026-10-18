import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../data/app_repository.dart';
import '../models/branch.dart';
import '../models/stored_receipt.dart';
import '../services/receipt_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';

/// Issues a record's receipt and keeps the shop's copy.
///
/// The PDF is filed in the app as it is generated, so the customer's copy is
/// never the only one that exists — it can be reopened or re-sent later from
/// the Receipts page. Viewing happens in-app; sharing is a separate, deliberate
/// step.
class ReceiptActions extends StatefulWidget {
  final String recordId;
  final ReceiptKind kind;
  final BranchId branch;
  final String counterparty;
  final int totalCentavos;

  /// Builds the PDF on demand, so nothing is rendered until it is wanted.
  final Future<Uint8List> Function() buildReceipt;

  /// The same receipt as plain text, for sending as a message.
  final String Function() buildText;

  const ReceiptActions({
    super.key,
    required this.recordId,
    required this.kind,
    required this.branch,
    required this.counterparty,
    required this.totalCentavos,
    required this.buildReceipt,
    required this.buildText,
  });

  @override
  State<ReceiptActions> createState() => _ReceiptActionsState();
}

class _ReceiptActionsState extends State<ReceiptActions> {
  bool _busy = false;

  /// Returns the filed copy, generating and filing one on first use.
  Future<StoredReceipt?> _ensureStored() async {
    final repo = context.read<AppRepository>();
    final existing = repo.receiptForRecord(widget.recordId);
    if (existing != null) return existing;

    final bytes = await widget.buildReceipt();
    if (!mounted) return null;
    return repo.storeReceipt(
      recordId: widget.recordId,
      kind: widget.kind,
      branch: widget.branch,
      counterparty: widget.counterparty,
      totalCentavos: widget.totalCentavos,
      bytes: bytes,
      text: widget.buildText(),
    );
  }

  Future<void> _run(Future<void> Function(StoredReceipt receipt) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final receipt = await _ensureStored();
      if (receipt != null) await action(receipt);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not produce the receipt: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final saved = repo.receiptForRecord(widget.recordId);
    // Before the cash moves there is nothing to receipt, and the server
    // would say the same.
    final blocked = saved == null
        ? repo.receiptBlockedReason(widget.recordId, widget.kind)
        : null;
    if (blocked != null) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
          border: Border.all(color: AppColors.outline),
        ),
        child: Row(
          children: [
            const Icon(Icons.receipt_long_outlined, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                blocked,
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run((receipt) async {
                          if (!mounted) return;
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ReceiptViewerScreen(receipt: receipt),
                            ),
                          );
                        }),
                icon: const Icon(Icons.receipt_long_rounded, size: 18),
                label: Text(saved == null ? 'Issue Receipt' : 'View Receipt'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run((receipt) => showShareReceiptSheet(context, receipt)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primaryBlue,
                  side: const BorderSide(color: AppColors.primaryBlue, width: 1.4),
                ),
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('Share'),
              ),
            ),
          ],
        ),
        if (saved != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Saved in the app · issued ${AppFormat.dateTimeShort(saved.issuedAt)}',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// Asks how to send the receipt: as the PDF file itself, or as a text
/// message. A chat app shows a PDF as a small file card the customer has to
/// open; text arrives readable at a glance.
Future<void> showShareReceiptSheet(BuildContext context, StoredReceipt receipt) async {
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Text('Share receipt ${receipt.recordId}', style: AppTextStyles.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_rounded, color: AppColors.danger),
            title: const Text('Send PDF file'),
            subtitle: Text(receipt.filename),
            onTap: () => Navigator.of(sheetContext).pop('pdf'),
          ),
          if (receipt.text.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.chat_rounded, color: AppColors.primaryBlue),
              title: const Text('Send as text message'),
              subtitle: const Text('Receipt details typed out, for Messenger or SMS'),
              onTap: () => Navigator.of(sheetContext).pop('text'),
            ),
          ListTile(
            leading: const Icon(Icons.print_rounded, color: AppColors.textSecondary),
            title: const Text('Print'),
            onTap: () => Navigator.of(sheetContext).pop('print'),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return;
  final subject = '${receipt.kind.label} receipt ${receipt.recordId}';
  try {
    switch (choice) {
      case 'pdf':
        await ReceiptService.sharePdf(receipt.bytes, receipt.filename, subject: subject);
      case 'text':
        await ReceiptService.shareText(receipt.text, subject: subject);
      case 'print':
        await ReceiptService.print(receipt.bytes, receipt.filename);
    }
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('Could not share the receipt: $error')));
  }
}

/// The filed receipt, drawn sharply and zoomable, with share and print.
///
/// Rendered from the PDF at print resolution rather than through a generic
/// preview, which drew it at screen resolution and made it look like a blurry
/// screenshot of a receipt instead of the receipt itself.
class ReceiptViewerScreen extends StatefulWidget {
  final StoredReceipt receipt;

  const ReceiptViewerScreen({super.key, required this.receipt});

  @override
  State<ReceiptViewerScreen> createState() => _ReceiptViewerScreenState();
}

class _ReceiptViewerScreenState extends State<ReceiptViewerScreen> {
  late final Future<List<Uint8List>> _pages = _render();

  Future<List<Uint8List>> _render() async {
    final pages = <Uint8List>[];
    await for (final page in Printing.raster(widget.receipt.bytes, dpi: 300)) {
      pages.add(await page.toPng());
    }
    return pages;
  }

  @override
  Widget build(BuildContext context) {
    final receipt = widget.receipt;
    return Scaffold(
      appBar: AppBar(
        title: Text('${receipt.kind.label} Receipt'),
        actions: [
          IconButton(
            tooltip: 'Print',
            icon: const Icon(Icons.print_rounded),
            onPressed: () => ReceiptService.print(receipt.bytes, receipt.filename),
          ),
        ],
      ),
      backgroundColor: AppColors.surfaceDim,
      body: FutureBuilder<List<Uint8List>>(
        future: _pages,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text('Could not display the receipt: ${snapshot.error}', textAlign: TextAlign.center),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                for (final png in snapshot.data!)
                  Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.md),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 2)),
                      ],
                    ),
                    child: Image.memory(png, fit: BoxFit.fitWidth, filterQuality: FilterQuality.high),
                  ),
                Text(
                  'Pinch to zoom · saved in the app as ${receipt.filename}',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
          child: FilledButton.icon(
            onPressed: () => showShareReceiptSheet(context, receipt),
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share Receipt'),
          ),
        ),
      ),
    );
  }
}
