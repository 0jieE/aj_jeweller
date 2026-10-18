import 'package:flutter/material.dart';

import '../models/gold_rate.dart';
import '../models/item.dart';
import '../models/item_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';

/// The app has three unrelated status systems. Each gets a distinct visual
/// language on purpose — a filled pill, a stamp-like outline, and a step
/// tracker — so staff never mistake one kind of "pending" for another.

// ---------------------------------------------------------------------------
// 1. Item status — filled pill with icon.
// ---------------------------------------------------------------------------
class ItemStatusBadge extends StatelessWidget {
  final ItemStatus status;
  final bool compact;

  const ItemStatusBadge({super.key, required this.status, this.compact = false});

  Color _color(BuildContext context) {
    final sc = context.semanticColors;
    switch (status) {
      case ItemStatus.pending:
        return AppColors.neutral;
      case ItemStatus.listed:
        return AppColors.primaryBlue;
      case ItemStatus.sold:
        return sc.success;
      case ItemStatus.reserved:
        return sc.info;
      case ItemStatus.forDisposal:
        return sc.warning;
      case ItemStatus.disposed:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.sm : AppSpacing.sm + 2,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: compact ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: AppTextStyles.labelSmall.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Verification status — stamp-like outlined badge, deliberately different
//    from the filled pill above (dashed border while waiting, solid seal
//    once verified).
// ---------------------------------------------------------------------------
class VerificationStatusBadge extends StatelessWidget {
  final VerificationStatus status;

  const VerificationStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    late final Color color;
    late final IconData icon;
    switch (status) {
      case VerificationStatus.awaitingVerification:
        color = sc.warning;
        icon = Icons.schedule_rounded;
      case VerificationStatus.verified:
        color = sc.success;
        icon = Icons.verified_rounded;
      case VerificationStatus.returnedForCorrection:
        color = sc.danger;
        icon = Icons.flag_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        border: Border.all(
          color: color,
          width: 1.4,
          style: BorderStyle.solid,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: AppTextStyles.labelSmall.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Commitment status — a 3-step tracker, since this status always
//    progresses in a fixed sequence rather than sitting in one state.
// ---------------------------------------------------------------------------
class CommitmentStatusTracker extends StatelessWidget {
  final CommitmentStatus status;

  const CommitmentStatusTracker({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final steps = CommitmentStatus.values;
    final currentIndex = status.stepIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Fixed width so the connector lines' Expanded always has something
        // bounded to fill — this widget gets placed as a non-flex child of
        // a Row (e.g. a card header) as often as inside one with room to
        // stretch, and Expanded needs a bounded parent either way.
        SizedBox(
          width: 96,
          child: Row(
            children: [
              for (int i = 0; i < steps.length; i++) ...[
                _StepDot(filled: i <= currentIndex, isCurrent: i == currentIndex),
                if (i != steps.length - 1)
                  Expanded(
                    child: Container(
                      height: 2,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      color: i < currentIndex
                          ? AppColors.primaryBlue
                          : AppColors.outline,
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          status.label,
          style: AppTextStyles.labelSmall.copyWith(color: AppColors.primaryBlue),
        ),
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  final bool filled;
  final bool isCurrent;

  const _StepDot({required this.filled, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: isCurrent ? 12 : 10,
      height: isCurrent ? 12 : 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? AppColors.primaryBlue : Colors.transparent,
        border: Border.all(
          color: filled ? AppColors.primaryBlue : AppColors.outline,
          width: 1.6,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Partition marker — deliberately NOT a fourth status system. It states a
//    structural fact about the lot (it has been drawn from, or it was drawn
//    out of another lot), so it reads as a quiet tag rather than a pill and
//    never competes with the item status beside it.
// ---------------------------------------------------------------------------
class PartitionBadge extends StatelessWidget {
  /// True when this item is itself a piece drawn out of a bigger lot, false
  /// when it's the lot that has been drawn from.
  final bool isChild;

  const PartitionBadge({super.key, required this.isChild});

  @override
  Widget build(BuildContext context) {
    const color = AppColors.neutral;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isChild ? Icons.subdirectory_arrow_right_rounded : Icons.call_split_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            isChild ? 'Partition' : 'Partitioned',
            style: AppTextStyles.labelSmall.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Item type — Goods vs Scrap, the one distinction that decides which way a
//    piece leaves the shop (resold over the counter, or melted in a disposal
//    batch). Colour-coded because it is scanned far more often than it is
//    read.
//
//    Neither colour is gold or amber: gold is reserved app-wide for actual
//    gold data (karat tags, rates, weights), and AppColors.warning is the
//    same hue, so a type tag in either would read as a gold figure. Buy-green
//    and sell-coral are likewise spoken for by transaction direction.
// ---------------------------------------------------------------------------
class ItemTypeBadge extends StatelessWidget {
  final ItemType type;

  const ItemTypeBadge({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (type) {
      ItemType.goods => (AppColors.info, Icons.sell_outlined),
      ItemType.scrap => (AppColors.neutral, Icons.local_fire_department_outlined),
      ItemType.silver => (AppColors.silverDark, Icons.toll_outlined),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      // Solid rather than washed out, so the tag still reads against the
      // tinted row behind it.
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            type.label,
            style: AppTextStyles.labelSmall.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 6. Karat — the purity of the piece, in the gold colours every other gold
//    figure uses. It sits among the badges rather than leading the row,
//    because a photograph identifies a piece faster than its karat does; the
//    karat still matters, just as one fact among several rather than the
//    headline.
// ---------------------------------------------------------------------------
class KaratBadge extends StatelessWidget {
  final int karat;

  const KaratBadge({super.key, required this.karat});

  @override
  Widget build(BuildContext context) {
    final palette = PurityPalette.of(context, karat);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        border: Border.all(color: palette.edge),
      ),
      child: Text(
        AppFormat.karat(karat),
        style: AppTextStyles.labelSmall.copyWith(
          color: palette.text,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Gold colours for a karat, silver-grey for a fineness — gold stays
/// reserved for gold, so a silver piece's purity must never be painted in it.
class PurityPalette {
  final Color text;
  final Color surface;
  final Color edge;

  const PurityPalette._(this.text, this.surface, this.edge);

  factory PurityPalette.of(BuildContext context, int karat) {
    final sc = context.semanticColors;
    return isSilverPurity(karat)
        ? PurityPalette._(AppColors.silverDark, sc.silverSurface, sc.silver.withValues(alpha: 0.8))
        : PurityPalette._(sc.goldDark, sc.goldSurface, sc.goldLight.withValues(alpha: 0.8));
  }
}
