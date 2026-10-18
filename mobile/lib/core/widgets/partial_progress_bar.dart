import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';

/// Progress toward a partial amount — loan repayment, down payments, a
/// partitioned lot drawn down over time. Shows both the bar and the
/// underlying peso figures so the fraction is never ambiguous.
class PartialProgressBar extends StatelessWidget {
  final int amountSoFarCentavos;
  final int targetAmountCentavos;
  final String label;
  final Color? color;

  const PartialProgressBar({
    super.key,
    required this.amountSoFarCentavos,
    required this.targetAmountCentavos,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final progress = targetAmountCentavos == 0
        ? 0.0
        : (amountSoFarCentavos / targetAmountCentavos).clamp(0.0, 1.0);
    final barColor = color ?? AppColors.primaryBlue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: AppTextStyles.labelSmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '${(progress * 100).toStringAsFixed(0)}%',
              style: AppTextStyles.numericSmall.copyWith(color: barColor),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSpacing.xs),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: AppColors.surfaceDim,
            valueColor: AlwaysStoppedAnimation(barColor),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${AppFormat.peso(amountSoFarCentavos, whole: true)} of '
          '${AppFormat.peso(targetAmountCentavos, whole: true)}',
          style: AppTextStyles.numericSmall.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
