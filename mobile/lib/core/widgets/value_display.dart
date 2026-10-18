import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// Whether a figure was typed by staff or computed by the system. This
/// distinction recurs constantly (capital vs. selling price, gross vs. net,
/// loan amount vs. grams owed) and must read unmistakably at a glance —
/// never just a color difference.
enum FigureOrigin { entered, derived }

/// A read-only figure display that makes [FigureOrigin] visually obvious:
/// derived figures look like a calculated readout (dashed border, muted,
/// a function glyph); entered figures look like committed staff input
/// (solid border, bold, a pencil glyph).
class ValueDisplay extends StatelessWidget {
  final String label;
  final String value;
  final FigureOrigin origin;
  final Color? valueColor;

  const ValueDisplay({
    super.key,
    required this.label,
    required this.value,
    required this.origin,
    this.valueColor,
  });

  bool get _isDerived => origin == FigureOrigin.derived;

  @override
  Widget build(BuildContext context) {
    final color = valueColor ?? AppColors.textPrimary;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: _isDerived ? AppColors.surfaceDim : AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: _isDerived
            ? null
            : Border.all(color: AppColors.outline, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The label gets the whole top line, and the origin tag sits beside
          // the value instead: in a half-width box the two together were wider
          // than the space, and truncating "Remaining Grams" to "Remaining…"
          // loses exactly the word that tells the two boxes apart.
          Row(
            children: [
              Icon(
                _isDerived ? Icons.functions_rounded : Icons.edit_note_rounded,
                size: 13,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Expanded, not Flexible beside a Spacer — those two split the
              // spare width evenly and cut the figure itself in half.
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: AppTextStyles.numericMedium.copyWith(
                      color: color,
                      fontStyle: _isDerived ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 3),
                child: Text(
                  _isDerived ? 'CALC' : 'ENTERED',
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textDisabled,
                    fontSize: 9,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
