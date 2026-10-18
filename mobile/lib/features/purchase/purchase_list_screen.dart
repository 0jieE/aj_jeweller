import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item.dart';
import '../../core/models/item_status.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/filter_menu_chip.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/inventory_item_tile.dart';
import '../../core/widgets/search_field.dart';
import 'lot_detail_screen.dart';

/// Every encoded purchase for the current branch view, most recent first,
/// with type / verification / date-range filters. Browsable by any role —
/// creating and verifying purchases is what's role-gated, not looking.
class PurchaseListScreen extends StatefulWidget {
  const PurchaseListScreen({super.key});

  @override
  State<PurchaseListScreen> createState() => _PurchaseListScreenState();
}

class _PurchaseListScreenState extends State<PurchaseListScreen> {
  ItemType? _typeFilter;
  PurchaseStatusFilter? _statusFilter;
  DateTimeRange? _dateRange;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final role = appState.role;

    final returned = role.canEncodePurchases
        ? repo.returnedForCorrectionFor(role, branchId: appState.selectedBranch)
        : const <Item>[];

    var items = repo.itemsForBranch(appState.selectedBranch);
    if (_typeFilter != null) {
      items = items.where((i) => i.type == _typeFilter).toList();
    }
    if (_statusFilter != null) {
      items = items.where(_statusFilter!.matches).toList();
    }
    if (_dateRange != null) {
      items = items.where((i) {
        final d = DateTime(i.purchaseDate.year, i.purchaseDate.month, i.purchaseDate.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((i) {
        // The customer lives on the purchase batch; the item's origin covers
        // older records and bulk lots with no batch.
        final customer = i.batchId == null ? null : repo.findBatch(i.batchId!)?.customer;
        return [
          i.id,
          i.batchId,
          i.description,
          i.origin,
          customer?.name,
          customer?.contactNumber,
          AppFormat.karat(i.karat),
          i.type.label,
        ].any((field) => field != null && field.toLowerCase().contains(q));
      }).toList();
    }
    items.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));

    return Column(
      children: [
        if (returned.isNotEmpty)
          _ReturnedBanner(
            count: returned.length,
            onTap: () => setState(() {
              _statusFilter = PurchaseStatusFilter.returnedForCorrection;
              _typeFilter = null;
              _dateRange = null;
            }),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: SearchField(
            hintText: 'Search by item, id, customer, or karat',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        _FilterBar(
          typeFilter: _typeFilter,
          statusFilter: _statusFilter,
          dateRange: _dateRange,
          onTypeChanged: (v) => setState(() => _typeFilter = v),
          onStatusChanged: (v) => setState(() => _statusFilter = v),
          onDateRangeChanged: (v) => setState(() => _dateRange = v),
        ),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'No purchases match this search or filters',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox.shrink(),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return InventoryItemTile(
                      item: item,
                      showVerification: true,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: item.id)),
                        );
                      },
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
                '$count item(s) returned for correction — tap to review',
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

class _FilterBar extends StatelessWidget {
  final ItemType? typeFilter;
  final PurchaseStatusFilter? statusFilter;
  final DateTimeRange? dateRange;
  final ValueChanged<ItemType?> onTypeChanged;
  final ValueChanged<PurchaseStatusFilter?> onStatusChanged;
  final ValueChanged<DateTimeRange?> onDateRangeChanged;

  const _FilterBar({
    required this.typeFilter,
    required this.statusFilter,
    required this.dateRange,
    required this.onTypeChanged,
    required this.onStatusChanged,
    required this.onDateRangeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        children: [
          // Resting label is the "All …" option itself, not the dimension
          // name — a chip reading "Verification" looked like an active filter
          // when nothing was actually narrowed.
          FilterMenuChip<ItemType>(
            label: typeFilter?.label ?? 'All types',
            active: typeFilter != null,
            allLabel: 'All types',
            values: ItemType.values,
            labelOf: (t) => t.label,
            onChanged: onTypeChanged,
          ),
          const SizedBox(width: AppSpacing.sm),
          FilterMenuChip<PurchaseStatusFilter>(
            label: statusFilter?.label ?? 'All statuses',
            active: statusFilter != null,
            allLabel: 'All statuses',
            values: PurchaseStatusFilter.values,
            labelOf: (v) => v.label,
            onChanged: onStatusChanged,
          ),
          const SizedBox(width: AppSpacing.sm),
          DateRangeChip(range: dateRange, onChanged: onDateRangeChanged),
        ],
      ),
    );
  }
}

/// What the Purchase list's status chip can narrow by.
///
/// Deliberately not [VerificationStatus] itself: "Partitioned" is a
/// structural fact about a lot rather than a verification outcome, but staff
/// reach for both while asking the same question — "what state is this record
/// in?" — so they share one chip instead of adding a fourth.
enum PurchaseStatusFilter {
  awaitingVerification,
  verified,
  returnedForCorrection,
  partitioned;

  String get label {
    switch (this) {
      case PurchaseStatusFilter.awaitingVerification:
        return VerificationStatus.awaitingVerification.label;
      case PurchaseStatusFilter.verified:
        return VerificationStatus.verified.label;
      case PurchaseStatusFilter.returnedForCorrection:
        return VerificationStatus.returnedForCorrection.label;
      case PurchaseStatusFilter.partitioned:
        return 'Partitioned';
    }
  }

  bool matches(Item item) {
    switch (this) {
      case PurchaseStatusFilter.awaitingVerification:
        return item.verificationStatus == VerificationStatus.awaitingVerification;
      case PurchaseStatusFilter.verified:
        return item.verificationStatus == VerificationStatus.verified;
      case PurchaseStatusFilter.returnedForCorrection:
        return item.verificationStatus == VerificationStatus.returnedForCorrection;
      case PurchaseStatusFilter.partitioned:
        // Both sides of a split: the lot that was drawn from and the pieces
        // drawn out of it.
        return item.hasPartitions || item.isPartitioned;
    }
  }
}
