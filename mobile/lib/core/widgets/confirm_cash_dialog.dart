import 'package:flutter/material.dart';

import '../models/branch.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';

enum CashDirection { release, receive }

/// Confirmation dialog for any action that moves cash — releasing payment
/// on a purchase, receiving payment on a sale. Always spells out exactly
/// what is about to happen before the balance changes.
class ConfirmCashDialog extends StatelessWidget {
  final CashDirection direction;
  final int amountCentavos;

  /// Null for a company-wide movement not tied to one branch's balance.
  final BranchId? branch;
  final String counterparty;
  final String reason;

  /// Where the money lands or leaves from, one line per pool — e.g. a split
  /// sale's cash into Sales Cash and its transfer into Cash in Bank. When
  /// null, the dialog names the branch balance generically.
  final List<({String label, int amountCentavos})>? breakdown;

  const ConfirmCashDialog({
    super.key,
    required this.direction,
    required this.amountCentavos,
    required this.branch,
    required this.counterparty,
    required this.reason,
    this.breakdown,
  });

  static Future<bool> show(
    BuildContext context, {
    required CashDirection direction,
    required int amountCentavos,
    required BranchId? branch,
    required String counterparty,
    required String reason,
    List<({String label, int amountCentavos})>? breakdown,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmCashDialog(
        direction: direction,
        amountCentavos: amountCentavos,
        branch: branch,
        counterparty: counterparty,
        reason: reason,
        breakdown: breakdown,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isRelease = direction == CashDirection.release;
    final color = isRelease ? AppColors.danger : AppColors.success;
    final verb = isRelease ? 'Release' : 'Receive';

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      ),
      icon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isRelease ? Icons.north_east_rounded : Icons.south_west_rounded,
          color: color,
        ),
      ),
      title: Text(
        breakdown != null && !isRelease ? 'Receive payment?' : '$verb cash?',
        textAlign: TextAlign.center,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppFormat.peso(amountCentavos),
            textAlign: TextAlign.center,
            style: AppTextStyles.numericLarge.copyWith(color: color),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            breakdown != null
                ? '$verb ${AppFormat.peso(amountCentavos)} ${isRelease ? 'to' : 'from'} $counterparty for $reason.'
                : '$verb ${AppFormat.peso(amountCentavos)} ${isRelease ? 'to' : 'from'} '
                    '$counterparty for $reason, ${branch != null ? 'from the ${branch!.label} branch balance' : 'company-wide (not tied to a single branch balance)'}.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
          if (breakdown != null) ...[
            const SizedBox(height: AppSpacing.md),
            for (final line in breakdown!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(isRelease ? Icons.north_east_rounded : Icons.south_west_rounded, size: 16, color: color),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '${isRelease ? 'From' : 'Into'} ${line.label}',
                        style: AppTextStyles.bodyMedium,
                      ),
                    ),
                    Text(
                      AppFormat.peso(line.amountCentavos),
                      style: AppTextStyles.numericSmall.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: color),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Confirm $verb'),
        ),
      ],
    );
  }
}

/// Confirmation dialog for New Cash Entry — same visual language as
/// [ConfirmCashDialog] (icon circle, big signed amount, plain-English
/// description, Cancel/Confirm), extended to show the resulting branch
/// balance(s) before the entry is actually posted.
///
/// Takes [label]/[icon]/[color] directly rather than a [CashEntryType] —
/// the New Cash Entry screen picks from 4 user-facing kinds (Cash In,
/// Expense, Withdrawal, Transfer), while a transfer itself has no single
/// "credit or debit" direction of its own to derive those from.
class ConfirmCashEntryDialog extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final int amountCentavos;
  final String note;

  /// The branch debited (expense/withdrawal) or credited (cash-in), or the
  /// transfer's source.
  final BranchId branch;
  final int resultingBalanceCentavos;

  /// Names the exact pool debited or credited, e.g. "Davao Sales Cash".
  final String? sourceLabel;
  final String? destinationLabel;

  /// Set only for a transfer — the destination branch and its resulting
  /// balance.
  final BranchId? destinationBranch;
  final int? resultingDestinationBalanceCentavos;

  const ConfirmCashEntryDialog({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.amountCentavos,
    required this.note,
    required this.branch,
    required this.resultingBalanceCentavos,
    this.destinationBranch,
    this.resultingDestinationBalanceCentavos,
    this.sourceLabel,
    this.destinationLabel,
  });

  static Future<bool> show(
    BuildContext context, {
    required String label,
    required IconData icon,
    required Color color,
    required int amountCentavos,
    required String note,
    required BranchId branch,
    required int resultingBalanceCentavos,
    BranchId? destinationBranch,
    int? resultingDestinationBalanceCentavos,
    String? sourceLabel,
    String? destinationLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmCashEntryDialog(
        label: label,
        icon: icon,
        color: color,
        amountCentavos: amountCentavos,
        note: note,
        branch: branch,
        resultingBalanceCentavos: resultingBalanceCentavos,
        destinationBranch: destinationBranch,
        resultingDestinationBalanceCentavos: resultingDestinationBalanceCentavos,
        sourceLabel: sourceLabel,
        destinationLabel: destinationLabel,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isTransfer = destinationBranch != null;

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      ),
      icon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color),
      ),
      title: Text('Record $label?', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppFormat.peso(amountCentavos),
            textAlign: TextAlign.center,
            style: AppTextStyles.numericLarge.copyWith(color: color),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            note,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
          _ResultingBalanceRow(
            label: isTransfer ? '${sourceLabel ?? branch.label} (from)' : (sourceLabel ?? branch.label),
            balanceCentavos: resultingBalanceCentavos,
          ),
          if (isTransfer) ...[
            const SizedBox(height: AppSpacing.xs),
            _ResultingBalanceRow(
              label: '${destinationLabel ?? destinationBranch!.label} (to)',
              balanceCentavos: resultingDestinationBalanceCentavos!,
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: color),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

class _ResultingBalanceRow extends StatelessWidget {
  final String label;
  final int balanceCentavos;

  const _ResultingBalanceRow({required this.label, required this.balanceCentavos});

  @override
  Widget build(BuildContext context) {
    // Stacked, not side by side: "Kidapawan Purchase Cash (from)" plus a
    // seven-figure amount is wider than a phone dialog.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label balance after',
          textAlign: TextAlign.center,
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        Text(
          AppFormat.peso(balanceCentavos),
          style: AppTextStyles.numericSmall.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
