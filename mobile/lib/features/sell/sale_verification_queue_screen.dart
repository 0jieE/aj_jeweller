import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import 'sale_verification_detail_screen.dart';

/// The Cashier's work queue: orders a Sales Rep has sent over, oldest
/// first, waiting for the pieces to be checked and payment received.
class SaleVerificationQueueScreen extends StatelessWidget {
  const SaleVerificationQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();

    final queue = repo.salesAwaitingPayment(branchId: appState.selectedBranch)
      ..sort((a, b) => a.date.compareTo(b.date));

    if (queue.isEmpty) {
      return const EmptyState(
        title: "You're all caught up",
        message: 'No orders are waiting on payment.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs, horizontal: AppSpacing.md),
      itemCount: queue.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final sale = queue[i];
        return InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SaleVerificationDetailScreen(saleId: sale.id)),
          ),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.cardSurface,
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              border: Border.all(color: AppColors.outline),
            ),
            child: Row(
              children: [
                TransactionCustomerAvatar(customer: sale.customer, radius: 20),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sale.customerName, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
                      Text(
                        '${sale.lineItems.length} item(s) · ${sale.payment.label} · ${AppFormat.dateShort(sale.date)}',
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                Text(AppFormat.peso(sale.totalAmountCentavos), style: AppTextStyles.numericMedium),
              ],
            ),
          ),
        );
      },
    );
  }
}
