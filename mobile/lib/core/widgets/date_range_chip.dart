import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';

/// A filter chip that opens the platform date-range picker — shared by any
/// list screen that filters by date (Purchase list, Cash ledger, …).
///
/// The clear "×" is its own tap target rather than decoration inside the
/// chip's own [InkWell]; when it wasn't, tapping it just reopened the picker
/// and the range could never actually be cleared.
class DateRangeChip extends StatelessWidget {
  final DateTimeRange? range;
  final ValueChanged<DateTimeRange?> onChanged;

  const DateRangeChip({super.key, required this.range, required this.onChanged});

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: range,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final active = range != null;
    final radius = BorderRadius.circular(AppSpacing.badgeRadius + 6);
    final label = active
        ? AppFormat.dateRangeShort(range!.start, range!.end)
        : 'Date range';
    final foreground = active ? AppColors.primaryBlue : AppColors.textSecondary;

    return Container(
      decoration: BoxDecoration(
        color: active ? AppColors.primaryBlue.withValues(alpha: 0.10) : AppColors.surfaceDim,
        borderRadius: radius,
        border: active ? Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.4)) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: radius,
            onTap: () => _pick(context),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.sm + 2,
                6,
                active ? AppSpacing.xs : AppSpacing.sm + 2,
                6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.calendar_today_rounded, size: 13, color: foreground),
                  const SizedBox(width: 5),
                  Text(label, style: AppTextStyles.labelSmall.copyWith(color: foreground)),
                ],
              ),
            ),
          ),
          if (active)
            InkWell(
              borderRadius: radius,
              onTap: () => onChanged(null),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(AppSpacing.xs, 7, AppSpacing.sm, 7),
                child: Icon(Icons.close_rounded, size: 15, color: AppColors.primaryBlue),
              ),
            ),
        ],
      ),
    );
  }
}
