import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/stored_receipt.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/receipt_actions.dart';
import '../../core/widgets/search_field.dart';
import '../../core/navigation/layout.dart';

/// Every receipt the shop has issued, newest first — the copies kept on this
/// side of the counter.
///
/// A receipt that only ever existed in a share sheet is gone the moment it is
/// sent; filing them here means a customer can be re-sent theirs, or a
/// disputed transaction can be checked against what was actually handed over.
class ReceiptsScreen extends StatefulWidget {
  const ReceiptsScreen({super.key});

  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final branchId = context.watch<AppState>().selectedBranch;

    var receipts = repo.receiptsForBranch(branchId);
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      receipts = receipts
          .where((r) =>
              r.counterparty.toLowerCase().contains(q) ||
              r.recordId.toLowerCase().contains(q))
          .toList();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Receipts')),
      body: ReadableWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SearchField(
                hintText: 'Search receipts by customer or record id',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: receipts.isEmpty
                  ? EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: q.isEmpty ? 'No receipts issued yet' : 'No receipts match this search',
                      message: q.isEmpty
                          ? 'A receipt is filed here the moment a Cashier releases cash on a '
                              'purchase or receives payment on a sale.'
                          : null,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                      itemCount: receipts.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _ReceiptTile(receipt: receipts[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptTile extends StatelessWidget {
  final StoredReceipt receipt;

  const _ReceiptTile({required this.receipt});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final isPurchase = receipt.kind == ReceiptKind.purchase;
    final accent = isPurchase ? sc.buyGreen : sc.sellCoral;

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReceiptViewerScreen(receipt: receipt)),
      ),
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        ),
        child: Icon(
          isPurchase ? Icons.south_west_rounded : Icons.north_east_rounded,
          color: accent,
          size: 20,
        ),
      ),
      title: Text(
        receipt.counterparty,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${receipt.kind.label} ${receipt.recordId} · ${receipt.branch.label} · '
        '${AppFormat.dateShort(receipt.issuedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: Text(
        AppFormat.peso(receipt.totalCentavos, whole: true),
        style: AppTextStyles.numericMedium.copyWith(color: accent),
      ),
    );
  }
}
