import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/data/staff_directory.dart';
import '../../core/models/rate_change.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/record_activity.dart';
import '../../core/widgets/status_badges.dart';

/// One row of rate history: the price set, what it moved from, who set it
/// and when.
class RateChangeTile extends StatelessWidget {
  final RateChange change;

  /// Show which karat or fineness this is — needed in the combined history,
  /// redundant on a single rate's own page.
  final bool showPurity;

  const RateChangeTile({
    super.key,
    required this.change,
    this.showPurity = false,
  });

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final sc = context.semanticColors;
    final newest = repo.rateHistory(change.karat).firstOrNull;
    final isCurrentEntry = identical(newest, change);

    final delta = change.deltaCentavos;
    final Color color = change.restoredFrom != null
        ? AppColors.primaryBlue
        : change.isInitial
            ? AppColors.info
            : delta > 0
                ? sc.success
                : sc.danger;
    final IconData icon = change.restoredFrom != null
        ? Icons.restore_rounded
        : change.isInitial
            ? Icons.add_rounded
            : delta > 0
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded;
    final user = StaffDirectory.byId(change.userId);

    final String detail;
    if (change.restoredFrom != null) {
      detail = 'Applied rates from ${AppFormat.dateShort(change.restoredFrom!)}'
          ' · was ${AppFormat.peso(change.beforeCentavos!)}';
    } else if (change.isInitial) {
      detail = 'Rate first set';
    } else {
      detail = 'From ${AppFormat.peso(change.beforeCentavos!)}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (showPurity) KaratBadge(karat: change.karat),
                    Text(
                      AppFormat.peso(change.afterCentavos),
                      style: AppTextStyles.numericMedium.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (isCurrentEntry)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.primaryBlue.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                        ),
                        child: Text(
                          'CURRENT',
                          style: AppTextStyles.labelSmall.copyWith(color: AppColors.primaryBlue, fontSize: 10),
                        ),
                      ),
                  ],
                ),
                Text(
                  detail,
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (user != null) ...[
                      StaffAvatar(user: user, radius: 9),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        '${change.userName} · ${AppFormat.dateTimeShort(change.at)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!change.isInitial && delta != 0)
            Text(
              AppFormat.pesoSigned(delta),
              style: AppTextStyles.numericSmall.copyWith(color: delta > 0 ? sc.success : sc.danger, fontWeight: FontWeight.w700),
            ),
        ],
      ),
    );
  }
}
