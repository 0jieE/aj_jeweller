import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item.dart';
import '../../core/models/purchase_batch.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/numeric_input_field.dart';
import '../../core/widgets/value_display.dart';
import '../../core/navigation/layout.dart';

/// Entry for one piece within a purchase — weighed, karated, and priced.
///
/// Pops a [PurchaseDraftLine] rather than writing anything: the basket owns
/// the transaction, and a piece the customer takes back should leave no
/// record behind.
///
/// Net weight, price per gram, and amount are one equation, so any two
/// settle the third. Price per gram starts at the karat's rate from Gold
/// Rate setup — the figure the shop actually quotes — but it is an input,
/// not a readout: staff routinely shade it for a worn piece or a regular
/// customer, and the amount follows. Type a total instead and the per-gram
/// rate is back-solved, so the receipt can never disagree with itself.
class PurchaseLineFormScreen extends StatefulWidget {
  /// Supplied when editing a line already in the basket.
  final PurchaseDraftLine? existing;

  const PurchaseLineFormScreen({super.key, this.existing});

  @override
  State<PurchaseLineFormScreen> createState() => _PurchaseLineFormScreenState();
}

class _PurchaseLineFormScreenState extends State<PurchaseLineFormScreen> {
  late final TextEditingController _descriptionController;

  double? _grossWeight;
  double? _netWeight;
  int? _karat;
  ItemType _type = ItemType.goods;
  int? _amountCentavos;

  Uint8List? _photo;
  int? _perGramCentavos;

  /// True once staff have typed their own rate, after which picking a karat
  /// no longer overwrites it with the setup figure.
  bool _perGramEdited = false;

  /// Whether staff have actually typed a net weight. Until they do, net
  /// mirrors gross — most pieces have nothing to deduct, and keeping the
  /// mirror live means a gross of "9.2" doesn't leave net stranded at the
  /// "9" that was on screen one keystroke earlier.
  bool _netEdited = false;

  // Rebuilt from state rather than held, so a recalculated value always shows.
  Key _netFieldKey = UniqueKey();
  Key _amountFieldKey = UniqueKey();
  Key _perGramFieldKey = UniqueKey();
  Key _karatFieldKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _descriptionController = TextEditingController(text: existing?.description ?? '');
    _grossWeight = existing?.grossWeightGrams;
    _netWeight = existing?.weightGrams;
    _karat = existing?.karat;
    _type = existing?.type ?? ItemType.goods;
    _amountCentavos = existing?.capitalAmountCentavos;
    _photo = existing?.photo;
    // An existing line already has both weights settled, and its rate is
    // whatever it was actually struck at.
    _netEdited = existing != null;
    if (existing != null && existing.weightGrams > 0) {
      _perGramCentavos = (existing.capitalAmountCentavos / existing.weightGrams).round();
      _perGramEdited = true;
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _descriptionController.text.trim().isNotEmpty &&
      _netWeight != null &&
      _netWeight! > 0 &&
      _karat != null &&
      _amountCentavos != null &&
      _amountCentavos! > 0 &&
      (_grossWeight == null || _grossWeight! >= _netWeight!);

  int? _ratePerGram(AppRepository repo) => _karat == null ? null : repo.rateForKarat(_karat!)?.pricePerGramCentavos;

  /// Seeds the per-gram rate from Gold Rate setup for the chosen karat,
  /// unless staff have already quoted their own.
  void _applySetupRate(AppRepository repo) {
    if (_perGramEdited) return;
    final rate = _ratePerGram(repo);
    if (rate == null) return;
    _perGramCentavos = rate;
    _perGramFieldKey = UniqueKey();
  }

  /// amount = net weight x price per gram.
  void _amountFromRate() {
    if (_netWeight == null || _perGramCentavos == null) return;
    _amountCentavos = (_netWeight! * _perGramCentavos!).round();
    _amountFieldKey = UniqueKey();
  }

  /// Back-solves the rate when staff quote a total instead. That counts as
  /// quoting their own rate, so picking a karat afterwards won't overwrite it.
  void _rateFromAmount() {
    if (_netWeight == null || _netWeight! <= 0 || _amountCentavos == null) return;
    _perGramCentavos = (_amountCentavos! / _netWeight!).round();
    _perGramEdited = true;
    _perGramFieldKey = UniqueKey();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final rate = _ratePerGram(repo);
    final deducted = (_grossWeight != null && _netWeight != null)
        ? _grossWeight! - _netWeight!
        : null;

    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add Item' : 'Edit Item')),
      body: FormPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(hintText: 'Description (e.g. 22K necklace, rope chain)'),
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Type', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            _TypeSelector(
              value: _type,
              onChanged: (v) => setState(() {
                // Crossing between gold and silver invalidates the purity and
                // the rate it loaded; goods <-> scrap keeps both.
                if (v.isSilver != _type.isSilver) {
                  _karat = null;
                  _karatFieldKey = UniqueKey();
                  if (!_perGramEdited) {
                    _perGramCentavos = null;
                    _perGramFieldKey = UniqueKey();
                  }
                }
                _type = v;
              }),
            ),
            const SizedBox(height: AppSpacing.md),

            // Gross first, then what's left after stones and fittings come off —
            // the order the piece is actually handled at the counter.
            NumericInputField(
              label: 'Original weight (as weighed)',
              kind: NumericInputKind.grams,
              initialValue: _grossWeight,
              helperText: 'Everything on the scale, stones and clasps included',
              onChanged: (v) => setState(() {
                _grossWeight = v;
                // Nothing deducted is the common case, so net follows gross
                // until someone actually types a different net.
                if (!_netEdited) {
                  _netWeight = v;
                  _netFieldKey = UniqueKey();
                  _amountFromRate();
                }
              }),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: NumericInputField(
                    key: _netFieldKey,
                    label: _type.isSilver ? 'Final weight (net silver)' : 'Final weight (net gold)',
                    kind: NumericInputKind.grams,
                    initialValue: _netWeight,
                    onChanged: (v) => setState(() {
                      _netWeight = v;
                      _netEdited = true;
                      _amountFromRate();
                    }),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 118,
                  child: _KaratPicker(
                    key: _karatFieldKey,
                    value: _karat,
                    type: _type,
                    repo: repo,
                    onChanged: (v) => setState(() {
                      _karat = v;
                      _applySetupRate(repo);
                      _amountFromRate();
                    }),
                  ),
                ),
              ],
            ),
            if (deducted != null && deducted > 0.0005) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Deducting ${AppFormat.grams(deducted)} of stones and fittings.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
            if (deducted != null && deducted < -0.0005) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Final weight cannot exceed the original weight.',
                style: AppTextStyles.caption.copyWith(color: AppColors.danger),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              key: _perGramFieldKey,
              label: 'Price per gram',
              kind: NumericInputKind.peso,
              initialValue: _perGramCentavos == null ? null : _perGramCentavos! / 100,
              helperText: rate == null
                  ? (_type.isSilver ? 'Pick a purity to load the setup rate' : 'Pick a karat to load the setup rate')
                  : _perGramEdited
                      ? 'Setup rate for ${AppFormat.karat(_karat!)} is ${AppFormat.peso(rate)}'
                      : 'From rate setup — edit to quote a different rate',
              onChanged: (v) => setState(() {
                _perGramCentavos = v == null ? null : (v * 100).round();
                _perGramEdited = true;
                _amountFromRate();
              }),
            ),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              key: _amountFieldKey,
              label: 'Purchase Amount',
              kind: NumericInputKind.peso,
              initialValue: _amountCentavos == null ? null : _amountCentavos! / 100,
              helperText: 'Weight x rate — or type a total and the rate follows',
              onChanged: (v) => setState(() {
                _amountCentavos = v == null ? null : (v * 100).round();
                _rateFromAmount();
              }),
            ),
            if (_perGramCentavos != null && _netWeight != null) ...[
              const SizedBox(height: AppSpacing.md),
              ValueDisplay(
                label: '${AppFormat.grams(_netWeight!)} × ${AppFormat.peso(_perGramCentavos!)}/g',
                value: AppFormat.peso((_perGramCentavos! * _netWeight!).round()),
                origin: FigureOrigin.derived,
              ),
              if (rate != null && _perGramCentavos != rate)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    _perGramCentavos! < rate
                        ? 'Quoted ${AppFormat.peso(rate - _perGramCentavos!)}/g below the setup rate.'
                        : 'Quoted ${AppFormat.peso(_perGramCentavos! - rate)}/g above the setup rate.',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ),
            ],
            const SizedBox(height: AppSpacing.lg),
            ItemPhotoField(
              photo: _photo,
              onChanged: (bytes) => setState(() => _photo = bytes),
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton(
              onPressed: _isValid ? _save : null,
              child: Text(widget.existing == null ? 'Add to Purchase' : 'Save Item'),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final net = _netWeight!;
    Navigator.of(context).pop(
      PurchaseDraftLine(
        description: _descriptionController.text.trim(),
        grossWeightGrams: _grossWeight ?? net,
        weightGrams: net,
        karat: _karat!,
        type: _type,
        capitalAmountCentavos: _amountCentavos!,
        photo: _photo,
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
    return Row(
      children: [
        for (final type in ItemType.values) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(type),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value == type ? AppColors.primaryBlue.withValues(alpha: 0.10) : AppColors.surfaceDim,
                  borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                  border: Border.all(
                    color: value == type ? AppColors.primaryBlue : AppColors.outline,
                    width: value == type ? 1.4 : 1,
                  ),
                ),
                child: Text(
                  type.label,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: value == type ? AppColors.primaryBlue : AppColors.textSecondary,
                    fontWeight: value == type ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          if (type != ItemType.values.last) const SizedBox(width: AppSpacing.sm),
        ],
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
    // dense undecorated box) so it lines up with the weight field beside it.
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
