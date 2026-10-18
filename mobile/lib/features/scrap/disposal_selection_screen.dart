import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/item.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/filter_menu_chip.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/status_badges.dart';
import 'disposal_record_screen.dart';
import '../../core/navigation/layout.dart';

/// Bulk selection for a disposal batch. An admin may be assembling this
/// from months of records, so selection is held by item id (not list
/// index) and survives every filter change — narrow by date, select some,
/// widen the date range, select more, and nothing already checked is lost.
///
/// Branch is the one exception: a batch belongs to a single branch, so
/// switching it is a hard reset of the pool, not a soft filter — changing
/// it clears the current selection (with confirmation).
class DisposalSelectionScreen extends StatefulWidget {
  /// Dispose silver stock instead of gold scrap. A batch is one metal.
  final bool silver;

  const DisposalSelectionScreen({super.key, this.silver = false});

  @override
  State<DisposalSelectionScreen> createState() => _DisposalSelectionScreenState();
}

enum _SortBy { newest, gramsDesc, capitalDesc }

class _DisposalSelectionScreenState extends State<DisposalSelectionScreen> {
  final Set<String> _selectedIds = {};
  late BranchId _branch;
  DateTimeRange? _dateRange;
  int? _karatFilter;
  final _searchController = TextEditingController();
  String _query = '';
  _SortBy _sort = _SortBy.newest;
  bool _initialized = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();

    if (!_initialized) {
      _branch = appState.selectedBranch ?? BranchId.kidapawan;
      _initialized = true;
    }

    final branchPool = repo.itemsForDisposal(branchId: _branch, silver: widget.silver);
    final selectedItems = branchPool.where((i) => _selectedIds.contains(i.id)).toList();

    var filtered = branchPool;
    if (_dateRange != null) {
      filtered = filtered.where((i) {
        final d = DateTime(i.purchaseDate.year, i.purchaseDate.month, i.purchaseDate.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }
    if (_karatFilter != null) {
      filtered = filtered.where((i) => i.karat == _karatFilter).toList();
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      filtered = filtered
          .where((i) => i.origin.toLowerCase().contains(q) || i.description.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case _SortBy.newest:
        filtered.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
      case _SortBy.gramsDesc:
        filtered.sort((a, b) => b.effectiveRemainingGrams.compareTo(a.effectiveRemainingGrams));
      case _SortBy.capitalDesc:
        filtered.sort((a, b) => b.effectiveRemainingAmountCentavos.compareTo(a.effectiveRemainingAmountCentavos));
    }

    final availableKarats = branchPool.map((i) => i.karat).toSet().toList()..sort((a, b) => b.compareTo(a));
    final allFilteredSelected = filtered.isNotEmpty && filtered.every((i) => _selectedIds.contains(i.id));

    return Scaffold(
      appBar: AppBar(title: Text(widget.silver ? 'Dispose Silver' : 'Dispose Gold Scrap')),
      body: ReadableWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  hintText: 'Search origin or description',
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
                  if (appState.selectedBranch == null) ...[
                    _ChipMenu<BranchId>(
                      label: _branch.label,
                      active: true,
                      items: [for (final b in BranchId.values) PopupMenuItem(value: b, child: Text(b.label))],
                      onSelected: _changeBranch,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  _DateRangeChip(range: _dateRange, onChanged: (v) => setState(() => _dateRange = v)),
                  const SizedBox(width: AppSpacing.sm),
                  FilterMenuChip<int>(
                    label: _karatFilter != null ? AppFormat.karat(_karatFilter!) : (widget.silver ? 'Purity' : 'Karat'),
                    active: _karatFilter != null,
                    allLabel: widget.silver ? 'All purities' : 'All karats',
                    values: availableKarats,
                    labelOf: AppFormat.karat,
                    onChanged: (v) => setState(() => _karatFilter = v),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _ChipMenu<_SortBy>(
                    label: switch (_sort) {
                      _SortBy.newest => 'Newest',
                      _SortBy.gramsDesc => 'Grams ↓',
                      _SortBy.capitalDesc => 'Capital ↓',
                    },
                    active: _sort != _SortBy.newest,
                    items: const [
                      PopupMenuItem(value: _SortBy.newest, child: Text('Newest')),
                      PopupMenuItem(value: _SortBy.gramsDesc, child: Text('Grams ↓')),
                      PopupMenuItem(value: _SortBy.capitalDesc, child: Text('Capital ↓')),
                    ],
                    onSelected: (v) => setState(() => _sort = v),
                  ),
                ],
              ),
            ),
            // Select all is a real checkbox, not a text link: it is the fastest
            // way to dispose a whole month of scrap, and it shows at a glance
            // whether everything in view is already in the batch.
            Container(
              margin: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                border: Border.all(color: AppColors.outline),
              ),
              child: InkWell(
                onTap: filtered.isEmpty
                    ? null
                    : () => setState(() {
                          if (allFilteredSelected) {
                            _selectedIds.removeAll(filtered.map((i) => i.id));
                          } else {
                            _selectedIds.addAll(filtered.map((i) => i.id));
                          }
                        }),
                child: Row(
                  children: [
                    Checkbox(
                      tristate: true,
                      value: allFilteredSelected
                          ? true
                          : (filtered.any((i) => _selectedIds.contains(i.id)) ? null : false),
                      onChanged: filtered.isEmpty
                          ? null
                          : (_) => setState(() {
                                if (allFilteredSelected) {
                                  _selectedIds.removeAll(filtered.map((i) => i.id));
                                } else {
                                  _selectedIds.addAll(filtered.map((i) => i.id));
                                }
                              }),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Select all (${filtered.length})',
                            style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${_selectedIds.length} selected',
                            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    if (_selectedIds.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(_selectedIds.clear),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? EmptyState(
                      icon: Icons.filter_alt_off_outlined,
                      title: branchPool.isEmpty
                          ? (widget.silver ? 'No silver on hand to dispose' : 'No scrap waiting for disposal')
                          : 'Nothing matches these filters',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xxl),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final item = filtered[i];
                        final selected = _selectedIds.contains(item.id);
                        return _SelectableScrapTile(
                          item: item,
                          selected: selected,
                          onChanged: (v) => setState(() {
                            if (v) {
                              _selectedIds.add(item.id);
                            } else {
                              _selectedIds.remove(item.id);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _selectedIds.isEmpty
          ? null
          : _SelectionSummaryBar(
              items: selectedItems,
              onContinue: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DisposalRecordScreen(itemIds: _selectedIds.toList(), branch: _branch),
                ),
              ),
            ),
    );
  }

  void _changeBranch(BranchId branch) async {
    if (branch == _branch) return;
    if (_selectedIds.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Switch branch?'),
          content: Text(
            'A disposal batch belongs to one branch. Switching to ${branch.label} will clear '
            'your current selection (${_selectedIds.length} item(s)).',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Switch')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() {
      _branch = branch;
      _selectedIds.clear();
    });
  }
}

class _SelectableScrapTile extends StatelessWidget {
  final Item item;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _SelectableScrapTile({required this.item, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Checkbox(value: selected, onChanged: (v) => onChanged(v ?? false)),
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: PurityPalette.of(context, item.karat).surface, borderRadius: BorderRadius.circular(8)),
              child: Text(
                AppFormat.karat(item.karat),
                style: AppTextStyles.numericSmall.copyWith(color: PurityPalette.of(context, item.karat).text, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${item.origin} · ${AppFormat.dateShort(item.purchaseDate)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(AppFormat.grams(item.effectiveRemainingGrams), style: AppTextStyles.numericSmall.copyWith(color: PurityPalette.of(context, item.karat).text)),
                Text(
                  AppFormat.peso(item.effectiveRemainingAmountCentavos, whole: true),
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionSummaryBar extends StatelessWidget {
  final List<Item> items;
  final VoidCallback onContinue;

  const _SelectionSummaryBar({required this.items, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final grams = items.fold<double>(0, (s, i) => s + i.effectiveRemainingGrams);
    final capital = items.fold<int>(0, (s, i) => s + i.effectiveRemainingAmountCentavos);
    final sc = context.semanticColors;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.cardSurface,
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: _SummaryFigure(label: '${items.length} item(s)', value: AppFormat.grams(grams), color: sc.gold),
                ),
                Expanded(
                  child: _SummaryFigure(label: 'Capital', value: AppFormat.peso(capital, whole: true)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ElevatedButton(onPressed: onContinue, child: const Text('Continue')),
          ],
        ),
      ),
    );
  }
}

class _SummaryFigure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryFigure({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        Text(value, style: AppTextStyles.numericMedium.copyWith(color: color ?? AppColors.textPrimary)),
      ],
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
            Text(label, style: AppTextStyles.labelSmall.copyWith(color: active ? AppColors.primaryBlue : AppColors.textSecondary)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 16, color: active ? AppColors.primaryBlue : AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _DateRangeChip extends StatelessWidget {
  final DateTimeRange? range;
  final ValueChanged<DateTimeRange?> onChanged;

  const _DateRangeChip({required this.range, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = range == null ? 'Date range' : '${AppFormat.dateShort(range!.start)} – ${AppFormat.dateShort(range!.end)}';
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(now.year - 2),
          lastDate: now,
          initialDateRange: range,
        );
        if (picked != null) onChanged(picked);
      },
      onLongPress: range != null ? () => onChanged(null) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2, vertical: 6),
        decoration: BoxDecoration(
          color: range != null ? AppColors.primaryBlue.withValues(alpha: 0.10) : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
          border: range != null ? Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.4)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_today_rounded, size: 13, color: range != null ? AppColors.primaryBlue : AppColors.textSecondary),
            const SizedBox(width: 5),
            Text(label, style: AppTextStyles.labelSmall.copyWith(color: range != null ? AppColors.primaryBlue : AppColors.textSecondary)),
            if (range != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.close_rounded, size: 13, color: AppColors.primaryBlue),
            ],
          ],
        ),
      ),
    );
  }
}
