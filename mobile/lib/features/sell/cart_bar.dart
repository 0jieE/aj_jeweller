import 'package:flutter/material.dart';

import '../../core/state/cart_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';

/// The persistent "N items · ₱total" strip that stays visible while
/// browsing so the rep never loses track of the order in progress. Tapping
/// it opens the full cart.
class CartBar extends StatelessWidget {
  final CartState cart;
  final VoidCallback onTap;

  const CartBar({super.key, required this.cart, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(AppSpacing.sm),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
          decoration: BoxDecoration(
            color: AppColors.primaryBlue,
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 10, offset: const Offset(0, 3)),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.shopping_bag_outlined, color: Colors.white, size: 18),
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                        alignment: Alignment.center,
                        child: Text(
                          '${cart.itemCount}',
                          style: AppTextStyles.labelSmall.copyWith(color: AppColors.primaryBlue, fontSize: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cart.editingSaleId != null ? 'Fixing returned order' : 'Current order',
                      style: AppTextStyles.caption.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                    ),
                    Text(
                      AppFormat.peso(cart.totalCentavos),
                      style: AppTextStyles.numericMedium.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
              const Text('View Order', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right_rounded, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}
