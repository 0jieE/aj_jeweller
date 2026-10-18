import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/cash_entry.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/numeric_input_field.dart';

const _expenseCategories = ['Rent', 'Utilities', 'Salaries', 'Supplies', 'Transport', 'Other'];

/// What can be done with one cash history row: see it in full and, for a
/// hand-typed entry, correct or delete it. Entries written by a purchase,
/// sale, or loan explain where to correct them instead.
Future<void> showCashEntryActions(BuildContext context, CashEntry entry) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _CashEntrySheet(entryId: entry.id, hostContext: context),
  );
}

class _CashEntrySheet extends StatelessWidget {
  final String entryId;
  final BuildContext hostContext;

  const _CashEntrySheet({required this.entryId, required this.hostContext});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final entry = repo.findCashEntry(entryId);
    if (entry == null) return const SizedBox(height: 80);
    final group = repo.cashEntryGroup(entry);
    final lock = repo.cashEntryLockReason(entry);
    final canEdit = context.watch<AppState>().role.canManageCash && lock == null;
    final sc = context.semanticColors;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              entry.isTransfer ? 'Transfer' : entry.type.label,
              style: AppTextStyles.titleLarge,
            ),
            Text(
              'Entry ${entry.id} · ${AppFormat.dateTimeShort(entry.date)}',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              AppFormat.peso(entry.amountCentavos),
              style: AppTextStyles.numericLarge.copyWith(
                color: entry.isTransfer ? AppColors.info : (entry.type.isCredit ? sc.success : sc.danger),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final e in group)
              Text(
                entry.isTransfer
                    ? '${e.type == CashEntryType.transferOut ? 'From' : 'To'}: ${e.branch.label} ${e.account.label}'
                    : '${e.branch.label} ${e.account.label}',
                style: AppTextStyles.bodyMedium,
              ),
            if (entry.category != null) Text('Category: ${entry.category}', style: AppTextStyles.bodyMedium),
            Text(entry.note, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.md),
            if (lock != null)
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline_rounded, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text(lock, style: AppTextStyles.bodyMedium)),
                  ],
                ),
              )
            else if (canEdit)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: const BorderSide(color: AppColors.danger),
                      ),
                      onPressed: () async {
                        final deleted = await _confirmDelete(context, repo, entry);
                        if (deleted && context.mounted) Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Delete'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(hostContext).push(
                          MaterialPageRoute(builder: (_) => EditCashEntryScreen(entryId: entry.id)),
                        );
                      },
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: const Text('Edit'),
                    ),
                  ),
                ],
              )
            else
              Text(
                'Only an Admin can change a cash entry.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            if (lock == null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Changes are recorded in Transaction Logs.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, AppRepository repo, CashEntry entry) async {
    final reason = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final group = repo.cashEntryGroup(entry);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${entry.isTransfer ? 'this transfer' : 'this ${entry.type.label.toLowerCase()}'}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${AppFormat.peso(entry.amountCentavos)} goes back as if it had never been entered'
              '${entry.isTransfer ? ' — both sides of the transfer are removed' : ''}.',
              style: AppTextStyles.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final e in group)
              Text(
                '${e.branch.label} ${e.account.label}: '
                '${AppFormat.peso(repo.accountBalance(e.branch, e.account))} → '
                '${AppFormat.peso(repo.accountBalance(e.branch, e.account) - e.signedAmountCentavos)}',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: 'Reason (e.g. "entered twice")'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      reason.dispose();
      return false;
    }
    try {
      repo.deleteCashEntry(entry.id, reason: reason.text, actor: context.read<AppState>().currentUser);
      messenger.showSnackBar(const SnackBar(content: Text('Cash entry deleted and logged.')));
      return true;
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return false;
    } finally {
      reason.dispose();
    }
  }
}

/// Correction form for a hand-typed cash entry.
class EditCashEntryScreen extends StatefulWidget {
  final String entryId;

  const EditCashEntryScreen({super.key, required this.entryId});

  @override
  State<EditCashEntryScreen> createState() => _EditCashEntryScreenState();
}

class _EditCashEntryScreenState extends State<EditCashEntryScreen> {
  late final CashEntry _original;
  late final List<CashEntry> _group;
  late CashEntryType _type;
  late CashAccount _account;
  late CashAccount _destinationAccount;
  late int? _amount;
  late String? _category;
  late DateTime _date;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final repo = context.read<AppRepository>();
    _original = repo.findCashEntry(widget.entryId)!;
    _group = repo.cashEntryGroup(_original);
    final out = _group.first;
    _type = _original.type;
    _account = out.account;
    _destinationAccount = _group.last.account;
    _amount = out.amountCentavos;
    _category = out.category;
    _date = out.date;
    _note = TextEditingController(text: out.note);
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _isTransfer => _original.isTransfer;

  bool get _valid =>
      (_amount ?? 0) > 0 &&
      _note.text.trim().isNotEmpty &&
      (_isTransfer || _type != CashEntryType.expense || (_category ?? '').isNotEmpty) &&
      !(_isTransfer && _group.first.branch == _group.last.branch && _account == _destinationAccount);

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    return Scaffold(
      appBar: AppBar(title: Text('Edit ${_isTransfer ? 'Transfer' : 'Cash Entry'}')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (!_isTransfer) ...[
            Text('Type', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            SegmentedButton<CashEntryType>(
              segments: const [
                ButtonSegment(value: CashEntryType.cashIn, label: Text('Cash In')),
                ButtonSegment(value: CashEntryType.expense, label: Text('Expense')),
                ButtonSegment(value: CashEntryType.withdrawal, label: Text('Withdraw')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          _SourcePicker(
            label: _isTransfer ? 'From: ${_group.first.branch.label}' : 'Cash source · ${_original.branch.label}',
            value: _account,
            balanceOf: (a) => repo.accountBalance(_group.first.branch, a),
            onChanged: (v) => setState(() => _account = v),
          ),
          if (_isTransfer) ...[
            const SizedBox(height: AppSpacing.md),
            _SourcePicker(
              label: 'To: ${_group.last.branch.label}',
              value: _destinationAccount,
              balanceOf: (a) => repo.accountBalance(_group.last.branch, a),
              onChanged: (v) => setState(() => _destinationAccount = v),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: 'Amount',
            kind: NumericInputKind.peso,
            initialValue: _amount == null ? null : _amount! / 100,
            onChanged: (v) => setState(() => _amount = v == null ? null : (v * 100).round()),
          ),
          if (!_isTransfer && _type == CashEntryType.expense) ...[
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _expenseCategories.contains(_category) ? _category : null,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [for (final c in _expenseCategories) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (v) => setState(() => _category = v),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Note'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          InkWell(
            onTap: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(now.year - 1),
                lastDate: now,
              );
              if (picked != null) {
                setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute));
              }
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Date'),
              child: Text(AppFormat.dateShort(_date), style: AppTextStyles.bodyLarge),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: _valid ? () => _save(repo) : null,
            icon: const Icon(Icons.save_rounded),
            label: const Text('Save Correction'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'The before and after values are recorded in Transaction Logs.',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  void _save(AppRepository repo) {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final changes = repo.updateCashEntry(
        _original.id,
        type: _isTransfer ? null : _type,
        account: _account,
        destinationAccount: _isTransfer ? _destinationAccount : null,
        amountCentavos: _amount,
        note: _note.text,
        category: _type == CashEntryType.expense ? _category : null,
        date: _date,
        actor: context.read<AppState>().currentUser,
      );
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(
        content: Text(changes.isEmpty ? 'Nothing changed.' : '${changes.length} correction(s) saved and logged.'),
      ));
    } on ArgumentError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message.toString())));
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _SourcePicker extends StatelessWidget {
  final String label;
  final CashAccount value;
  final int Function(CashAccount) balanceOf;
  final ValueChanged<CashAccount> onChanged;

  const _SourcePicker({
    required this.label,
    required this.value,
    required this.balanceOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
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
              for (final a in CashAccount.values) ...[
                if (a != CashAccount.values.first) const Divider(height: 1),
                InkWell(
                  onTap: () => onChanged(a),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Row(
                      children: [
                        Icon(
                          value == a ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: value == a ? AppColors.primaryBlue : AppColors.textDisabled,
                          size: 22,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: Text(a.label, style: AppTextStyles.bodyLarge)),
                        Text(AppFormat.peso(balanceOf(a)), style: AppTextStyles.numericSmall),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
