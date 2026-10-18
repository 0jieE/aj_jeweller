import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// Placeholder body for a tab whose full workflow hasn't been built yet.
/// Used only during scaffolding — each of these gets replaced by a real
/// screen in a later prompt.
class ComingSoon extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const ComingSoon({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.surfaceDim,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 30, color: AppColors.primaryBlue),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: AppTextStyles.headlineMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
              ),
              child: Text(
                'Coming in a later prompt',
                style: AppTextStyles.labelSmall.copyWith(color: AppColors.textDisabled),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
