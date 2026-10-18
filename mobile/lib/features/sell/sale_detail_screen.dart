import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/sale.dart';
import '../../core/models/stored_receipt.dart';
import '../../core/services/receipt_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/receipt_actions.dart';
import '../../core/widgets/record_activity.dart';
import '../../core/widgets/status_badges.dart';

/// One completed sale, as a record rather than a workflow step: what went
/// out, at what weight and rate, to whom, and for how much.
///
/// Issuing the receipt files the shop's own copy as it produces the
/// customer's, so the document survives in the app rather than only in
/// whatever the share sheet was pointed at.
class SaleDetailScreen extends StatelessWidget {
  final String saleId;

  const SaleDetailScreen({super.key, required this.saleId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final sale = repo.findSale(saleId);

    if (sale == null) {
      return const Scaffold(body: Center(child: Text('Sale not found')));
    }

    final totalGrams = sale.lineItems.fold<double>(0, (g, l) => g + l.effectiveFinalGrams);

    return Scaffold(
      appBar: AppBar(title: const Text('Sale Record')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _HeaderCard(sale: sale, totalGrams: totalGrams),
          const SizedBox(height: AppSpacing.sm),
          AccountabilityCard(
            children: [
              AttributionRow(
                icon: Icons.shopping_bag_outlined,
                label: 'Sold by',
                userId: sale.submittedByUserId,
                at: sale.date,
              ),
              AttributionRow(
                icon: Icons.point_of_sale_outlined,
                label: 'Payment received by',
                userId: sale.receivedByUserId,
                pendingText: 'Not yet received',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Items Sold', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final line in sale.lineItems) ...[
            _SaleLineCard(line: line),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.md),
          ReceiptActions(
            recordId: sale.id,
            kind: ReceiptKind.sale,
            branch: sale.branch,
            counterparty: sale.customerName,
            totalCentavos: sale.totalAmountCentavos,
            buildReceipt: () => ReceiptService.sale(sale: sale),
            buildText: () => ReceiptService.saleText(sale: sale),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Activity', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          RecordActivityList(entries: repo.logsForRecord(sale.id)),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final Sale sale;
  final double totalGrams;

  const _HeaderCard({required this.sale, required this.totalGrams});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;

    return Container(
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TransactionCustomerAvatar(customer: sale.customer, radius: 26),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sale.customerName, style: AppTextStyles.headlineMedium.copyWith(fontSize: 19)),
                    if (sale.customer.contactNumber != null)
                      Text(sale.customer.contactNumber!, style: AppTextStyles.bodyMedium),
                    if (sale.customer.address != null)
                      Text(
                        sale.customer.address!,
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              VerificationStatusBadge(status: sale.verificationStatus),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Receipt ${sale.id} · ${sale.branch.label} · ${AppFormat.dateTimeShort(sale.date)}',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  label: 'Total',
                  value: AppFormat.peso(sale.totalAmountCentavos),
                  color: sc.sellCoral,
                ),
              ),
              Expanded(
                child: _Figure(label: 'Weight sold', value: AppFormat.grams(totalGrams)),
              ),
              Expanded(
                child: _Figure(label: 'Paid by', value: sale.payment.label),
              ),
            ],
          ),
          if (sale.note != null && sale.note!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(sale.note!, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }
}

class _SaleLineCard extends StatelessWidget {
  final SaleLineItem line;

  const _SaleLineCard({required this.line});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (line.item.hasPhoto)
                ItemPhotoThumbnail(photo: line.item.photo!, label: line.item.description, size: 40)
              else
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: PurityPalette.of(context, line.item.karat).surface,
                    borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                  ),
                  child: Text(
                    AppFormat.karat(line.item.karat),
                    style: AppTextStyles.numericSmall.copyWith(
                      color: PurityPalette.of(context, line.item.karat).text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.item.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'Item ${line.item.id}',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  label: 'Final weight',
                  value: AppFormat.grams(line.effectiveFinalGrams),
                ),
              ),
              Expanded(
                child: _Figure(
                  label: 'Per gram',
                  value: AppFormat.peso(line.pricePerGramCentavos),
                ),
              ),
              Expanded(
                child: _Figure(
                  label: 'Price',
                  value: AppFormat.peso(line.negotiatedPriceCentavos),
                  color: sc.sellCoral,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Figure({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        Text(
          value,
          style: AppTextStyles.numericSmall.copyWith(color: color ?? AppColors.textPrimary),
        ),
      ],
    );
  }
}
