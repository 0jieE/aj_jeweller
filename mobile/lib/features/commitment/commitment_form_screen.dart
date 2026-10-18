import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/numeric_input_field.dart';

/// A new loan commitment. Always starts `loanPending` — there is no field
/// for cash-received here; that only happens as an explicit action on the
/// detail screen once the lender actually hands the money over.
class CommitmentFormScreen extends StatefulWidget {
  const CommitmentFormScreen({super.key});

  @override
  State<CommitmentFormScreen> createState() => _CommitmentFormScreenState();
}

class _CommitmentFormScreenState extends State<CommitmentFormScreen> {
  final _lenderController = TextEditingController();
  DateTime _dateApproved = DateTime.now();
  int? _amountCentavos;
  int? _rateCentavos;
  BranchId? _branch;
  bool _branchTouched = false;

  @override
  void dispose() {
    _lenderController.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _lenderController.text.trim().isNotEmpty &&
      _amountCentavos != null &&
      _amountCentavos! > 0 &&
      _rateCentavos != null &&
      _rateCentavos! > 0;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();

    if (!_branchTouched) {
      _branch = appState.selectedBranch;
    }

    final impliedGrams = (_amountCentavos != null && _rateCentavos != null && _rateCentavos! > 0)
        ? _amountCentavos! / _rateCentavos!
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('New Commitment')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: AppColors.info.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              border: Border.all(color: AppColors.info.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.hourglass_top_rounded, size: 18, color: AppColors.info),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'This starts as Loan Pending. Cash is not recorded as received until you '
                    'confirm it on the commitment detail screen.',
                    style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _lenderController,
            decoration: const InputDecoration(labelText: 'Lender'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          _DateField(date: _dateApproved, onChanged: (d) => setState(() => _dateApproved = d)),
          const SizedBox(height: AppSpacing.md),
          _BranchPicker(
            value: _branch,
            onChanged: (v) => setState(() {
              _branch = v;
              _branchTouched = true;
            }),
          ),
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: 'Loan Amount',
            kind: NumericInputKind.peso,
            onChanged: (v) => setState(() => _amountCentavos = v != null ? (v * 100).round() : null),
          ),
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: 'Rate (₱ per gram)',
            kind: NumericInputKind.peso,
            helperText: 'The lender\'s locked-in rate — reference only, never used to compute a disposal\'s gross.',
            onChanged: (v) => setState(() => _rateCentavos = v != null ? (v * 100).round() : null),
          ),
          if (impliedGrams != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: context.semanticColors.goldSurface,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.scale_outlined, size: 16, color: context.semanticColors.goldDark),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Implies roughly ${AppFormat.grams(impliedGrams)} of gold at this rate.',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: context.semanticColors.goldDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton(
            onPressed: _isValid ? () => _save(context, repo, appState) : null,
            child: const Text('Create Commitment'),
          ),
        ],
      ),
    );
  }

  void _save(BuildContext context, AppRepository repo, AppState appState) {
    repo.addCommitment(
      actor: context.read<AppState>().currentUser,
      lender: _lenderController.text.trim(),
      amountCentavos: _amountCentavos!,
      ratePerGramCentavos: _rateCentavos!,
      dateApproved: _dateApproved,
      branch: _branch,
    );
    Navigator.of(context).pop();
  }
}

class _DateField extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onChanged;

  const _DateField({required this.date, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(now.year - 1),
          lastDate: now,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Date Approved'),
        child: Row(
          children: [
            Expanded(child: Text(AppFormat.dateShort(date), style: AppTextStyles.bodyLarge)),
            const Icon(Icons.calendar_today_rounded, size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _BranchPicker extends StatelessWidget {
  final BranchId? value;
  final ValueChanged<BranchId?> onChanged;

  const _BranchPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<BranchId?>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Branch'),
      items: [
        for (final b in BranchId.values) DropdownMenuItem(value: b, child: Text(b.label)),
        const DropdownMenuItem(value: null, child: Text('Company-wide')),
      ],
      onChanged: onChanged,
    );
  }
}
