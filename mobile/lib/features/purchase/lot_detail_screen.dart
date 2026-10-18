import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item.dart';
import '../../core/models/item_status.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/inventory_item_tile.dart';
import '../../core/widgets/record_activity.dart';
import '../../core/widgets/status_badges.dart';
import '../../core/widgets/value_display.dart';
import 'create_partition_sheet.dart';
import 'edit_item_screen.dart';
import 'purchase_form_screen.dart';
import '../../core/navigation/layout.dart';

/// A single item's full record: its own weight/amount, its place in a
/// partitioned lot (original vs. remaining, always shown together), and
/// links both up to its parent lot and down to its own partitions.
///
/// Takes an [itemId] rather than an [Item] so it always reads the latest
/// state from the repository after a partition or verification changes it.
class LotDetailScreen extends StatelessWidget {
  final String itemId;

  const LotDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final appState = context.watch<AppState>();
    final item = repo.findItem(itemId);

    if (item == null) {
      return const Scaffold(body: Center(child: Text('Item not found')));
    }

    final parent = item.parentLotId != null ? repo.findItem(item.parentLotId!) : null;
    final partitions = repo.partitionsOf(item.id);
    final canEdit = appState.role.canEncodePurchases && item.submittedByRole == appState.role;
    final canPartition = appState.role.canEncodePurchases &&
        item.verificationStatus == VerificationStatus.verified &&
        !item.isExhausted;
    final canDeletePartitions = appState.role.canDeletePartitions;
    final canCorrect = appState.role.canCorrectRecords && repo.canEditItem(item);
    final batch = item.batchId == null ? null : repo.findBatch(item.batchId!);
    // The piece's own story, the purchase it came in on (release and returns
    // are recorded against the batch), and every piece drawn out of it — a
    // lot's history includes how it was split.
    final activity = [
      ...repo.logsForRecord(item.id),
      if (!item.isPartitioned && item.batchId != null) ...repo.logsForRecord(item.batchId!),
      for (final piece in partitions) ...repo.logsForRecord(piece.id),
    ]..sort((a, b) => a.at.compareTo(b.at));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lot Detail'),
        actions: [
          if (canCorrect)
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              tooltip: 'Correct this record',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => EditItemScreen(itemId: item.id)),
              ),
            ),
        ],
      ),
      body: DetailPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (item.verificationStatus == VerificationStatus.returnedForCorrection)
              _ReturnedCard(item: item, canEdit: canEdit),
            if (parent != null) _ParentLinkCard(parent: parent),
            _HeaderCard(item: item),
            const SizedBox(height: AppSpacing.sm),
            AccountabilityCard(
              children: [
                AttributionRow(
                  icon: Icons.edit_note_rounded,
                  label: item.isPartitioned ? 'Drawn by' : 'Encoded by',
                  userId: item.encodedByUserId,
                  at: item.purchaseDate,
                ),
                if (!item.isPartitioned)
                  AttributionRow(
                    icon: Icons.payments_outlined,
                    label: 'Cash released by',
                    userId: batch?.releasedByUserId,
                    at: batch?.releasedAt,
                    pendingText: 'Not yet released',
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (item.isExhausted)
              const _ExhaustedBanner()
            else
              Row(
                children: [
                  Expanded(
                    child: ValueDisplay(
                      label: 'Original Grams',
                      value: AppFormat.grams(item.effectiveOriginalGrams),
                      origin: FigureOrigin.entered,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: ValueDisplay(
                      label: 'Original Amount',
                      value: AppFormat.peso(item.effectiveOriginalAmountCentavos, whole: true),
                      origin: FigureOrigin.entered,
                      valueColor: context.semanticColors.gold,
                    ),
                  ),
                ],
              ),
            if (!item.isExhausted) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: ValueDisplay(
                      label: 'Remaining Grams',
                      value: AppFormat.grams(item.effectiveRemainingGrams),
                      origin: FigureOrigin.derived,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: ValueDisplay(
                      label: 'Remaining Amount',
                      value: AppFormat.peso(item.effectiveRemainingAmountCentavos, whole: true),
                      origin: FigureOrigin.derived,
                      valueColor: context.semanticColors.gold,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            if (canPartition)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => CreatePartitionSheet(parentId: item.id),
                  ),
                  icon: const Icon(Icons.call_split_rounded),
                  label: const Text('Create Partition'),
                ),
              )
            else if (item.verificationStatus != VerificationStatus.verified && !item.isExhausted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  'Partitioning is available once this purchase is verified and cash is released.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            Text('Partitions (${partitions.length})', style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            if (partitions.isEmpty)
              const EmptyState(
                icon: Icons.call_split_rounded,
                title: 'No partitions yet',
                message: 'This lot has not been split into smaller items.',
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
                    for (final p in partitions)
                      Row(
                        children: [
                          Expanded(
                            child: InventoryItemTile(
                              item: p,
                              showVerification: true,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: p.id)),
                              ),
                            ),
                          ),
                          // Disabled rather than hidden once the piece has moved
                          // on, so an Admin can see the action exists and why it
                          // no longer applies.
                          if (canDeletePartitions)
                            IconButton(
                              icon: const Icon(Icons.undo_rounded),
                              color: AppColors.danger,
                              tooltip: p.canReturnToParent
                                  ? 'Return this partition to the lot'
                                  : 'A ${p.itemStatus.label.toLowerCase()} partition can no longer be returned',
                              onPressed: p.canReturnToParent
                                  ? () => _confirmReturnPartition(context, repo, p, item)
                                  : null,
                            ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                      ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            Text('Activity', style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            RecordActivityList(entries: activity),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }

  /// Undoes a draw: the partition's grams and amount go back to the lot and
  /// the partition record is deleted. Spelled out in full first, since it
  /// removes a record rather than just changing a status.
  Future<void> _confirmReturnPartition(
    BuildContext context,
    AppRepository repo,
    Item partition,
    Item parent,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Return this partition to the lot?'),
        content: Text(
          '${AppFormat.grams(partition.weightGrams)} and '
          '${AppFormat.peso(partition.capitalAmountCentavos)} go back to '
          '"${parent.description}", and the partition record '
          '"${partition.description}" is deleted. No cash moves — this '
          'only changes how the lot is split.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Return to Lot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    repo.deletePartition(partition.id, actor: context.read<AppState>().currentUser);
    messenger.showSnackBar(
      SnackBar(content: Text('Partition returned to "${parent.description}".')),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final Item item;

  const _HeaderCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.description, style: AppTextStyles.headlineMedium.copyWith(fontSize: 19)),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ItemStatusBadge(status: item.itemStatus),
                VerificationStatusBadge(status: item.verificationStatus),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    // A partitioned lot's stored weight means different things
                    // depending on how it was split; what is still on hand is
                    // the figure that answers "how much is here?".
                    label: item.hasPartitions ? 'Weight left' : 'Weight',
                    value: AppFormat.grams(
                      item.hasPartitions ? item.effectiveRemainingGrams : item.weightGrams,
                    ),
                  ),
                ),
                Expanded(
                  child: _Stat(label: item.type.isSilver ? 'Purity' : 'Karat', value: AppFormat.karat(item.karat), color: PurityPalette.of(context, item.karat).text),
                ),
                Expanded(
                  child: _Stat(label: 'Type', value: item.type.label),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: item.hasPartitions ? 'Capital left' : 'Capital',
                    value: AppFormat.peso(
                      item.hasPartitions
                          ? item.effectiveRemainingAmountCentavos
                          : item.capitalAmountCentavos,
                      whole: true,
                    ),
                    color: sc.gold,
                  ),
                ),
                Expanded(child: _Stat(label: 'Purchase Date', value: AppFormat.dateShort(item.purchaseDate))),
                Expanded(child: _Stat(label: 'Branch', value: item.branch.label)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const Divider(),
            const SizedBox(height: AppSpacing.xs),
            Text('Origin', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
            Text(item.origin, style: AppTextStyles.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Stat({required this.label, required this.value, this.color});

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

class _ParentLinkCard extends StatelessWidget {
  final Item parent;

  const _ParentLinkCard({required this.parent});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: parent.id)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        ),
        child: Row(
          children: [
            const Icon(Icons.call_split_rounded, size: 16, color: AppColors.primaryBlue),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                  children: [
                    const TextSpan(text: 'Partitioned from: '),
                    TextSpan(
                      text: parent.description,
                      style: const TextStyle(color: AppColors.primaryBlue, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.primaryBlue),
          ],
        ),
      ),
    );
  }
}

class _ExhaustedBanner extends StatelessWidget {
  const _ExhaustedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: AppColors.outline, style: BorderStyle.solid),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, color: AppColors.textDisabled),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LOT EXHAUSTED',
                  style: AppTextStyles.labelSmall.copyWith(color: AppColors.textDisabled),
                ),
                Text(
                  'Every gram and peso of this lot has been drawn into partitions.',
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReturnedCard extends StatelessWidget {
  final Item item;
  final bool canEdit;

  const _ReturnedCard({required this.item, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
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
          if (item.verificationNote != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(item.verificationNote!, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textPrimary)),
          ],
          if (canEdit) ...[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: sc.danger),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => PurchaseFormScreen(editingItem: item)),
                ),
                child: const Text('Fix & Resubmit'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
