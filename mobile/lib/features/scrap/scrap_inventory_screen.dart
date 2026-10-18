import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/inventory_item_tile.dart';
import '../../core/widgets/search_field.dart';
import '../purchase/lot_detail_screen.dart';

/// Every scrap record for the current branch view — bulk lots and the
/// partitions drawn out of them, still waiting or already disposed.
///
/// The headline figure stays deliberately narrower than the list: it counts
/// only what is actually still waiting on a disposal run, which is the
/// number an Admin glances at to know how much is piling up. The list below
/// is the full history, so a disposed lot can still be found and opened.
class ScrapInventoryScreen extends StatefulWidget {
  /// Silver stock instead of gold scrap.
  final bool silver;

  const ScrapInventoryScreen({super.key, this.silver = false});

  @override
  State<ScrapInventoryScreen> createState() => _ScrapInventoryScreenState();
}

class _ScrapInventoryScreenState extends State<ScrapInventoryScreen> {
  String _query = '';
  DateTimeRange? _dateRange;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final branchId = appState.selectedBranch;

    // Only the live disposal pool feeds the header total.
    final silver = widget.silver;
    final pending = repo.itemsForDisposal(branchId: branchId, silver: silver);
    final totalGrams = pending.fold<double>(0, (sum, i) => sum + i.effectiveRemainingGrams);
    final totalCapital = pending.fold<int>(0, (sum, i) => sum + i.effectiveRemainingAmountCentavos);

    var scrap = silver ? repo.allSilver(branchId: branchId) : repo.allScrap(branchId: branchId);
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      scrap = scrap
          .where((i) =>
              i.description.toLowerCase().contains(q) ||
              i.origin.toLowerCase().contains(q) ||
              i.id.toLowerCase().contains(q))
          .toList();
    }
    if (_dateRange != null) {
      scrap = scrap.where((i) {
        final d = DateTime(i.purchaseDate.year, i.purchaseDate.month, i.purchaseDate.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }
    scrap.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: _RemainingScrapCard(
            totalGrams: totalGrams,
            totalCapital: totalCapital,
            count: pending.length,
            silver: silver,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, 0),
          child: SearchField(
            hintText: silver ? 'Search silver by description, origin, or id' : 'Search scrap by description, origin, or id',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            children: [
              DateRangeChip(
                range: _dateRange,
                onChanged: (v) => setState(() => _dateRange = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: scrap.isEmpty
              ? EmptyState(
                  icon: Icons.delete_sweep_outlined,
                  title: q.isEmpty && _dateRange == null
                      ? (silver ? 'No silver recorded yet' : 'No scrap recorded yet')
                      : (silver ? 'No silver matches these filters' : 'No scrap matches these filters'),
                  message: q.isEmpty && _dateRange == null
                      ? (silver
                          ? 'Verified silver purchases appear here, ready to sell or dispose.'
                          : 'Verified scrap purchases will accumulate here until a batch is run.')
                      : null,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  itemCount: scrap.length,
                  separatorBuilder: (_, _) => const SizedBox.shrink(),
                  itemBuilder: (context, i) {
                    final item = scrap[i];
                    return InventoryItemTile(
                      item: item,
                      showVerification: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: item.id)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RemainingScrapCard extends StatelessWidget {
  final double totalGrams;
  final int totalCapital;
  final int count;
  final bool silver;

  const _RemainingScrapCard({
    required this.totalGrams,
    required this.totalCapital,
    required this.count,
    required this.silver,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final ink = silver ? AppColors.silverDark : sc.goldDark;
    final surface = silver ? sc.silverSurface : sc.goldSurface;
    final edge = silver ? sc.silver : sc.goldLight;
    final accent = silver ? sc.silver : sc.gold;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: edge.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(Icons.scale_outlined, color: ink),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  silver ? 'SILVER ON HAND · $count PIECE(S)' : 'AWAITING DISPOSAL · $count RECORD(S)',
                  style: AppTextStyles.labelSmall.copyWith(color: ink),
                ),
                Text(AppFormat.grams(totalGrams), style: AppTextStyles.numericLarge.copyWith(color: ink)),
                Text(
                  '${AppFormat.peso(totalCapital, whole: true)} in tied-up capital',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
