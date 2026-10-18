import 'package:flutter/material.dart';

import '../models/item.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';
import 'status_badges.dart';

/// Standard list tile for an inventory item: weight, karat, value, status.
/// Used across purchase, sell, and scrap tabs so items always read the same
/// way regardless of screen.
class InventoryItemTile extends StatelessWidget {
  final Item item;
  final VoidCallback? onTap;
  final bool showVerification;
  final Widget? trailing;

  const InventoryItemTile({
    super.key,
    required this.item,
    this.onTap,
    this.showVerification = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    // A lot drawn from, or a piece drawn out of one. Both carry a marker so a
    // split lot is never mistaken for a plain purchase in a long list.
    final isParentLot = item.hasPartitions;
    final isPartition = item.isPartitioned;
    // A fully drawn-down lot has nothing left to act on, so it recedes rather
    // than competing with live stock for attention.
    final muted = item.isExhausted;
    // Goods and scrap leave the shop by completely different routes — sold
    // over the counter, or melted down in a disposal batch — so the row
    // itself is tinted, not just tagged. Green for stock that will be resold,
    // red for material headed to the melt.
    final (typeTint, typeEdge) = switch (item.type) {
      ItemType.goods => (
        sc.buyGreen.withValues(alpha: 0.16),
        sc.buyGreen.withValues(alpha: 0.45),
      ),
      ItemType.scrap => (
        sc.danger.withValues(alpha: 0.13),
        sc.danger.withValues(alpha: 0.40),
      ),
      // Slate, not the pale silver swatch — it has to hold its own beside the
      // green and red rows.
      ItemType.silver => (
        AppColors.silverDark.withValues(alpha: 0.16),
        AppColors.silverDark.withValues(alpha: 0.50),
      ),
    };

    final radius = BorderRadius.circular(AppSpacing.cardRadius);

    return Opacity(
      opacity: muted ? 0.55 : 1,
      // Each row is its own bordered card with air around it. A flat tinted
      // strip separated by a hairline reads as one continuous block when two
      // items of the same type sit together — the gap and the edge are what
      // make "two records" legible at a glance.
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        // Ink rather than a Container so the tap ripple still paints over the
        // tint instead of being hidden behind it.
        child: Ink(
          decoration: BoxDecoration(
            color: typeTint,
            borderRadius: radius,
            border: Border.all(color: typeEdge),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm + 2,
              ),
              child: Row(
                children: [
                  // The piece itself leads the row — a photograph identifies
                  // stock far faster than a karat tag, and the karat has moved
                  // down to the badges where the record's other state lives.
                  if (item.hasPhoto)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppSpacing.inputRadius,
                      ),
                      child: Image.memory(
                        item.photo!,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      ),
                    )
                  else
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceDim,
                        borderRadius: BorderRadius.circular(
                          AppSpacing.inputRadius,
                        ),
                        border: Border.all(color: AppColors.outline),
                      ),
                      child: const Icon(
                        Icons.photo_camera_outlined,
                        size: 18,
                        color: AppColors.textDisabled,
                      ),
                    ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyLarge.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        // One truncatable line rather than a row of rigid
                        // pieces: the id, weight and badge together are wider
                        // than a phone row once a partitioned lot adds its
                        // "of" figure, and unconstrained they ran under the
                        // amount on the right.
                        Row(
                          children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: item.id,
                                      style: AppTextStyles.numericSmall.copyWith(
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '  ·  ',
                                      style: AppTextStyles.numericSmall.copyWith(
                                        color: AppColors.textDisabled,
                                      ),
                                    ),
                                    TextSpan(
                                      text: AppFormat.grams(
                                        isParentLot
                                            ? item.effectiveRemainingGrams
                                            : item.weightGrams,
                                      ),
                                      style: AppTextStyles.numericSmall.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    // What's left, then what it started as — a
                                    // partitioned lot is only readable when
                                    // both are on the row.
                                    if (isParentLot)
                                      TextSpan(
                                        text: ' of ${AppFormat.grams(item.effectiveOriginalGrams)}',
                                        style: AppTextStyles.numericSmall.copyWith(
                                          color: AppColors.textDisabled,
                                        ),
                                      ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            ItemTypeBadge(type: item.type),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            KaratBadge(karat: item.karat),
                            ItemStatusBadge(
                              status: item.itemStatus,
                              compact: true,
                            ),
                            if (isParentLot || isPartition)
                              PartitionBadge(isChild: isPartition),
                            if (showVerification)
                              VerificationStatusBadge(
                                status: item.verificationStatus,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (trailing != null)
                    trailing!
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          AppFormat.peso(
                            isParentLot
                                ? item.effectiveRemainingAmountCentavos
                                : item.capitalAmountCentavos,
                            whole: true,
                          ),
                          style: AppTextStyles.numericMedium.copyWith(
                            color: item.type.isSilver ? AppColors.silverDark : sc.gold,
                          ),
                        ),
                        if (isParentLot)
                          Text(
                            'of ${AppFormat.peso(item.effectiveOriginalAmountCentavos, whole: true)}',
                            style: AppTextStyles.numericSmall.copyWith(
                              color: AppColors.textDisabled,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
