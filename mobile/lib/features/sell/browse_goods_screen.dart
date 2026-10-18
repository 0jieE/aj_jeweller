import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/filter_menu_chip.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/inventory_item_tile.dart';
import 'add_to_order_screen.dart';
import 'returned_sales_list_screen.dart';

enum _SortBy { newest, weightAsc, weightDesc, priceAsc, priceDesc }

extension on _SortBy {
  String get label {
    switch (this) {
      case _SortBy.newest:
        return 'Newest';
      case _SortBy.weightAsc:
        return 'Weight ↑';
      case _SortBy.weightDesc:
        return 'Weight ↓';
      case _SortBy.priceAsc:
        return 'Capital ↑';
      case _SortBy.priceDesc:
        return 'Capital ↓';
    }
  }
}

/// Searchable, filterable browse of goods available to sell — scrap never
/// appears here, only verified `listed` goods. Tapping a row opens price
/// entry; adding to the order reserves the item so it drops out of this
/// list. Pieces that have already gone out are on the Sold tab.
class BrowseGoodsScreen extends StatefulWidget {
  /// Silver stock instead of gold goods.
  final bool silver;

  const BrowseGoodsScreen({super.key, this.silver = false});

  @override
  State<BrowseGoodsScreen> createState() => _BrowseGoodsScreenState();
}

class _BrowseGoodsScreenState extends State<BrowseGoodsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  int? _karatFilter;
  DateTimeRange? _dateRange;
  _SortBy _sort = _SortBy.newest;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final role = appState.role;

    final returned = role.canMakeSales
        ? repo.salesReturnedForCorrectionFor(role, branchId: appState.selectedBranch)
        : const [];

    var goods = repo.sellableGoods(branchId: appState.selectedBranch, silver: widget.silver);
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      goods = goods.where((i) => i.description.toLowerCase().contains(q) || i.origin.toLowerCase().contains(q)).toList();
    }
    if (_karatFilter != null) {
      goods = goods.where((i) => i.karat == _karatFilter).toList();
    }
    if (_dateRange != null) {
      goods = goods.where((i) {
        final d = DateTime(i.purchaseDate.year, i.purchaseDate.month, i.purchaseDate.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }
    switch (_sort) {
      case _SortBy.newest:
        goods.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
      case _SortBy.weightAsc:
        goods.sort((a, b) => a.weightGrams.compareTo(b.weightGrams));
      case _SortBy.weightDesc:
        goods.sort((a, b) => b.weightGrams.compareTo(a.weightGrams));
      case _SortBy.priceAsc:
        goods.sort((a, b) => a.capitalAmountCentavos.compareTo(b.capitalAmountCentavos));
      case _SortBy.priceDesc:
        goods.sort((a, b) => b.capitalAmountCentavos.compareTo(a.capitalAmountCentavos));
    }

    final availableKarats = repo.sellableGoods(branchId: appState.selectedBranch, silver: widget.silver).map((i) => i.karat).toSet().toList()
      ..sort((a, b) => b.compareTo(a));

    return Column(
      children: [
        if (returned.isNotEmpty)
          _ReturnedBanner(
            count: returned.length,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReturnedSalesListScreen()),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: 'Search description or customer origin',
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            children: [
              FilterMenuChip<int>(
                label: _karatFilter != null ? AppFormat.karat(_karatFilter!) : (widget.silver ? 'Purity' : 'Karat'),
                active: _karatFilter != null,
                allLabel: 'All karats',
                values: availableKarats,
                labelOf: AppFormat.karat,
                onChanged: (v) => setState(() => _karatFilter = v),
              ),
              const SizedBox(width: AppSpacing.sm),
              DateRangeChip(
                range: _dateRange,
                onChanged: (v) => setState(() => _dateRange = v),
              ),
              const SizedBox(width: AppSpacing.sm),
              _ChipMenu<_SortBy>(
                label: _sort.label,
                active: _sort != _SortBy.newest,
                items: [for (final s in _SortBy.values) PopupMenuItem(value: s, child: Text(s.label))],
                onSelected: (v) => setState(() => _sort = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: goods.isEmpty
              ? EmptyState(
                  icon: Icons.storefront_outlined,
                  title: widget.silver ? 'No silver available to sell' : 'No sellable goods match',
                  message: 'Try clearing filters, or check the Purchase tab for inventory awaiting verification.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  itemCount: goods.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = goods[i];
                    return InventoryItemTile(
                      item: item,
                      onTap: role.canMakeSales
                          ? () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => AddToOrderScreen(itemId: item.id)),
                              )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ReturnedBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _ReturnedBanner({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: sc.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          border: Border.all(color: sc.danger.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.flag_rounded, color: sc.danger, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '$count order(s) returned for correction — tap to review',
                style: AppTextStyles.bodyMedium.copyWith(color: sc.danger, fontWeight: FontWeight.w700),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: sc.danger),
          ],
        ),
      ),
    );
  }
}

class _ChipMenu<T> extends StatelessWidget {
  final String label;
  final bool active;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  const _ChipMenu({required this.label, required this.active, required this.items, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      itemBuilder: (_) => items,
      onSelected: onSelected,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryBlue.withValues(alpha: 0.10) : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
          border: active ? Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.4)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppTextStyles.labelSmall.copyWith(color: active ? AppColors.primaryBlue : AppColors.textSecondary),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 16, color: active ? AppColors.primaryBlue : AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
