import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/item.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/status_badges.dart';
import '../../core/widgets/numeric_input_field.dart';
import '../../core/widgets/value_display.dart';

/// Filled in at the counter while a customer waits. When [editingItem] is
/// set, this is a Cashier's "returned for correction" being fixed and
/// resubmitted by the original appraiser rather than a brand-new purchase.
class PurchaseFormScreen extends StatefulWidget {
  final Item? editingItem;

  const PurchaseFormScreen({super.key, this.editingItem});

  @override
  State<PurchaseFormScreen> createState() => _PurchaseFormScreenState();
}

class _PurchaseFormScreenState extends State<PurchaseFormScreen> {
  late DateTime _date;
  late final TextEditingController _descriptionController;
  late final TextEditingController _originController;
  double? _weightGrams;
  int? _karat;
  ItemType _type = ItemType.goods;
  int? _amountCentavos;
  BranchId? _branch;
  Key _karatFieldKey = UniqueKey();

  bool get _isEditing => widget.editingItem != null;

  @override
  void initState() {
    super.initState();
    final editing = widget.editingItem;
    _date = editing?.purchaseDate ?? DateTime.now();
    _descriptionController = TextEditingController(text: editing?.description ?? '');
    _originController = TextEditingController(text: editing?.origin ?? '');
    _weightGrams = editing?.weightGrams;
    _karat = editing?.karat;
    _type = editing?.type ?? ItemType.goods;
    _amountCentavos = editing?.capitalAmountCentavos;
    _branch = editing?.branch;
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _originController.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _descriptionController.text.trim().isNotEmpty &&
      _originController.text.trim().isNotEmpty &&
      _weightGrams != null &&
      _weightGrams! > 0 &&
      _karat != null &&
      _amountCentavos != null &&
      _amountCentavos! > 0 &&
      _branch != null;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final resolvedBranch = _branch ?? appState.selectedBranch;
    if (_branch == null && resolvedBranch != null) {
      _branch = resolvedBranch;
    }

    final rate = _karat != null ? repo.rateForKarat(_karat!) : null;
    final referenceAmount = rate != null && _weightGrams != null
        ? (rate.pricePerGramCentavos * _weightGrams!).round()
        : null;

    final todaysTotal = repo
        .purchasesToday(branchId: resolvedBranch)
        .fold<int>(0, (sum, i) => sum + i.capitalAmountCentavos);
    final branchBalance = resolvedBranch != null ? repo.cashBalance(resolvedBranch) : null;

    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Fix & Resubmit' : 'New Purchase')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (_isEditing && widget.editingItem?.verificationNote != null)
            _CorrectionNoteBanner(note: widget.editingItem!.verificationNote!),
          if (branchBalance != null) _CashTrackerCard(todaysTotal: todaysTotal, branchBalance: branchBalance),
          const SizedBox(height: AppSpacing.md),
          if (appState.selectedBranch == null)
            _BranchPicker(value: _branch, onChanged: (v) => setState(() => _branch = v))
          else
            _ReadOnlyField(label: 'Branch', value: resolvedBranch?.label ?? '—'),
          const SizedBox(height: AppSpacing.md),
          _DateField(date: _date, onChanged: (d) => setState(() => _date = d)),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: 'Description'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          _TypeSelector(
            value: _type,
            onChanged: (v) => setState(() {
              if (v.isSilver != _type.isSilver) {
                _karat = null;
                _karatFieldKey = UniqueKey();
              }
              _type = v;
            }),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: NumericInputField(
                  label: 'Weight',
                  kind: NumericInputKind.grams,
                  initialValue: _weightGrams,
                  onChanged: (v) => setState(() => _weightGrams = v),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _KaratPicker(
                  key: _karatFieldKey,
                  value: _karat,
                  type: _type,
                  repo: repo,
                  onChanged: (v) => setState(() => _karat = v),
                ),
              ),
            ],
          ),
          if (rate != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _GoldRateReferenceCard(
              karat: rate.karat,
              pricePerGramCentavos: rate.pricePerGramCentavos,
              referenceAmount: referenceAmount,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: 'Purchase Amount',
            kind: NumericInputKind.peso,
            initialValue: _amountCentavos != null ? _amountCentavos! / 100 : null,
            onChanged: (v) => setState(() => _amountCentavos = v != null ? (v * 100).round() : null),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _originController,
            decoration: const InputDecoration(labelText: 'Origin note (e.g. "Walk-in – Juan Dela Cruz")'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton(
            onPressed: _isValid ? () => _save(context, repo, appState) : null,
            child: Text(_isEditing ? 'Resubmit for Verification' : 'Save Purchase'),
          ),
        ],
      ),
    );
  }

  void _save(BuildContext context, AppRepository repo, AppState appState) {
    if (_isEditing) {
      repo.resubmitItem(
        actor: context.read<AppState>().currentUser,
        widget.editingItem!.id,
        description: _descriptionController.text.trim(),
        weightGrams: _weightGrams!,
        karat: _karat!,
        type: _type,
        capitalAmountCentavos: _amountCentavos!,
        origin: _originController.text.trim(),
      );
    } else {
      repo.addPurchase(
        description: _descriptionController.text.trim(),
        weightGrams: _weightGrams!,
        karat: _karat!,
        type: _type,
        capitalAmountCentavos: _amountCentavos!,
        origin: _originController.text.trim(),
        branch: _branch!,
        purchaseDate: _date,
        submittedByRole: appState.role,
      );
    }
    _showSavedDialog(context);
  }

  void _showSavedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.cardRadius)),
        icon: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: AppColors.info.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: const Icon(Icons.hourglass_top_rounded, color: AppColors.info),
        ),
        title: const Text('Saved — awaiting verification', textAlign: TextAlign.center),
        content: Text(
          'Cash has NOT been released. This purchase now sits in the Cashier\'s '
          'queue until it\'s verified against the physical item.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).pop();
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _CorrectionNoteBanner extends StatelessWidget {
  final String note;

  const _CorrectionNoteBanner({required this.note});

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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.flag_rounded, color: sc.danger, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Returned by Cashier', style: AppTextStyles.labelSmall.copyWith(color: sc.danger)),
                const SizedBox(height: 2),
                Text(note, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CashTrackerCard extends StatelessWidget {
  final int todaysTotal;
  final int branchBalance;

  const _CashTrackerCard({required this.todaysTotal, required this.branchBalance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cash used today', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                Text(AppFormat.peso(todaysTotal, whole: true), style: AppTextStyles.numericMedium),
              ],
            ),
          ),
          Container(width: 1, height: 32, color: AppColors.outline),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Remaining on hand', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                  Text(
                    AppFormat.peso(branchBalance - todaysTotal, whole: true),
                    style: AppTextStyles.numericMedium.copyWith(color: AppColors.primaryBlue),
                  ),
                ],
              ),
            ),
          ),
        ],
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
    return DropdownButtonFormField<BranchId>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Branch'),
      items: [for (final b in BranchId.values) DropdownMenuItem(value: b, child: Text(b.label))],
      onChanged: onChanged,
    );
  }
}

class _ReadOnlyField extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Row(
        children: [
          Text('$label: ', style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
          Text(value, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
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

class _TypeSelector extends StatelessWidget {
  final ItemType value;
  final ValueChanged<ItemType> onChanged;

  const _TypeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Type', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        SegmentedButton<ItemType>(
          segments: [for (final t in ItemType.values) ButtonSegment(value: t, label: Text(t.label))],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

class _KaratPicker extends StatelessWidget {
  final int? value;
  final ItemType type;
  final AppRepository repo;
  final ValueChanged<int?> onChanged;

  const _KaratPicker({
    super.key,
    required this.value,
    required this.type,
    required this.repo,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final karats = repo.ratesForType(type).map((r) => r.karat).toList();
    // Mirrors NumericInputField's structure exactly (external label + gap,
    // dense undecorated box) so it lines up with the Weight field beside it
    // — a DropdownButtonFormField's own internal floating label sits at a
    // different height and throws the row out of alignment.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(type.isSilver ? 'Purity' : 'Karat', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        DropdownButtonFormField<int>(
          initialValue: karats.contains(value) ? value : null,
          decoration: const InputDecoration(isDense: true),
          items: [for (final k in karats) DropdownMenuItem(value: k, child: Text(AppFormat.karat(k)))],
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _GoldRateReferenceCard extends StatelessWidget {
  final int karat;
  final int pricePerGramCentavos;
  final int? referenceAmount;

  const _GoldRateReferenceCard({
    required this.karat,
    required this.pricePerGramCentavos,
    required this.referenceAmount,
  });

  @override
  Widget build(BuildContext context) {
    return ValueDisplay(
      label: '${AppFormat.karat(karat)} reference · ${AppFormat.peso(pricePerGramCentavos)}/g',
      value: referenceAmount != null ? AppFormat.peso(referenceAmount!) : '—',
      origin: FigureOrigin.derived,
      valueColor: PurityPalette.of(context, karat).text,
    );
  }
}
