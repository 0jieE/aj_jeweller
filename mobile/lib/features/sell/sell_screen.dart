import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/state/app_state.dart';
import '../../core/state/cart_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import 'browse_goods_screen.dart';
import 'cart_bar.dart';
import 'order_summary_screen.dart';
import 'sale_verification_queue_screen.dart';
import 'sold_goods_screen.dart';

enum _SellView { browse, silver, sold, queue }

/// Root of the Sell tab. Everyone can browse sellable goods; the "Verify &
/// Receive" segment (a Cashier's payment queue) only shows for roles that
/// can move cash, and the persistent cart bar only shows for roles that can
/// build orders — strict separation of duties, driven by [AppState].
class SellScreen extends StatefulWidget {
  const SellScreen({super.key});

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  _SellView? _view;

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AppState>().role;
    final canQueue = role.canMoveCash;
    final canSell = role.canMakeSales;
    final cart = context.watch<CartState>();

    final view = _view ?? (canQueue && !canSell ? _SellView.queue : _SellView.browse);

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
            child: _ViewToggle(
              view: view,
              showQueue: canQueue,
              onChanged: (v) => setState(() => _view = v),
            ),
          ),
          Expanded(
            child: switch (view) {
              _SellView.browse => const BrowseGoodsScreen(key: ValueKey('gold')),
              _SellView.silver => const BrowseGoodsScreen(key: ValueKey('silver'), silver: true),
              _SellView.sold => const SoldGoodsScreen(),
              _SellView.queue => const SaleVerificationQueueScreen(),
            },
          ),
        ],
      ),
      bottomNavigationBar: (canSell && (view == _SellView.browse || view == _SellView.silver) && !cart.isEmpty)
          ? CartBar(
              cart: cart,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OrderSummaryScreen()),
              ),
            )
          : null,
    );
  }
}

class _ViewToggle extends StatelessWidget {
  final _SellView view;

  /// The Cashier's payment queue is role-gated; the other two segments are
  /// browsing and always available.
  final bool showQueue;
  final ValueChanged<_SellView> onChanged;

  const _ViewToggle({required this.view, required this.showQueue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Row(
        children: [
          Expanded(child: _segment(context, 'Gold', _SellView.browse)),
          Expanded(child: _segment(context, 'Silver', _SellView.silver)),
          Expanded(child: _segment(context, 'Sold', _SellView.sold)),
          if (showQueue) Expanded(child: _segment(context, 'Verify', _SellView.queue)),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, _SellView value) {
    final selected = view == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? AppColors.cardSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius - 2),
          boxShadow: selected
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyles.bodyMedium.copyWith(
            color: selected ? AppColors.primaryBlue : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
