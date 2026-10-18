import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/data/staff_directory.dart';
import '../../core/models/transaction_log.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/record_activity.dart';
import '../commitment/commitment_detail_screen.dart';
import '../customers/customer_detail_screen.dart';
import '../users/user_form_screen.dart';
import '../disposal_history/disposal_batch_detail_screen.dart';
import '../purchase/lot_detail_screen.dart';
import '../purchase/purchase_batch_detail_screen.dart';
import '../sell/sale_detail_screen.dart';
import '../../core/navigation/layout.dart';

/// One log entry in full, with a way through to the record it concerns.
class LogDetailScreen extends StatelessWidget {
  final TransactionLog entry;

  const LogDetailScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final color = logCategoryColor(context, entry.action.category);
    final user = StaffDirectory.byId(entry.userId);
    final opener = _recordOpener(repo);

    return Scaffold(
      appBar: AppBar(title: Text(entry.action.label)),
      body: DetailPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                    ),
                    child: Icon(entry.action.icon, color: color),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.action.category.label.toUpperCase(),
                          style: AppTextStyles.labelSmall.copyWith(color: color),
                        ),
                        const SizedBox(height: 2),
                        Text(entry.summary, style: AppTextStyles.bodyLarge),
                        if (entry.amountCentavos != null) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            AppFormat.peso(entry.amountCentavos!),
                            style: AppTextStyles.numericMedium.copyWith(color: color),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                children: [
                  _Detail(
                    label: 'By',
                    child: Row(
                      children: [
                        if (user != null) ...[
                          StaffAvatar(user: user, radius: 12),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        Expanded(
                          child: Text(
                            '${entry.userName} · ${entry.role.label}',
                            style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Detail(
                    label: 'When',
                    child: Text(AppFormat.dateTimeShort(entry.at), style: AppTextStyles.bodyMedium),
                  ),
                  _Detail(
                    label: 'Branch',
                    child: Text(
                      entry.branch?.label ?? 'Company-wide',
                      style: AppTextStyles.bodyMedium,
                    ),
                  ),
                  if (entry.recordId != null)
                    _Detail(
                      label: 'Record',
                      child: Row(
                        children: [
                          Text(
                            entry.recordId!,
                            style: AppTextStyles.numericSmall.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          if (opener != null)
                            TextButton.icon(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => opener),
                              ),
                              icon: const Icon(Icons.open_in_new_rounded, size: 16),
                              label: const Text('Open'),
                            )
                          else if (entry.recordKind == LogRecordKind.cashEntry &&
                              repo.findCashEntry(entry.recordId!) != null)
                            Text(
                              'In Cash history',
                              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                            )
                          else
                            Text(
                              'No longer on record',
                              style: AppTextStyles.caption.copyWith(color: AppColors.textDisabled),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (entry.changes.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('What changed', style: AppTextStyles.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              FieldChangeTable(changes: entry.changes),
            ],
          ],
        ),
      ),
    );
  }

  /// The screen for the record this entry names, if it still exists — a
  /// returned partition, for one, is deleted, and the log outlives it.
  Widget? _recordOpener(AppRepository repo) {
    final id = entry.recordId;
    if (id == null) return null;
    switch (entry.recordKind) {
      case LogRecordKind.purchaseBatch:
        return repo.findBatch(id) == null ? null : PurchaseBatchDetailScreen(batchId: id);
      case LogRecordKind.item:
        return repo.findItem(id) == null ? null : LotDetailScreen(itemId: id);
      case LogRecordKind.sale:
        return repo.findSale(id) == null ? null : SaleDetailScreen(saleId: id);
      case LogRecordKind.disposal:
        return repo.findDisposalBatch(id) == null ? null : DisposalBatchDetailScreen(batchId: id);
      case LogRecordKind.commitment:
        return repo.findCommitment(id) == null ? null : CommitmentDetailScreen(commitmentId: id);
      case LogRecordKind.customer:
        return repo.findCustomer(id) == null ? null : CustomerDetailScreen(customerId: id);
      case LogRecordKind.user:
        return repo.findUser(id) == null ? null : UserFormScreen(userId: id);
      case LogRecordKind.cashEntry:
      case null:
        return null;
    }
  }
}

class _Detail extends StatelessWidget {
  final String label;
  final Widget child;

  const _Detail({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
