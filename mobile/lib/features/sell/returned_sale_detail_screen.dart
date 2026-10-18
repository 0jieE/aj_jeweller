import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/sale.dart';
import '../../core/state/cart_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/formatters.dart';
import 'order_summary_screen.dart';
import '../../core/navigation/layout.dart';

/// A single Cashier-returned order: what the customer ordered, why it was
/// sent back, and the door into fixing it (which reloads the order into
/// the working cart for editing).
class ReturnedSaleDetailScreen extends StatelessWidget {
  final String saleId;

  const ReturnedSaleDetailScreen({super.key, required this.saleId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final sale = repo.findSale(saleId);

    if (sale == null) {
      return const Scaffold(body: Center(child: Text('Order not found')));
    }

    final sc = context.semanticColors;

    return Scaffold(
      appBar: AppBar(title: const Text('Returned Order')),
      body: DetailPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: sc.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                border: Border.all(color: sc.danger.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.flag_rounded, color: sc.danger, size: 18),
                      const SizedBox(width: AppSpacing.sm),
                      Text('Returned for correction', style: AppTextStyles.titleMedium.copyWith(color: sc.danger)),
                    ],
                  ),
                  if (sale.verificationNote != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(sale.verificationNote!, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textPrimary)),
                  ],
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      TransactionCustomerAvatar(customer: sale.customer, radius: 22),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(sale.customerName, style: AppTextStyles.headlineMedium.copyWith(fontSize: 19)),
                      ),
                    ],
                  ),
                  if (sale.note != null) ...[
                    const SizedBox(height: 2),
                    Text(sale.note!, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  const Divider(),
                  for (final line in sale.lineItems)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(line.item.description, style: AppTextStyles.bodyMedium)),
                          Text(AppFormat.peso(line.negotiatedPriceCentavos), style: AppTextStyles.numericSmall),
                        ],
                      ),
                    ),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total', style: AppTextStyles.titleMedium),
                      Text(AppFormat.peso(sale.totalAmountCentavos), style: AppTextStyles.numericMedium),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton.icon(
              icon: const Icon(Icons.edit_rounded),
              label: const Text('Fix & Resubmit'),
              onPressed: () => _startFixing(context, sale),
            ),
          ],
        ),
      ),
    );
  }

  void _startFixing(BuildContext context, Sale sale) async {
    final cart = context.read<CartState>();
    if (!cart.isEmpty && cart.editingSaleId != sale.id) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Replace current order?'),
          content: Text(
            'You already have ${cart.itemCount} item(s) in an order in progress. '
            'Opening this returned order will replace it.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Replace')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!context.mounted) return;
    cart.startEditingSale(sale);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OrderSummaryScreen()));
  }
}
