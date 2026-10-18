import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../commitment/commitment_detail_screen.dart';
import '../purchase/lot_detail_screen.dart';
import '../../core/navigation/layout.dart';

/// The full record for one disposal batch — what the "repayment history"
/// on a commitment's ledger links into, and what the disposal history list
/// links into as well.
class DisposalBatchDetailScreen extends StatelessWidget {
  final String batchId;

  const DisposalBatchDetailScreen({super.key, required this.batchId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final batch = repo.findDisposalBatch(batchId);

    if (batch == null) {
      return const Scaffold(body: Center(child: Text('Disposal batch not found')));
    }

    final sc = context.semanticColors;
    final isProfit = batch.netCentavos >= 0;
    final commitment = repo.findCommitment(batch.commitmentRef);
    final karatBreakdown = repo.karatBreakdown(batch.id);
    final items = repo.itemsInDisposal(batch.id);

    return Scaffold(
      appBar: AppBar(title: Text(batch.id)),
      body: DetailPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${batch.branch.label} · ${batch.itemIds.length} item(s)', style: AppTextStyles.titleMedium),
                      Text(AppFormat.dateShort(batch.date), style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                  if (batch.photo != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        ItemPhotoThumbnail(photo: batch.photo!, label: 'Disposal ${batch.id}', size: 64),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            'Disposal photo — tap to enlarge.',
                            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  const Divider(),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(child: _Figure(label: 'Capital', value: AppFormat.peso(batch.capitalCentavos, whole: true))),
                      Expanded(child: _Figure(label: 'Gross Grams', value: AppFormat.grams(batch.grossGrams), color: sc.gold)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: _Figure(
                          label: 'Gross Amount',
                          value: AppFormat.peso(batch.grossAmountCentavos, whole: true),
                        ),
                      ),
                      Expanded(
                        child: _Figure(
                          label: 'Net (shop profit)',
                          value: AppFormat.pesoSigned(batch.netCentavos),
                          color: isProfit ? sc.success : sc.danger,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Gross amount and shop profit are independent figures — gross is what pays down a loan, '
                      'profit (gross minus capital) is what the shop earns. One is never derived from the other.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            if (commitment != null) ...[
              const SizedBox(height: AppSpacing.md),
              InkWell(
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitmentId: commitment.id)),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
                  decoration: BoxDecoration(
                    color: sc.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                    border: Border.all(color: sc.danger.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.handshake_outlined, size: 18, color: sc.danger),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                            children: [
                              const TextSpan(text: 'This gross amount applies toward: '),
                              TextSpan(
                                text: commitment.lender,
                                style: TextStyle(color: sc.danger, fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: sc.danger),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            // What actually left the shop. The karat totals are what the refiner
            // settles against; the pieces underneath are what gets checked off
            // against their weigh-in slip when the figures disagree.
            Text('Delivered', style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            if (karatBreakdown.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in karatBreakdown)
                    _KaratGramChip(karat: entry.key, grams: entry.value),
                ],
              ),
            const SizedBox(height: AppSpacing.sm),
            if (items.isEmpty)
              Text(
                'The pieces in this batch are no longer on record.',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: AppColors.cardSurface,
                  borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _DeliveredItemRow(item: items[i]),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One karat's share of a delivery — the karat tag and the grams that came in
/// at it, in the gold colours those figures use everywhere else.
class _KaratGramChip extends StatelessWidget {
  final int karat;
  final double grams;

  const _KaratGramChip({required this.karat, required this.grams});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: sc.goldSurface,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        border: Border.all(color: sc.goldLight.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppFormat.karat(karat),
            style: AppTextStyles.labelSmall.copyWith(
              color: sc.goldDark,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            AppFormat.grams(grams),
            style: AppTextStyles.numericSmall.copyWith(color: sc.goldDark),
          ),
        ],
      ),
    );
  }
}

/// One piece within a delivery: what it was, its karat and weight, and the
/// capital that went out with it.
class _DeliveredItemRow extends StatelessWidget {
  final Item item;

  const _DeliveredItemRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: item.id)),
      ),
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sc.goldSurface,
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        ),
        child: Text(
          AppFormat.karat(item.karat),
          style: AppTextStyles.numericSmall.copyWith(
            color: sc.goldDark,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(
        item.description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'Item ${item.id} · ${item.origin}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            AppFormat.grams(item.effectiveRemainingGrams),
            style: AppTextStyles.numericSmall.copyWith(color: sc.goldDark),
          ),
          Text(
            AppFormat.peso(item.effectiveRemainingAmountCentavos, whole: true),
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
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
        Text(value, style: AppTextStyles.numericBody.copyWith(color: color ?? AppColors.textPrimary)),
      ],
    );
  }
}
