import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/disposal_batch.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import 'disposal_batch_detail_screen.dart';

/// Read-only log of past scrap disposal batches for the selected branch.
class DisposalHistoryScreen extends StatelessWidget {
  const DisposalHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final batches = repo.disposalBatchesForBranch(appState.selectedBranch)
      ..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: const Text('Disposal History')),
      body: batches.isEmpty
          ? const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No disposal batches yet',
              message: 'Completed scrap disposals will show up here.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: batches.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, i) =>
                  _DisposalBatchCard(batch: batches[i]),
            ),
    );
  }
}

class _DisposalBatchCard extends StatelessWidget {
  final DisposalBatch batch;

  const _DisposalBatchCard({required this.batch});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final isProfit = batch.netCentavos >= 0;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DisposalBatchDetailScreen(batchId: batch.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(batch.id, style: AppTextStyles.titleMedium),
                  Text(
                    AppFormat.dateShort(batch.date),
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${batch.branch.label} · ${batch.itemIds.length} item(s)',
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              const Divider(),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _Figure(
                      label: 'Capital',
                      value: AppFormat.peso(batch.capitalCentavos, whole: true),
                    ),
                  ),
                  Expanded(
                    child: _Figure(
                      label: 'Gross grams',
                      value: AppFormat.grams(batch.grossGrams),
                      color: sc.gold,
                    ),
                  ),
                  Expanded(
                    child: _Figure(
                      label: 'Gross amount',
                      value: AppFormat.peso(
                        batch.grossAmountCentavos,
                        whole: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.xs,
                  horizontal: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: (isProfit ? sc.success : sc.danger).withValues(
                    alpha: 0.10,
                  ),
                  borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                ),
                child: Text(
                  'Net: ${AppFormat.pesoSigned(batch.netCentavos)}',
                  style: AppTextStyles.numericBody.copyWith(
                    color: isProfit ? sc.success : sc.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Linked commitment: ${batch.commitmentRef}',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
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
        Text(
          label,
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        Text(
          value,
          style: AppTextStyles.numericSmall.copyWith(
            color: color ?? AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}
