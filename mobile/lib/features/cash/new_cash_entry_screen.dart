import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/cash_entry.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/confirm_cash_dialog.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/numeric_input_field.dart';

/// The four kinds a Cashier/Admin can record by hand. Distinct from
/// [CashEntryType] because a transfer has no single credit/debit direction
/// of its own — it always posts as a `transferOut` + `transferIn` pair via
/// [AppRepository.recordTransfer].
enum _EntryKind {
  cashIn,
  expense,
  withdrawal,
  transfer;

  String get label {
    switch (this) {
      case _EntryKind.cashIn:
        return 'Cash In';
      case _EntryKind.expense:
        return 'Expense';
      case _EntryKind.withdrawal:
        return 'Withdrawal';
      case _EntryKind.transfer:
        return 'Transfer';
    }
  }

  String get noteLabel {
    switch (this) {
      case _EntryKind.cashIn:
        return 'Source / origin (e.g. "Owner capital injection")';
      case _EntryKind.expense:
        return 'Description';
      case _EntryKind.withdrawal:
        return 'Destination (e.g. "Owner personal withdrawal")';
      case _EntryKind.transfer:
        return 'Reason for transfer';
    }
  }

  IconData get icon {
    switch (this) {
      case _EntryKind.cashIn:
        return Icons.south_west_rounded;
      case _EntryKind.expense:
        return Icons.receipt_long_rounded;
      case _EntryKind.withdrawal:
        return Icons.north_east_rounded;
      case _EntryKind.transfer:
        return Icons.swap_horiz_rounded;
    }
  }
}

const _expenseCategories = ['Rent', 'Utilities', 'Salaries', 'Supplies', 'Transport', 'Other'];

/// A manual cash-in / expense / withdrawal / transfer entry, shown as the
/// Cash Entry tab of the Cash screen. Entry type is picked first since every
/// field after it depends on the choice.
///
/// Every entry names which of the branch's three cash sources it moves —
/// purchase cash, sales cash, or cash in bank — and a transfer names one on
/// each side, so money can move between branches or between a branch's own
/// sources.
class CashEntryForm extends StatefulWidget {
  /// Called after an entry is recorded, so the host can show the history.
  final VoidCallback? onRecorded;

  const CashEntryForm({super.key, this.onRecorded});

  @override
  State<CashEntryForm> createState() => _CashEntryFormState();
}

class _CashEntryFormState extends State<CashEntryForm> {
  _EntryKind? _kind;
  BranchId? _branch;
  CashAccount _account = CashAccount.purchase;
  BranchId? _destinationBranch;
  CashAccount _destinationAccount = CashAccount.purchase;
  int? _amountCentavos;
  DateTime _date = DateTime.now();
  String? _category;
  late final TextEditingController _noteController;

  // Rebuilt after a successful entry so the amount field clears too.
  Key _formKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool get _sameSourceAndDestination =>
      _kind == _EntryKind.transfer &&
      _destinationBranch != null &&
      _destinationBranch == _branch &&
      _destinationAccount == _account;

  bool get _isValid {
    if (_kind == null || _branch == null) return false;
    if (_amountCentavos == null || _amountCentavos! <= 0) return false;
    if (_noteController.text.trim().isEmpty) return false;
    if (_kind == _EntryKind.expense && (_category == null || _category!.isEmpty)) return false;
    if (_kind == _EntryKind.transfer && (_destinationBranch == null || _sameSourceAndDestination)) {
      return false;
    }
    return true;
  }

  void _reset() {
    setState(() {
      _kind = null;
      _account = CashAccount.purchase;
      _destinationBranch = null;
      _destinationAccount = CashAccount.purchase;
      _amountCentavos = null;
      _date = DateTime.now();
      _category = null;
      _noteController.clear();
      _formKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    _branch ??= appState.selectedBranch;
    final isTransfer = _kind == _EntryKind.transfer;

    return ListView(
      key: _formKey,
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xl),
      children: [
        Text('Entry Type', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        _EntryKindGrid(
          value: _kind,
          onChanged: (k) => setState(() {
            _kind = k;
            _category = null;
            _destinationBranch = null;
          }),
        ),
        if (_kind != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _BranchPicker(
            label: isTransfer ? 'From branch' : 'Branch',
            value: _branch,
            onChanged: (v) => setState(() => _branch = v),
          ),
          const SizedBox(height: AppSpacing.sm),
          _AccountRadios(
            label: isTransfer ? 'From cash source' : 'Cash source',
            branch: _branch,
            value: _account,
            onChanged: (v) => setState(() => _account = v),
          ),
          if (isTransfer) ...[
            const SizedBox(height: AppSpacing.lg),
            _BranchPicker(
              label: 'To branch',
              value: _destinationBranch,
              onChanged: (v) => setState(() => _destinationBranch = v),
            ),
            const SizedBox(height: AppSpacing.sm),
            _AccountRadios(
              label: 'To cash source',
              branch: _destinationBranch,
              value: _destinationAccount,
              // The exact source being drawn from can't also be the target.
              disabled: _destinationBranch == _branch ? _account : null,
              onChanged: (v) => setState(() => _destinationAccount = v),
            ),
            if (_sameSourceAndDestination)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Pick a different branch or cash source to transfer to.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.danger),
                ),
              ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _DateField(date: _date, onChanged: (d) => setState(() => _date = d)),
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: 'Amount',
            kind: NumericInputKind.peso,
            initialValue: _amountCentavos != null ? _amountCentavos! / 100 : null,
            onChanged: (v) => setState(() => _amountCentavos = v != null ? (v * 100).round() : null),
          ),
          if (_kind == _EntryKind.expense) ...[
            const SizedBox(height: AppSpacing.md),
            _CategoryPicker(value: _category, onChanged: (v) => setState(() => _category = v)),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _noteController,
            maxLines: 2,
            decoration: InputDecoration(labelText: _kind!.noteLabel),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton(
            onPressed: _isValid ? () => _submit(context, repo, appState) : null,
            child: const Text('Record Entry'),
          ),
        ],
      ],
    );
  }

  Future<void> _submit(BuildContext context, AppRepository repo, AppState appState) async {
    final kind = _kind!;
    final branch = _branch!;
    final amount = _amountCentavos!;
    final note = _noteController.text.trim();
    final currentBalance = repo.accountBalance(branch, _account);

    late final bool confirmed;
    if (kind == _EntryKind.transfer) {
      final destination = _destinationBranch!;
      final destinationBalance = repo.accountBalance(destination, _destinationAccount);
      confirmed = await ConfirmCashEntryDialog.show(
        context,
        label: 'transfer',
        icon: _EntryKind.transfer.icon,
        color: AppColors.info,
        amountCentavos: amount,
        note: note,
        branch: branch,
        sourceLabel: '${branch.label} ${_account.label}',
        resultingBalanceCentavos: currentBalance - amount,
        destinationBranch: destination,
        destinationLabel: '${destination.label} ${_destinationAccount.label}',
        resultingDestinationBalanceCentavos: destinationBalance + amount,
      );
    } else {
      final isCredit = kind == _EntryKind.cashIn;
      confirmed = await ConfirmCashEntryDialog.show(
        context,
        label: kind.label.toLowerCase(),
        icon: kind.icon,
        color: isCredit ? AppColors.success : AppColors.danger,
        amountCentavos: amount,
        note: note,
        branch: branch,
        sourceLabel: '${branch.label} ${_account.label}',
        resultingBalanceCentavos: isCredit ? currentBalance + amount : currentBalance - amount,
      );
    }
    if (!confirmed || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final role = appState.role;
    switch (kind) {
      case _EntryKind.cashIn:
      case _EntryKind.expense:
      case _EntryKind.withdrawal:
        repo.recordCashEntry(
          branch: branch,
          type: switch (kind) {
            _EntryKind.cashIn => CashEntryType.cashIn,
            _EntryKind.expense => CashEntryType.expense,
            _ => CashEntryType.withdrawal,
          },
          account: _account,
          amountCentavos: amount,
          note: note,
          category: kind == _EntryKind.expense ? _category : null,
          date: _date,
          recordedByRole: role,
          actor: appState.currentUser,
        );
      case _EntryKind.transfer:
        repo.recordTransfer(
          from: branch,
          fromAccount: _account,
          to: _destinationBranch!,
          toAccount: _destinationAccount,
          amountCentavos: amount,
          note: note,
          date: _date,
          recordedByRole: role,
          actor: appState.currentUser,
        );
    }
    messenger.showSnackBar(SnackBar(content: Text('${kind.label} recorded.')));
    _reset();
    widget.onRecorded?.call();
  }
}

/// Radio choice of the three cash sources, each showing its live balance at
/// the chosen branch so the Cashier sees what is actually in it.
class _AccountRadios extends StatelessWidget {
  final String label;
  final BranchId? branch;
  final CashAccount value;
  final CashAccount? disabled;
  final ValueChanged<CashAccount> onChanged;

  const _AccountRadios({
    required this.label,
    required this.branch,
    required this.value,
    required this.onChanged,
    this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: AppColors.cardSurface,
            borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            children: [
              for (final account in CashAccount.values) ...[
                if (account != CashAccount.values.first) const Divider(height: 1),
                _AccountOption(
                  account: account,
                  selected: value == account,
                  enabled: disabled != account,
                  balance: branch == null ? null : repo.accountBalance(branch!, account),
                  onTap: () => onChanged(account),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AccountOption extends StatelessWidget {
  final CashAccount account;
  final bool selected;
  final bool enabled;
  final int? balance;
  final VoidCallback onTap;

  const _AccountOption({
    required this.account,
    required this.selected,
    required this.enabled,
    required this.balance,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.primaryBlue : AppColors.textDisabled;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(
              selected && enabled ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
              color: selected && enabled ? color : AppColors.textDisabled,
              size: 22,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                account.label,
                style: AppTextStyles.bodyLarge.copyWith(
                  color: enabled ? AppColors.textPrimary : AppColors.textDisabled,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (balance != null)
              Text(
                AppFormat.peso(balance!),
                style: AppTextStyles.numericSmall.copyWith(
                  color: enabled ? AppColors.textSecondary : AppColors.textDisabled,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EntryKindGrid extends StatelessWidget {
  final _EntryKind? value;
  final ValueChanged<_EntryKind> onChanged;

  const _EntryKindGrid({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    Color colorFor(_EntryKind k) {
      switch (k) {
        case _EntryKind.cashIn:
          return sc.success;
        case _EntryKind.expense:
        case _EntryKind.withdrawal:
          return sc.danger;
        case _EntryKind.transfer:
          return sc.info;
      }
    }

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpacing.sm,
      crossAxisSpacing: AppSpacing.sm,
      childAspectRatio: 2.4,
      children: [
        for (final k in _EntryKind.values)
          _EntryKindCard(kind: k, color: colorFor(k), selected: value == k, onTap: () => onChanged(k)),
      ],
    );
  }
}

class _EntryKindCard extends StatelessWidget {
  final _EntryKind kind;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _EntryKindCard({
    required this.kind,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          border: Border.all(color: selected ? color : Colors.transparent, width: 1.4),
        ),
        child: Row(
          children: [
            Icon(kind.icon, color: color, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                kind.label,
                style: AppTextStyles.bodyLarge.copyWith(
                  color: selected ? color : AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchPicker extends StatelessWidget {
  final String label;
  final BranchId? value;
  final ValueChanged<BranchId?> onChanged;

  const _BranchPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<BranchId>(
      key: ValueKey('$label-$value'),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [for (final b in BranchId.values) DropdownMenuItem(value: b, child: Text(b.label))],
      onChanged: onChanged,
    );
  }
}

class _CategoryPicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const _CategoryPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Category'),
      items: [for (final c in _expenseCategories) DropdownMenuItem(value: c, child: Text(c))],
      onChanged: onChanged,
    );
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
        decoration: const InputDecoration(labelText: 'Date'),
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
