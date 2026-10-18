import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/commitment.dart';
import '../../core/models/disposal_batch.dart';
import '../../core/models/item_status.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/partial_progress_bar.dart';
import '../../core/widgets/status_badges.dart';
import '../disposal_history/disposal_batch_detail_screen.dart';

/// The full loan statement: header figures, repayment progress, and the
/// audit trail of every disposal batch applied against the balance.
class CommitmentDetailScreen extends StatelessWidget {
  final String commitmentId;

  const CommitmentDetailScreen({super.key, required this.commitmentId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final appState = context.watch<AppState>();
    final ledger = repo.ledgerFor(commitmentId);
    final c = ledger.commitment;
    final sc = context.semanticColors;
    final canManage = appState.role.canManageCommitmentsAndRates;

    return Scaffold(
      appBar: AppBar(title: Text(c.lender)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _HeaderCard(ledger: ledger),
          const SizedBox(height: AppSpacing.md),
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
                Text('Repayment Progress', style: AppTextStyles.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                PartialProgressBar(
                  amountSoFarCentavos: ledger.repaidAmountCentavos,
                  targetAmountCentavos: c.amountCentavos,
                  label: 'Paid via disposal gross',
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: sc.goldSurface,
                    borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.scale_outlined, size: 16, color: sc.goldDark),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          ledger.status == CommitmentStatus.loanPaid
                              ? 'Fully covered — no weight left outstanding.'
                              : '≈ ${AppFormat.grams(ledger.remainingGrams)} still stands between the shop and a cleared loan, at ${AppFormat.peso(c.ratePerGramCentavos)}/g.',
                          style: AppTextStyles.bodyMedium.copyWith(color: sc.goldDark, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (ledger.status == CommitmentStatus.loanPending && canManage) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: sc.success),
                icon: const Icon(Icons.payments_rounded),
                label: const Text('Record Cash Received'),
                onPressed: () => _receiveCash(context, repo, c),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text('Repayment History (${ledger.appliedBatches.length})', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          if (ledger.appliedBatches.isEmpty)
            EmptyState(
              icon: Icons.receipt_long_outlined,
              title: ledger.status == CommitmentStatus.loanPending ? 'Loan not yet received' : 'No repayments yet',
              message: ledger.status == CommitmentStatus.loanPending
                  ? 'Repayment history will appear here once cash is received and disposed scrap starts paying down the balance.'
                  : 'Disposal batches applied to this loan will show up here as they happen.',
            )
          else
            Column(
              children: [
                for (final batch in ledger.appliedBatches)
                  _RepaymentHistoryTile(
                    batch: batch,
                    karatBreakdown: repo.karatBreakdown(batch.id),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => DisposalBatchDetailScreen(batchId: batch.id)),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _receiveCash(BuildContext context, AppRepository repo, Commitment c) async {
    final proof = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _ReceiveCashDialog(commitment: c),
    );
    if (proof == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    repo.receiveCommitmentCash(
      c.id,
      recordedByRole: context.read<AppState>().role,
      proofPhoto: proof,
      actor: context.read<AppState>().currentUser,
    );
    messenger.showSnackBar(
      SnackBar(content: Text('Cash recorded as received from ${c.lender}.')),
    );
  }
}

/// Confirms loan cash as received, with a photo as proof. The photo is
/// required: the cash never passes through a sale or a purchase that could
/// vouch for it, so the picture is the only evidence it arrived.
class _ReceiveCashDialog extends StatefulWidget {
  final Commitment commitment;

  const _ReceiveCashDialog({required this.commitment});

  @override
  State<_ReceiveCashDialog> createState() => _ReceiveCashDialogState();
}

class _ReceiveCashDialogState extends State<_ReceiveCashDialog> {
  Uint8List? _photo;

  @override
  Widget build(BuildContext context) {
    final c = widget.commitment;
    final sc = context.semanticColors;
    return AlertDialog(
      title: const Text('Receive loan cash?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppFormat.peso(c.amountCentavos),
              textAlign: TextAlign.center,
              style: AppTextStyles.numericLarge.copyWith(color: sc.success),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'From ${c.lender}'
              '${c.branch == null ? ' · company-wide' : ' · into ${c.branch!.label} Purchase Cash'}',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ItemPhotoField(
              photo: _photo,
              label: 'Proof of cash received (required)',
              caption: 'The counted cash or the lender\'s slip — kept on the commitment as proof.',
              onChanged: (bytes) => setState(() => _photo = bytes),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _photo == null ? null : () => Navigator.of(context).pop(_photo),
          child: const Text('Receive Cash'),
        ),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final CommitmentLedger ledger;

  const _HeaderCard({required this.ledger});

  @override
  Widget build(BuildContext context) {
    final c = ledger.commitment;
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.branch == null ? 'Company-wide commitment' : '${c.branch!.label} commitment',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                    Text(c.lender, style: AppTextStyles.headlineMedium.copyWith(fontSize: 20)),
                  ],
                ),
              ),
              CommitmentStatusTracker(status: ledger.status),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(child: _Stat(label: 'Loan Amount', value: AppFormat.peso(c.amountCentavos, whole: true))),
              Expanded(
                child: _Stat(label: 'Rate', value: '${AppFormat.peso(c.ratePerGramCentavos)}/g', color: sc.goldDark),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: sc.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Remaining balance (owed)', style: AppTextStyles.bodyMedium.copyWith(color: sc.danger)),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      AppFormat.peso(ledger.remainingBalanceCentavos),
                      style: AppTextStyles.numericLarge.copyWith(color: sc.danger),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(child: _Stat(label: 'Date Approved', value: AppFormat.dateShort(c.dateApproved))),
              Expanded(
                child: _Stat(
                  label: 'Date Received',
                  value: c.dateReceived != null ? AppFormat.dateShort(c.dateReceived!) : 'Not yet received',
                ),
              ),
            ],
          ),
          if (c.receivedProofPhoto != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                ItemPhotoThumbnail(
                  photo: c.receivedProofPhoto!,
                  label: 'Cash received from ${c.lender}',
                  size: 64,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Proof of cash received — tap to enlarge.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ],
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

class _RepaymentHistoryTile extends StatelessWidget {
  final DisposalBatch batch;

  /// Grams per karat in this batch, highest karat first. The pieces behind
  /// these totals are listed on the disposal record itself, one tap away —
  /// this list stays scannable.
  final List<MapEntry<int, double>> karatBreakdown;
  final VoidCallback onTap;

  const _RepaymentHistoryTile({
    required this.batch,
    required this.karatBreakdown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(batch.id, style: AppTextStyles.titleMedium),
                Text(AppFormat.dateShort(batch.date), style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _Field(label: 'Gross Grams', value: AppFormat.grams(batch.grossGrams))),
                Expanded(
                  child: _Field(
                    label: 'Gross Amount (applied)',
                    value: AppFormat.peso(batch.grossAmountCentavos, whole: true),
                    color: sc.danger,
                  ),
                ),
                Expanded(child: _Field(label: 'Capital', value: AppFormat.peso(batch.capitalCentavos, whole: true))),
              ],
            ),
            if (karatBreakdown.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'DELIVERED',
                style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in karatBreakdown)
                    _KaratGramChip(karat: entry.key, grams: entry.value),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.textDisabled),
                const SizedBox(width: 2),
                Text(
                  'View disposal record',
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

/// One karat's share of a delivery — the karat tag and the grams that came
/// in at it, in the gold colours those figures use everywhere else.
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

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Field({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        Text(value, style: AppTextStyles.numericSmall.copyWith(color: color ?? AppColors.textPrimary)),
      ],
    );
  }
}
