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
import 'returned_sale_detail_screen.dart';
import '../../core/navigation/layout.dart';

/// Orders the Cashier sent back — the rep works through these to fix and
/// resubmit them.
class ReturnedSalesListScreen extends StatelessWidget {
  const ReturnedSalesListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();

    final returned = repo.salesReturnedForCorrectionFor(appState.role, branchId: appState.selectedBranch)
      ..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: const Text('Returned Orders')),
      body: ReadableWidth(
        child: returned.isEmpty
            ? const EmptyState(
                icon: Icons.flag_outlined,
                title: 'Nothing returned',
                message: 'Orders the Cashier sends back will show up here.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: returned.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, i) {
                  final sale = returned[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ReturnedSaleDetailScreen(saleId: sale.id)),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.cardSurface,
                        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                        border: Border.all(color: context.semanticColors.danger.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    TransactionCustomerAvatar(customer: sale.customer, radius: 14),
                                    const SizedBox(width: AppSpacing.sm),
                                    Flexible(
                                      child: Text(
                                        sale.customerName,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(AppFormat.peso(sale.totalAmountCentavos), style: AppTextStyles.numericMedium),
                            ],
                          ),
                          Text(
                            '${sale.lineItems.length} item(s) · ${AppFormat.dateShort(sale.date)}',
                            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                          ),
                          if (sale.verificationNote != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              sale.verificationNote!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.bodyMedium.copyWith(color: context.semanticColors.danger),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
