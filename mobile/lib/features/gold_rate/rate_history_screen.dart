import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/rate_change.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/status_badges.dart';
import 'gold_rate_reference_screen.dart';
import 'rate_change_tile.dart';

/// Every price one karat or silver fineness has been set at, newest first,
/// with who set it and by how much it moved.
class RateHistoryScreen extends StatelessWidget {
  final int karat;

  const RateHistoryScreen({super.key, required this.karat});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final editable = context.watch<AppState>().role.canManageCommitmentsAndRates;
    final rate = repo.rateForKarat(karat);
    final history = repo.rateHistory(karat);
    final palette = PurityPalette.of(context, karat);

    if (rate == null) {
      return const Scaffold(body: Center(child: Text('Rate not found')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${AppFormat.karat(karat)} History'),
        actions: [
          if (editable)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit rate',
              onPressed: () => editRate(context, rate),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
              border: Border.all(color: palette.edge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rateName(karat).toUpperCase(),
                  style: AppTextStyles.labelSmall.copyWith(color: palette.text),
                ),
                const SizedBox(height: 2),
                Text(
                  '${AppFormat.peso(rate.pricePerGramCentavos)} / g',
                  style: AppTextStyles.numericLarge.copyWith(color: palette.text, fontSize: 26),
                ),
                Text(
                  'Current price · since ${AppFormat.dateTimeShort(rate.updatedAt)}',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
                if (history.length > 1) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _RangeLine(history: history),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Price Changes (${history.length})', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          if (history.isEmpty)
            const EmptyState(
              icon: Icons.history_rounded,
              title: 'No history yet',
              message: 'Every time this price is set, it is recorded here.',
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
                  for (var i = 0; i < history.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    RateChangeTile(change: history[i]),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Lowest and highest the price has been, across the history shown.
class _RangeLine extends StatelessWidget {
  final List<RateChange> history;

  const _RangeLine({required this.history});

  @override
  Widget build(BuildContext context) {
    final prices = history.map((c) => c.afterCentavos);
    final low = prices.reduce((a, b) => a < b ? a : b);
    final high = prices.reduce((a, b) => a > b ? a : b);
    return Text(
      'Range: ${AppFormat.peso(low)} – ${AppFormat.peso(high)}',
      style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
    );
  }
}
