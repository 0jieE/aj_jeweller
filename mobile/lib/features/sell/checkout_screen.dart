import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/customer.dart';
import '../../core/models/sale.dart';
import '../../core/state/app_state.dart';
import '../../core/state/cart_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_fields.dart';
import '../../core/widgets/formatters.dart';
import '../../core/navigation/layout.dart';

/// Confirms the order, captures who it's for, and hands it to the Cashier.
/// The rep's job ends here — nothing on this screen implies payment has
/// been taken.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  late final TextEditingController _noteController;
  late CustomerDetails _customer;

  /// The rep's read on how the customer means to settle. The Cashier enters
  /// the amounts that actually arrive, so this is intent, not a commitment.
  bool _expectsBank = false;

  @override
  void initState() {
    super.initState();
    final cart = context.read<CartState>();
    _customer = CustomerDetails(name: cart.customerName);
    _noteController = TextEditingController(text: cart.note);
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool get _isValid => _customer.name.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: FormPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _OrderRecap(cart: cart),
            const SizedBox(height: AppSpacing.md),
            Text('Customer', style: AppTextStyles.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            CustomerFields(
              initial: _customer,
              onChanged: (details) => setState(() => _customer = details),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
              maxLines: 2,
            ),
            const SizedBox(height: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Customer intends to pay by',
                  style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 6),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Cash')),
                    ButtonSegment(value: true, label: Text('Bank transfer')),
                  ],
                  selected: {_expectsBank},
                  onSelectionChanged: (s) => setState(() => _expectsBank = s.first),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'The Cashier records what actually arrives, and can split it '
                  'between cash and bank.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'This sends the order to the Cashier. Payment has not been received yet.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton(
              onPressed: _isValid ? () => _submit(context, cart) : null,
              child: Text(cart.editingSaleId != null ? 'Resubmit to Cashier' : 'Send to Cashier'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit(BuildContext context, CartState cart) {
    final repo = context.read<AppRepository>();
    final appState = context.read<AppState>();
    final lineItems = [
      for (final line in cart.lines)
        SaleLineItem(
          item: line.item,
          negotiatedPriceCentavos: line.priceCentavos,
          finalGrams: line.finalGrams,
        ),
    ];
    final note = _noteController.text.trim().isEmpty ? null : _noteController.text.trim();
    // Intent only — whichever way the rep expects it, the whole amount is
    // staged against that tender and the Cashier corrects it on receipt.
    final intended = _expectsBank
        ? SalePayment.bank(cart.totalCentavos)
        : SalePayment.cash(cart.totalCentavos);

    if (cart.editingSaleId != null) {
      repo.resubmitSale(
        actor: appState.currentUser,
        cart.editingSaleId!,
        lineItems: lineItems,
        customer: _customer,
        note: note,
        payment: intended,
      );
    } else {
      repo.checkoutSale(
        actor: appState.currentUser,
        lineItems: lineItems,
        customer: _customer,
        note: note,
        payment: intended,
        branch: cart.branch!,
        submittedByRole: appState.role,
      );
    }
    cart.clearAfterCheckout();
    _showSentDialog(context);
  }

  void _showSentDialog(BuildContext context) {
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
        title: const Text('Sent — awaiting payment', textAlign: TextAlign.center),
        content: Text(
          'Payment has NOT been received. This order now sits in the Cashier\'s '
          'queue until payment is confirmed and the items are handed over.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _OrderRecap extends StatelessWidget {
  final CartState cart;

  const _OrderRecap({required this.cart});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${cart.itemCount} item(s)', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          for (final line in cart.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      line.item.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMedium,
                    ),
                  ),
                  Text(AppFormat.peso(line.priceCentavos), style: AppTextStyles.numericSmall),
                ],
              ),
            ),
          const Divider(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: AppTextStyles.titleMedium),
              Text(AppFormat.peso(cart.totalCentavos), style: AppTextStyles.numericLarge.copyWith(color: AppColors.primaryBlue)),
            ],
          ),
        ],
      ),
    );
  }
}
