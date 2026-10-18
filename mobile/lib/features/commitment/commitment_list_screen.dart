import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/commitment.dart';
import '../../core/models/item_status.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/partial_progress_bar.dart';
import '../../core/widgets/status_badges.dart';
import 'commitment_detail_screen.dart';
import 'commitment_form_screen.dart';

/// Every commitment for the current branch view — a liability list, not an
/// asset one. The header total and each entry's remaining balance are
/// styled as money owed, never as stock on hand or profit.
class CommitmentListScreen extends StatefulWidget {
  const CommitmentListScreen({super.key});

  @override
  State<CommitmentListScreen> createState() => _CommitmentListScreenState();
}

class _CommitmentListScreenState extends State<CommitmentListScreen> {
  CommitmentStatus? _statusFilter;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final role = appState.role;

    final ledgers = repo.commitmentLedgers(branchId: appState.selectedBranch)
      ..sort((a, b) => b.commitment.dateApproved.compareTo(a.commitment.dateApproved));

    final totalOutstanding = ledgers.fold<int>(0, (sum, l) => sum + l.remainingBalanceCentavos);

    final filtered = _statusFilter == null ? ledgers : ledgers.where((l) => l.status == _statusFilter).toList();

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _TotalOutstandingCard(totalOutstanding: totalOutstanding, count: ledgers.length),
          const SizedBox(height: AppSpacing.md),
          _StatusFilterBar(
            selected: _statusFilter,
            onSelected: (v) => setState(() => _statusFilter = v),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: EmptyState(
                icon: Icons.handshake_outlined,
                title: 'No commitments match',
                message: 'Try a different status filter.',
              ),
            )
          else
            for (final ledger in filtered) ...[
              _CommitmentCard(
                ledger: ledger,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitmentId: ledger.commitment.id)),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
        ],
      ),
      floatingActionButton: role.canManageCommitmentsAndRates
          ? FloatingActionButton.extended(
              // Every tab stays mounted in the shell's IndexedStack, so
              // each FAB needs its own hero tag — otherwise Flutter finds
              // multiple heroes sharing the default tag the moment any
              // route transitions.
              heroTag: 'commitment-new-fab',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CommitmentFormScreen()),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New Commitment'),
            )
          : null,
    );
  }
}

class _TotalOutstandingCard extends StatelessWidget {
  final int totalOutstanding;
  final int count;

  const _TotalOutstandingCard({required this.totalOutstanding, required this.count});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: sc.danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: sc.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: sc.danger.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(Icons.account_balance_wallet_outlined, color: sc.danger),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOTAL OUTSTANDING · $count COMMITMENT(S)',
                  style: AppTextStyles.labelSmall.copyWith(color: sc.danger),
                ),
                Text(
                  AppFormat.peso(totalOutstanding),
                  style: AppTextStyles.numericLarge.copyWith(color: sc.danger),
                ),
                Text(
                  'Still owed to lenders — not stock, not profit',
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

class _StatusFilterBar extends StatelessWidget {
  final CommitmentStatus? selected;
  final ValueChanged<CommitmentStatus?> onSelected;

  const _StatusFilterBar({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _chip(context, null, 'All'),
          const SizedBox(width: AppSpacing.sm),
          for (final s in CommitmentStatus.values) ...[
            _chip(context, s, s.label),
            const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, CommitmentStatus? status, String label) {
    final active = selected == status;
    return GestureDetector(
      onTap: () => onSelected(status),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 4, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryBlue : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: active ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _CommitmentCard extends StatelessWidget {
  final CommitmentLedger ledger;
  final VoidCallback onTap;

  const _CommitmentCard({required this.ledger, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = ledger.commitment;
    final sc = context.semanticColors;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      child: Container(
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.lender, style: AppTextStyles.titleMedium),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          _BranchChip(branch: c.branch),
                          const SizedBox(width: 6),
                          Text(
                            '${AppFormat.peso(c.ratePerGramCentavos)}/g',
                            style: AppTextStyles.numericSmall.copyWith(color: sc.goldDark),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                CommitmentStatusTracker(status: ledger.status),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            PartialProgressBar(
              amountSoFarCentavos: ledger.repaidAmountCentavos,
              targetAmountCentavos: c.amountCentavos,
              label: 'Repaid via disposal gross',
            ),
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
              decoration: BoxDecoration(
                color: sc.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Remaining balance', style: AppTextStyles.caption.copyWith(color: sc.danger)),
                  Text(
                    AppFormat.peso(ledger.remainingBalanceCentavos),
                    style: AppTextStyles.numericMedium.copyWith(color: sc.danger, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchChip extends StatelessWidget {
  final BranchId? branch;

  const _BranchChip({required this.branch});

  @override
  Widget build(BuildContext context) {
    final label = branch == null ? 'Company-wide' : branch!.label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary, fontSize: 10.5),
      ),
    );
  }
}
