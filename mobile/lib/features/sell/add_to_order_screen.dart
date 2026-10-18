import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/state/app_state.dart';
import '../../core/models/item.dart';
import '../../core/state/cart_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/numeric_input_field.dart';
import '../../core/widgets/status_badges.dart';
import '../../core/widgets/value_display.dart';
import '../../core/navigation/layout.dart';

/// Item detail plus price entry — the rep negotiates on the spot, so nothing
/// here is pre-filled beyond a market-rate reference.
///
/// A piece is re-weighed at the sale (repair and polishing lose grams since
/// it was bought), and customers haggle in both currencies: some ask for a
/// per-gram rate, some for a total. Entering either settles the other from
/// the final weight, so the two can never disagree on the receipt.
class AddToOrderScreen extends StatefulWidget {
  final String itemId;

  const AddToOrderScreen({super.key, required this.itemId});

  @override
  State<AddToOrderScreen> createState() => _AddToOrderScreenState();
}

class _AddToOrderScreenState extends State<AddToOrderScreen> {
  int? _priceCentavos;
  int? _perGramCentavos;
  double? _finalGrams;

  /// Rebuilt so a recalculated figure actually reaches its field.
  Key _priceKey = UniqueKey();
  Key _perGramKey = UniqueKey();

  double get _grams => _finalGrams ?? 0;

  /// Total follows the per-gram rate the rep quoted.
  void _fromPerGram() {
    if (_perGramCentavos == null || _grams <= 0) return;
    _priceCentavos = (_perGramCentavos! * _grams).round();
    _priceKey = UniqueKey();
  }

  /// Per-gram follows the total the rep agreed.
  void _fromTotal() {
    if (_priceCentavos == null || _grams <= 0) return;
    _perGramCentavos = (_priceCentavos! / _grams).round();
    _perGramKey = UniqueKey();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final cart = context.watch<CartState>();
    final item = repo.findItem(widget.itemId);

    if (item == null) {
      return const Scaffold(body: Center(child: Text('Item not found')));
    }

    _finalGrams ??= item.weightGrams;

    final rate = repo.rateForKarat(item.karat);
    // The selling rate starts at the karat's figure from Gold Rate setup —
    // what the shop quotes before any haggling — and stays editable.
    if (_perGramCentavos == null && rate != null) {
      _perGramCentavos = rate.pricePerGramCentavos;
      _fromPerGram();
    }
    final referenceAmount = rate != null ? (rate.pricePerGramCentavos * _grams).round() : null;
    final sc = context.semanticColors;

    return Scaffold(
      appBar: AppBar(title: const Text('Add to Order')),
      body: FormPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.description, style: AppTextStyles.headlineMedium.copyWith(fontSize: 19)),
                    const SizedBox(height: AppSpacing.xs),
                    ItemStatusBadge(status: item.itemStatus),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(child: _Stat(label: 'Weight', value: AppFormat.grams(item.weightGrams))),
                        Expanded(child: _Stat(label: item.type.isSilver ? 'Purity' : 'Karat', value: AppFormat.karat(item.karat), color: PurityPalette.of(context, item.karat).text)),
                        Expanded(child: _Stat(label: 'Capital', value: AppFormat.peso(item.capitalAmountCentavos, whole: true))),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const Divider(),
                    const SizedBox(height: AppSpacing.xs),
                    Text('Origin', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                    Text(item.origin, style: AppTextStyles.bodyLarge),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (referenceAmount != null)
              ValueDisplay(
                label: '${AppFormat.karat(item.karat)} market reference · ${AppFormat.peso(rate!.pricePerGramCentavos)}/g',
                value: AppFormat.peso(referenceAmount),
                origin: FigureOrigin.derived,
                valueColor: sc.gold,
              ),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              label: 'Final weight (re-weighed at sale)',
              kind: NumericInputKind.grams,
              initialValue: _finalGrams,
              helperText: 'Recorded at purchase as ${AppFormat.grams(item.weightGrams)}',
              onChanged: (v) => setState(() {
                _finalGrams = v;
                // The weight underpins both money figures; keep the total as
                // agreed and let the per-gram rate follow it.
                _fromTotal();
              }),
            ),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              key: _perGramKey,
              label: 'Price per gram',
              kind: NumericInputKind.peso,
              initialValue: _perGramCentavos == null ? null : _perGramCentavos! / 100,
              helperText: rate == null
                  ? null
                  : 'From Gold Rate setup — edit to quote a different rate',
              onChanged: (v) => setState(() {
                _perGramCentavos = v == null ? null : (v * 100).round();
                _fromPerGram();
              }),
            ),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              key: _priceKey,
              label: 'Selling Price',
              kind: NumericInputKind.peso,
              autofocus: true,
              initialValue: _priceCentavos == null ? null : _priceCentavos! / 100,
              helperText: 'Edit either figure — the other follows the final weight',
              onChanged: (v) => setState(() {
                _priceCentavos = v == null ? null : (v * 100).round();
                _fromTotal();
              }),
            ),
            const SizedBox(height: AppSpacing.lg),
            // Stored straight onto the item rather than the cart line: it is a
            // photo of the piece, and the Cashier verifying this sale needs it
            // whether or not this particular order goes through.
            ItemPhotoField(
              photo: item.photo,
              onChanged: (bytes) {
                if (bytes != null) {
                  repo.setItemPhoto(item.id, bytes, actor: context.read<AppState>().currentUser);
                }
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton(
              onPressed: (_priceCentavos != null && _priceCentavos! > 0 && _grams > 0)
                  ? () => _addToOrder(context, cart, item)
                  : null,
              child: const Text('Add to Order'),
            ),
          ],
        ),
      ),
    );
  }

  void _addToOrder(BuildContext context, CartState cart, Item item) {
    if (!cart.canAdd(item)) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Different branch'),
          content: Text(
            'This order already has items from ${cart.branch!.label}. Clear the '
            'current order before selling from a different branch.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    cart.addLine(item, _priceCentavos!, finalGrams: _finalGrams);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Added — ${cart.itemCount} item(s) in order, ${AppFormat.peso(cart.totalCentavos)}.')),
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
