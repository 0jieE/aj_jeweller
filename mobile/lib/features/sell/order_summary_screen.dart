import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/state/cart_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/status_badges.dart';
import '../../core/widgets/numeric_input_field.dart';
import 'checkout_screen.dart';

/// The rep's working view of the deal in progress — every line's price can
/// be renegotiated and any item pulled out, without starting the order
/// over. This is what the persistent cart bar opens into.
class OrderSummaryScreen extends StatelessWidget {
  const OrderSummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Summary'),
        actions: [
          if (!cart.isEmpty)
            TextButton(
              onPressed: () => _confirmClear(context, cart),
              child: const Text('Clear', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: cart.isEmpty
          ? const EmptyState(
              icon: Icons.shopping_bag_outlined,
              title: 'Nothing in this order yet',
              message: 'Browse goods and add items to start building an order.',
            )
          : Column(
              children: [
                if (cart.editingSaleId != null) _EditingBanner(note: cart.editingSaleNote),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: cart.lines.length,
                    separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, i) {
                      final line = cart.lines[i];
                      return _CartLineTile(
                        line: line,
                        onEditPrice: () => _editPrice(context, cart, line),
                        onRemove: () => cart.removeLine(line.item.id),
                      );
                    },
                  ),
                ),
                _TotalBar(cart: cart),
              ],
            ),
    );
  }

  void _confirmClear(BuildContext context, CartState cart) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear this order?'),
        content: Text(
          '${cart.itemCount} item(s) will be released back into sellable inventory.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) cart.cancelCart();
  }

  void _editPrice(BuildContext context, CartState cart, CartLine line) async {
    final newPrice = await showDialog<int>(
      context: context,
      builder: (_) => _EditPriceDialog(line: line),
    );
    if (newPrice != null) cart.updatePrice(line.item.id, newPrice);
  }
}

class _EditingBanner extends StatelessWidget {
  final String? note;

  const _EditingBanner({required this.note});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: sc.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: sc.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flag_rounded, color: sc.danger, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text('Fixing a returned order', style: AppTextStyles.titleMedium.copyWith(color: sc.danger)),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(note!, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textPrimary)),
          ],
        ],
      ),
    );
  }
}

class _CartLineTile extends StatelessWidget {
  final CartLine line;
  final VoidCallback onEditPrice;
  final VoidCallback onRemove;

  const _CartLineTile({required this.line, required this.onEditPrice, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final item = line.item;
    final sc = context.semanticColors;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: PurityPalette.of(context, item.karat).surface, borderRadius: BorderRadius.circular(8)),
            child: Text(
              AppFormat.karat(item.karat),
              style: AppTextStyles.numericSmall.copyWith(color: PurityPalette.of(context, item.karat).text, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.description, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
                Text(AppFormat.grams(item.weightGrams), style: AppTextStyles.numericSmall.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              InkWell(
                onTap: onEditPrice,
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  children: [
                    Text(AppFormat.peso(line.priceCentavos), style: AppTextStyles.numericMedium),
                    const SizedBox(width: 2),
                    const Icon(Icons.edit_outlined, size: 14, color: AppColors.textSecondary),
                  ],
                ),
              ),
              InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded, size: 14, color: sc.danger),
                      const SizedBox(width: 2),
                      Text('Remove', style: AppTextStyles.caption.copyWith(color: sc.danger)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalBar extends StatelessWidget {
  final CartState cart;

  const _TotalBar({required this.cart});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.cardSurface,
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${cart.itemCount} item(s)',
                  style: AppTextStyles.bodyLarge.copyWith(color: AppColors.textSecondary),
                ),
                Text(AppFormat.peso(cart.totalCentavos), style: AppTextStyles.numericLarge),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CheckoutScreen()),
              ),
              child: const Text('Proceed to Checkout'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditPriceDialog extends StatefulWidget {
  final CartLine line;

  const _EditPriceDialog({required this.line});

  @override
  State<_EditPriceDialog> createState() => _EditPriceDialogState();
}

class _EditPriceDialogState extends State<_EditPriceDialog> {
  int? _price;

  @override
  void initState() {
    super.initState();
    _price = widget.line.priceCentavos;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.cardRadius)),
      title: Text('Edit price — ${widget.line.item.description}'),
      content: NumericInputField(
        label: 'Selling Price',
        kind: NumericInputKind.peso,
        initialValue: widget.line.priceCentavos / 100,
        autofocus: true,
        onChanged: (v) => setState(() => _price = v != null ? (v * 100).round() : null),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_price != null && _price! > 0) ? () => Navigator.of(context).pop(_price) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
