import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item.dart';
import '../../core/models/item_status.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/numeric_input_field.dart';

/// Admin correction of an item that was recorded wrongly.
///
/// Says up front what an edit here will and won't touch — a partition's
/// change comes out of its lot, a partitioned lot keeps what was drawn from
/// it, and cash already released never moves — so an admin fixing a typo
/// isn't surprised by a knock-on effect. The repository enforces all of it;
/// this screen explains it before the button is pressed.
class EditItemScreen extends StatefulWidget {
  final String itemId;

  const EditItemScreen({super.key, required this.itemId});

  @override
  State<EditItemScreen> createState() => _EditItemScreenState();
}

class _EditItemScreenState extends State<EditItemScreen> {
  late final TextEditingController _description;
  late ItemType _type;
  int? _karat;
  Key _karatKey = UniqueKey();
  late double? _netWeight;
  late double? _grossWeight;
  late int? _amountCentavos;

  /// While true, the gross weight follows the net: the piece was recorded
  /// with nothing deducted, so the two are one reading until someone says
  /// otherwise by editing the gross directly.
  late bool _grossFollowsNet;
  Key _grossKey = UniqueKey();

  late final Item _original;
  late final double _originalWeight;
  late final int _originalAmount;

  @override
  void initState() {
    super.initState();
    final item = context.read<AppRepository>().findItem(widget.itemId)!;
    _original = item;
    // A partitioned lot is edited in terms of what was bought, not what is
    // left of it — the remainder follows automatically.
    _originalWeight = item.hasPartitions ? item.effectiveOriginalGrams : item.weightGrams;
    _originalAmount = item.hasPartitions ? item.effectiveOriginalAmountCentavos : item.capitalAmountCentavos;

    _description = TextEditingController(text: item.description);
    _type = item.type;
    _karat = item.karat;
    _netWeight = _originalWeight;
    _grossWeight = item.grossWeightGrams;
    _grossFollowsNet = _grossWeight != null && (_grossWeight! - _originalWeight).abs() < 1e-9;
    _amountCentavos = _originalAmount;
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  bool get _amountChanged => _amountCentavos != null && _amountCentavos != _originalAmount;

  bool get _dirty =>
      _description.text.trim() != _original.description ||
      _type != _original.type ||
      _karat != _original.karat ||
      (_netWeight != null && (_netWeight! - _originalWeight).abs() > 1e-9) ||
      _grossWeight != _original.grossWeightGrams ||
      _amountChanged;

  bool get _valid =>
      _description.text.trim().isNotEmpty &&
      _karat != null &&
      _netWeight != null &&
      _netWeight! > 0 &&
      _amountCentavos != null &&
      _amountCentavos! > 0 &&
      (_grossWeight == null || _grossWeight! + 1e-9 >= _netWeight!);

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final item = repo.findItem(widget.itemId);
    if (item == null) {
      return const Scaffold(body: Center(child: Text('Item not found')));
    }

    final parent = item.parentLotId == null ? null : repo.findItem(item.parentLotId!);
    final batch = item.batchId == null ? null : repo.findBatch(item.batchId!);
    final paid = !item.isPartitioned &&
        batch != null &&
        batch.verificationStatus == VerificationStatus.verified;
    final partitionCount = repo.partitionsOf(item.id).length;
    final karats = repo.ratesForType(_type).map((r) => r.karat).toList();
    // A partition or a split lot is locked to its metal: its purity is shared
    // with pieces already drawn.
    final metalLocked = item.isPartitioned || item.hasPartitions;

    return Scaffold(
      appBar: AppBar(title: Text('Correct ${item.id}')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (item.isPartitioned && parent != null)
            _Notice(
              icon: Icons.call_split_rounded,
              text: 'This is a partition of lot ${parent.id}. Any change to its weight or '
                  'amount is taken from — or given back to — that lot, which has '
                  '${AppFormat.grams(parent.effectiveRemainingGrams)} and '
                  '${AppFormat.peso(parent.effectiveRemainingAmountCentavos)} left. '
                  'Its karat is the lot\'s and can only be changed there.',
            ),
          if (item.hasPartitions)
            _Notice(
              icon: Icons.inventory_2_outlined,
              text: 'Weight and amount here are what was originally bought. '
                  '$partitionCount partition(s) keep what they drew, so the change lands on '
                  'the remainder. A karat change carries down to every partition.',
            ),
          if (paid)
            _Notice(
              icon: Icons.payments_outlined,
              warning: true,
              text: 'Cash was already released for this purchase. Correcting the amount '
                  'will not move cash — if money changed hands to settle a difference, '
                  'record it in Cash.',
            ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description'),
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Type', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          SegmentedButton<ItemType>(
            segments: [
              for (final t in ItemType.values)
                ButtonSegment(
                  value: t,
                  label: Text(t.label),
                  enabled: !metalLocked || t.isSilver == item.type.isSilver,
                ),
            ],
            selected: {_type},
            onSelectionChanged: item.itemStatus == ItemStatus.sold
                ? null
                : (s) => setState(() {
                      final next = s.first;
                      if (next.isSilver != _type.isSilver) {
                        _karat = next.isSilver == item.type.isSilver ? item.karat : null;
                        _karatKey = UniqueKey();
                      }
                      _type = next;
                    }),
          ),
          if (item.itemStatus == ItemStatus.sold)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'A sold piece keeps its type.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Text(_type.isSilver ? 'Purity' : 'Karat', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          DropdownButtonFormField<int>(
            key: _karatKey,
            initialValue: karats.contains(_karat) ? _karat : null,
            decoration: const InputDecoration(isDense: true),
            items: [
              for (final k in karats) DropdownMenuItem(value: k, child: Text(AppFormat.karat(k))),
            ],
            onChanged: item.isPartitioned ? null : (v) => setState(() => _karat = v ?? _karat),
          ),
          if (_karat == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Pick a ${_type.isSilver ? 'silver purity' : 'karat'} for this ${_type.label.toLowerCase()} piece.',
                style: AppTextStyles.caption.copyWith(color: AppColors.danger),
              ),
          ),
          if (!item.isPartitioned) ...[
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              key: _grossKey,
              label: 'Original weight (as weighed)',
              kind: NumericInputKind.grams,
              initialValue: _grossWeight,
              onChanged: (v) => setState(() {
                _grossWeight = v;
                _grossFollowsNet = false;
              }),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: item.hasPartitions ? 'Final weight (as bought)' : 'Final weight (net gold)',
            kind: NumericInputKind.grams,
            initialValue: _netWeight,
            onChanged: (v) => setState(() {
              _netWeight = v;
              if (_grossFollowsNet && !item.isPartitioned) {
                _grossWeight = v;
                _grossKey = UniqueKey();
              }
            }),
          ),
          const SizedBox(height: AppSpacing.md),
          NumericInputField(
            label: item.hasPartitions ? 'Amount (as bought)' : 'Amount',
            kind: NumericInputKind.peso,
            initialValue: _amountCentavos == null ? null : _amountCentavos! / 100,
            onChanged: (v) => setState(() => _amountCentavos = v == null ? null : (v * 100).round()),
          ),
          if (_grossWeight != null && _netWeight != null && _grossWeight! + 1e-9 < _netWeight!)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'The original weight cannot be less than the final weight.',
                style: AppTextStyles.caption.copyWith(color: AppColors.danger),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton.icon(
            onPressed: (_dirty && _valid) ? () => _save(context, repo, item, paid) : null,
            icon: const Icon(Icons.save_rounded),
            label: const Text('Save Correction'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Recorded in the transaction log under ${context.watch<AppState>().currentUser.name}.',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, AppRepository repo, Item item, bool paid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Save correction to ${item.id}?'),
        content: Text(
          'The change is applied now and written to the transaction log with the '
          'before and after values.'
          '${paid && _amountChanged ? '\n\nCash already released is not changed.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final changes = repo.updateItem(
        item.id,
        description: _description.text,
        type: _type,
        karat: _karat,
        weightGrams: _netWeight,
        grossWeightGrams: item.isPartitioned ? null : _grossWeight,
        capitalAmountCentavos: _amountCentavos,
        actor: context.read<AppState>().currentUser,
      );
      if (!context.mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            changes.isEmpty ? 'Nothing changed.' : '${changes.length} correction(s) saved to ${item.id}.',
          ),
        ),
      );
    } on ArgumentError catch (error) {
      _refuse(context, error.message.toString());
    } on StateError catch (error) {
      _refuse(context, error.message);
    }
  }

  void _refuse(BuildContext context, String reason) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Correction not saved'),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warning;

  const _Notice({required this.icon, required this.text, this.warning = false});

  @override
  Widget build(BuildContext context) {
    final color = warning ? context.semanticColors.warning : AppColors.info;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}
