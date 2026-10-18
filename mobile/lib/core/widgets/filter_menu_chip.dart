import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A filter chip that opens a popup menu of [values] plus an "All" option
/// that clears the filter (`onChanged(null)`).
///
/// Built on [PopupMenuButton], which has a well-known gotcha: internally it
/// treats a selected value of `null` identically to the menu being
/// dismissed without a choice, so `onSelected` silently never fires for a
/// null-valued item — tapping "All" would look like nothing happened. This
/// wraps every menu entry (including "All") in a non-null box so the two
/// cases are distinguishable, then unwraps before calling [onChanged].
class FilterMenuChip<T> extends StatelessWidget {
  final String label;
  final bool active;
  final String allLabel;
  final List<T> values;
  final String Function(T value) labelOf;
  final ValueChanged<T?> onChanged;

  const FilterMenuChip({
    super.key,
    required this.label,
    required this.active,
    required this.values,
    required this.labelOf,
    required this.onChanged,
    this.allLabel = 'All',
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_Option<T>>(
      itemBuilder: (_) => [
        PopupMenuItem(value: _Option<T>(null), child: Text(allLabel)),
        for (final v in values) PopupMenuItem(value: _Option<T>(v), child: Text(labelOf(v))),
      ],
      onSelected: (option) => onChanged(option.value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryBlue.withValues(alpha: 0.10) : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
          border: active ? Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.4)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppTextStyles.labelSmall.copyWith(
                color: active ? AppColors.primaryBlue : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 16, color: active ? AppColors.primaryBlue : AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Non-null wrapper so a "value of null" (All) is distinguishable from
/// [PopupMenuButton]'s own "dismissed without choosing" null.
class _Option<T> {
  final T? value;
  const _Option(this.value);
}
