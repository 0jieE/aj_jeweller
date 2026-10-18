import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/purchase_batch.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import 'purchase_batch_detail_screen.dart';
import '../../core/navigation/layout.dart';

/// The Cashier's work queue: purchases encoded by an Appraiser, oldest
/// first, waiting to be checked against the physical pieces and paid for.
///
/// Rows are whole transactions rather than pieces — the customer is paid once
/// for everything they brought in, so that is the decision being queued.
class VerificationQueueScreen extends StatelessWidget {
  const VerificationQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();

    final queue = repo.purchaseBatchesAwaitingRelease(branchId: appState.selectedBranch)
      ..sort((a, b) => a.date.compareTo(b.date));

    if (queue.isEmpty) {
      return const EmptyState(
        title: "You're all caught up",
        message: 'No purchases are waiting on cash release.',
      );
    }

    return ReadableWidth(
      maxWidth: 820,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        itemCount: queue.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final batch = queue[i];
          return _BatchQueueTile(
            batch: batch,
            itemCount: repo.itemsInBatch(batch.id).length,
            totalCentavos: repo.batchTotalCentavos(batch.id),
          );
        },
      ),
    );
  }
}

class _BatchQueueTile extends StatelessWidget {
  final PurchaseBatch batch;
  final int itemCount;
  final int totalCentavos;

  const _BatchQueueTile({
    required this.batch,
    required this.itemCount,
    required this.totalCentavos,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PurchaseBatchDetailScreen(batchId: batch.id)),
      ),
      leading: TransactionCustomerAvatar(customer: batch.customer, radius: 22),
      title: Text(
        batch.customer.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'Purchase ${batch.id} · $itemCount item(s) · ${AppFormat.dateShort(batch.date)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: Text(
        AppFormat.peso(totalCentavos, whole: true),
        style: AppTextStyles.numericMedium.copyWith(color: sc.buyGreen),
      ),
    );
  }
}
