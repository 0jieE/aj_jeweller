import 'package:flutter/material.dart';

import '../models/item.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';
import 'status_badges.dart';

/// One piece of stock, as a card: the photograph first, then what it is and
/// what it is worth.
///
/// Stock is looked at, not read. A row works on a phone because there is only
/// room for one at a time, but a shelf of gold in a wide window wants to be
/// seen the way the counter sees it — pictures side by side, the way any shop
/// catalogue is laid out. The same card serves both; only how many fit across
/// changes.
class InventoryItemCard extends StatelessWidget {
  final Item item;
  final VoidCallback? onTap;
  final bool showVerification;

  const InventoryItemCard({
    super.key,
    required this.item,
    this.onTap,
    this.showVerification = false,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final isParentLot = item.hasPartitions;
    // A lot with nothing left recedes rather than competing with live stock.
    final muted = item.isExhausted;

    // Goods and scrap leave the shop by different routes, so the card is
    // tinted rather than only tagged: green for stock to be resold, red for
    // material headed to the melt, slate for silver.
    final (tint, edge) = switch (item.type) {
      ItemType.goods => (sc.buyGreen.withValues(alpha: 0.14), sc.buyGreen.withValues(alpha: 0.42)),
      ItemType.scrap => (sc.danger.withValues(alpha: 0.11), sc.danger.withValues(alpha: 0.38)),
      ItemType.silver => (
          AppColors.silverDark.withValues(alpha: 0.14),
          AppColors.silverDark.withValues(alpha: 0.46),
        ),
    };
    final radius = BorderRadius.circular(AppSpacing.cardRadius);

    return Opacity(
      opacity: muted ? 0.55 : 1,
      child: Ink(
        decoration: BoxDecoration(color: tint, borderRadius: radius, border: Border.all(color: edge)),
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Photo(item: item, radius: radius, showVerification: showVerification),
              // Whatever height is left after the photograph, and no more:
              // the description gives way before the price does.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 6, AppSpacing.sm, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          item.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // The money is what the eye goes to on a shelf.
                      Text(
                        AppFormat.peso(
                          isParentLot ? item.effectiveRemainingAmountCentavos : item.capitalAmountCentavos,
                          whole: true,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.numericMedium.copyWith(
                          color: item.type.isSilver ? AppColors.silverDark : sc.gold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${item.id}  ·  ${AppFormat.grams(isParentLot ? item.effectiveRemainingGrams : item.weightGrams)}'
                        '${isParentLot ? ' of ${AppFormat.grams(item.effectiveOriginalGrams)}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.numericSmall.copyWith(color: AppColors.textSecondary),
                      ),
                      const Spacer(),
                      // Status last, small: it qualifies the piece rather
                      // than announcing it. Only one badge — a card is too
                      // narrow for a row of them, and the rest are on the
                      // photograph above.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ItemStatusBadge(status: item.itemStatus, compact: true),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The photograph, square, with the karat on it the way a price tag sits on
/// the piece itself.
class _Photo extends StatelessWidget {
  final Item item;
  final BorderRadius radius;
  final bool showVerification;

  const _Photo({required this.item, required this.radius, required this.showVerification});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.only(topLeft: radius.topLeft, topRight: radius.topRight),
            child: item.hasPhoto
                ? Image.memory(item.photo!, fit: BoxFit.cover)
                : Container(
                    color: AppColors.surfaceDim,
                    alignment: Alignment.center,
                    child: const Icon(Icons.photo_camera_outlined, size: 28, color: AppColors.textDisabled),
                  ),
          ),
          Positioned(
            top: AppSpacing.xs,
            left: AppSpacing.xs,
            child: KaratBadge(karat: item.karat),
          ),
          Positioned(
            top: AppSpacing.xs,
            right: AppSpacing.xs,
            child: ItemTypeBadge(type: item.type),
          ),
          if (showVerification)
            Positioned(
              bottom: AppSpacing.xs,
              left: AppSpacing.xs,
              child: VerificationStatusBadge(status: item.verificationStatus),
            ),
          // A split lot, or a piece drawn out of one — a structural fact, so
          // it sits on the piece rather than among the words below.
          if (item.hasPartitions || item.isPartitioned)
            Positioned(
              bottom: AppSpacing.xs,
              right: AppSpacing.xs,
              child: PartitionBadge(isChild: item.isPartitioned),
            ),
        ],
      ),
    );
  }
}

/// Stock laid out as cards: two across a phone, as many as fit on a desktop.
///
/// The card's width is what is fixed, not the number of columns — so the same
/// list reads the same whether it is a phone in the shop or a monitor in the
/// back office, with more of it visible at once.
class InventoryGrid extends StatelessWidget {
  final List<Item> items;
  final void Function(Item item)? onTap;
  final bool showVerification;
  final EdgeInsetsGeometry padding;

  const InventoryGrid({
    super.key,
    required this.items,
    this.onTap,
    this.showVerification = false,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.sm,
      AppSpacing.sm,
      AppSpacing.sm,
      AppSpacing.xxl,
    ),
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // A phone fits two; a wide window keeps the same card and simply
        // shows more of them.
        maxCrossAxisExtent: 220,
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
        // The square photograph, plus room for two lines of description, the
        // amount, the figures and a badge.
        childAspectRatio: 0.58,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return InventoryItemCard(
          item: item,
          showVerification: showVerification,
          onTap: onTap == null ? null : () => onTap!(item),
        );
      },
    );
  }
}
