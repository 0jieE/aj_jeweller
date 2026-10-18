import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/state/app_state.dart';
import '../../core/models/branch.dart';
import '../../core/models/commitment.dart';
import '../../core/models/item_status.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/partial_progress_bar.dart';
import '../commitment/commitment_detail_screen.dart';

/// The final review: tag the batch to the commitment it settles, watch that
/// loan's balance update live from the entered gross before committing, and
/// confirm. Batch net (shop profit) and the gross applied toward the loan
/// stay visible side by side — two numbers, never one derived from the other.
///
/// A commitment is required. Scrap only ever leaves this shop to pay down a
/// loan, so a batch with nowhere to apply its gross is not a disposal anyone
/// could account for.
class DisposalTagCommitmentScreen extends StatefulWidget {
  final List<String> itemIds;
  final BranchId branch;
  final DateTime date;
  final int capitalCentavos;
  final double grossGrams;
  final int grossAmountCentavos;

  const DisposalTagCommitmentScreen({
    super.key,
    required this.itemIds,
    required this.branch,
    required this.date,
    required this.capitalCentavos,
    required this.grossGrams,
    required this.grossAmountCentavos,
  });

  @override
  State<DisposalTagCommitmentScreen> createState() => _DisposalTagCommitmentScreenState();
}

class _DisposalTagCommitmentScreenState extends State<DisposalTagCommitmentScreen> {
  Uint8List? _photo;
  String? _selectedCommitmentId;

  int get _netCentavos => widget.grossAmountCentavos - widget.capitalCentavos;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final sc = context.semanticColors;

    // Only loans that have actually received cash can be repaid — a still
    // -pending commitment hasn't handed over money yet, so there's nothing
    // for disposal gross to pay down, and an already-paid one needs
    // nothing more applied.
    final candidates = repo
        .commitmentLedgers(branchId: widget.branch)
        .where((l) => l.status == CommitmentStatus.loanReceived)
        .toList()
      ..sort((a, b) => b.remainingBalanceCentavos.compareTo(a.remainingBalanceCentavos));

    CommitmentLedger? selectedLedger;
    if (_selectedCommitmentId != null) {
      for (final l in candidates) {
        if (l.commitment.id == _selectedCommitmentId) {
          selectedLedger = l;
          break;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Tag to Commitment')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              Expanded(
                child: _FigureCard(
                  label: 'Batch Net (shop profit)',
                  value: AppFormat.pesoSigned(_netCentavos),
                  color: _netCentavos >= 0 ? sc.success : sc.danger,
                  icon: Icons.trending_up_rounded,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _FigureCard(
                  label: 'Loan Repayment (gross)',
                  value: AppFormat.peso(widget.grossAmountCentavos),
                  color: sc.danger,
                  icon: Icons.handshake_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Apply to a Commitment', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Scrap leaves the shop to settle a loan, so every batch applies to one.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (candidates.isEmpty)
            const EmptyState(
              icon: Icons.handshake_outlined,
              title: 'No commitment to settle',
              message: 'This branch has no received loan with a balance left to pay, '
                  'so there is nothing for this scrap to be applied against.',
            ),
          for (final ledger in candidates) ...[
            _CommitmentOption(
              ledger: ledger,
              selected: _selectedCommitmentId == ledger.commitment.id,
              grossAmountCentavos: widget.grossAmountCentavos,
              grossGrams: widget.grossGrams,
              onTap: () => setState(() => _selectedCommitmentId = ledger.commitment.id),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.md),
          ItemPhotoField(
            photo: _photo,
            label: 'Disposal photo',
            caption: 'The scrap on the refiner\'s scale or the settlement slip — kept with this batch.',
            onChanged: (bytes) => setState(() => _photo = bytes),
          ),
          const SizedBox(height: AppSpacing.md),
          ElevatedButton(
            onPressed: selectedLedger == null
                ? null
                : () => _confirm(context, repo, selectedLedger!),
            child: const Text('Confirm & Complete Disposal'),
          ),
          if (selectedLedger == null && candidates.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Pick the commitment this batch settles to continue.',
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirm(BuildContext context, AppRepository repo, CommitmentLedger selectedLedger) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDisposalDialog(
        itemCount: widget.itemIds.length,
        grossGrams: widget.grossGrams,
        grossAmountCentavos: widget.grossAmountCentavos,
        netCentavos: _netCentavos,
        lenderName: selectedLedger.commitment.lender,
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final commitmentId = selectedLedger.commitment.id;
    repo.completeDisposal(
      actor: context.read<AppState>().currentUser,
      branch: widget.branch,
      itemIds: widget.itemIds,
      capitalCentavos: widget.capitalCentavos,
      grossGrams: widget.grossGrams,
      grossAmountCentavos: widget.grossAmountCentavos,
      date: widget.date,
      commitmentRef: commitmentId,
      photo: _photo,
    );
    navigator.popUntil((route) => route.isFirst);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Disposal batch recorded — ${widget.itemIds.length} item(s) marked disposed.'),
        action: SnackBarAction(
          label: 'View Loan',
          onPressed: () => navigator.push(
            MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitmentId: commitmentId)),
          ),
        ),
      ),
    );
  }
}

class _FigureCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _FigureCard({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: AppSpacing.xs),
          Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          Text(value, style: AppTextStyles.numericLarge.copyWith(color: color, fontSize: 20)),
        ],
      ),
    );
  }
}

class _CommitmentOption extends StatelessWidget {
  final CommitmentLedger ledger;
  final bool selected;
  final int grossAmountCentavos;
  final double grossGrams;
  final VoidCallback onTap;

  const _CommitmentOption({
    required this.ledger,
    required this.selected,
    required this.grossAmountCentavos,
    required this.grossGrams,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = ledger.commitment;
    final sc = context.semanticColors;
    final newRepaid = ledger.repaidAmountCentavos + grossAmountCentavos;
    final newRemaining = (c.amountCentavos - newRepaid) < 0 ? 0 : c.amountCentavos - newRepaid;
    final willBePaidOff = newRemaining <= 0;

    final expectedGrossCentavos = (c.ratePerGramCentavos * grossGrams).round();
    final variance = expectedGrossCentavos == 0
        ? 0.0
        : ((grossAmountCentavos - expectedGrossCentavos) / expectedGrossCentavos) * 100;
    final highVariance = variance.abs() > 15;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryBlue.withValues(alpha: 0.06) : AppColors.cardSurface,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          border: Border.all(color: selected ? AppColors.primaryBlue : AppColors.outline, width: selected ? 1.4 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? AppColors.primaryBlue : AppColors.textDisabled,
                  size: 20,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.lender, style: AppTextStyles.titleMedium),
                      Text(
                        '${c.branch?.label ?? 'Company-wide'} · ${AppFormat.peso(c.ratePerGramCentavos)}/g',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (selected) ...[
              const SizedBox(height: AppSpacing.sm),
              PartialProgressBar(
                amountSoFarCentavos: newRepaid > c.amountCentavos ? c.amountCentavos : newRepaid,
                targetAmountCentavos: c.amountCentavos,
                label: 'Balance after this batch',
                color: sc.danger,
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _BalanceStat(label: 'Before', value: AppFormat.peso(ledger.remainingBalanceCentavos, whole: true)),
                  const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.textSecondary),
                  _BalanceStat(
                    label: willBePaidOff ? 'After (Paid)' : 'After',
                    value: AppFormat.peso(newRemaining, whole: true),
                    color: willBePaidOff ? sc.success : sc.danger,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                ),
                child: Row(
                  children: [
                    Icon(
                      highVariance ? Icons.info_rounded : Icons.info_outline_rounded,
                      size: 13,
                      color: highVariance ? sc.warning : AppColors.textDisabled,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Rate-implied reference: ${AppFormat.peso(expectedGrossCentavos)} '
                        '(entered is ${variance >= 0 ? '+' : ''}${variance.toStringAsFixed(0)}% vs. reference)',
                        style: AppTextStyles.caption.copyWith(
                          color: highVariance ? sc.warning : AppColors.textDisabled,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BalanceStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _BalanceStat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        Text(value, style: AppTextStyles.numericMedium.copyWith(color: color ?? AppColors.textPrimary)),
      ],
    );
  }
}

class _ConfirmDisposalDialog extends StatelessWidget {
  final int itemCount;
  final double grossGrams;
  final int grossAmountCentavos;
  final int netCentavos;
  final String lenderName;

  const _ConfirmDisposalDialog({
    required this.itemCount,
    required this.grossGrams,
    required this.grossAmountCentavos,
    required this.netCentavos,
    required this.lenderName,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.cardRadius)),
      icon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(color: sc.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
        child: Icon(Icons.delete_sweep_rounded, color: sc.goldDark),
      ),
      title: const Text('Complete this disposal?', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$itemCount item(s) · ${AppFormat.grams(grossGrams)} · ${AppFormat.peso(grossAmountCentavos)}',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'This marks every selected item disposed and cannot be undone. '
            'The gross amount applies toward the $lenderName loan.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
