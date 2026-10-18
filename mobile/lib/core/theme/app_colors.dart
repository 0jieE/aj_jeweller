import 'package:flutter/material.dart';

/// Raw color palette. Prefer [AppSemanticColors] or [ColorScheme] in widgets
/// — reach for these constants only when building those.
class AppColors {
  AppColors._();

  // Primary blue — trust, financial credibility. Deliberately deep, not a
  // washed-out Material default.
  static const Color primaryBlue = Color(0xFF0F3D73);
  static const Color primaryBlueLight = Color(0xFF3868A0);
  static const Color primaryBlueDark = Color(0xFF08284F);
  static const Color accentBlue = Color(0xFF1E88E5);

  static const Color surface = Color(0xFFF7F9FC);
  static const Color surfaceDim = Color(0xFFEDF1F7);
  static const Color cardSurface = Color(0xFFFFFFFF);
  static const Color outline = Color(0xFFD7DEE8);

  static const Color textPrimary = Color(0xFF14202E);
  static const Color textSecondary = Color(0xFF54626F);
  static const Color textDisabled = Color(0xFF9AA6B2);

  // Gold — reserved EXCLUSIVELY for actual gold data: karat tags, gold
  // rates, gold weights/values. Never use as interface chrome or decoration.
  static const Color gold = Color(0xFFB8860B);
  static const Color goldLight = Color(0xFFE8C158);
  static const Color goldDark = Color(0xFF7A5A08);
  static const Color goldSurface = Color(0xFFFBF2DC);

  // Silver — for silver items, kept visually separate from gold.
  static const Color silver = Color(0xFF8A94A6);
  static const Color silverSurface = Color(0xFFEFF1F4);
  // Dark enough to read as text and as a row tint, where [silver] washes out.
  static const Color silverDark = Color(0xFF4F5B6D);

  // Transaction-direction colors.
  static const Color buyGreen = Color(0xFF2E7D46);
  static const Color buyGreenSurface = Color(0xFFE3F3E8);
  static const Color sellCoral = Color(0xFFC1602F);
  static const Color sellCoralSurface = Color(0xFFFBEAE0);

  // Status colors.
  static const Color success = Color(0xFF2E7D46);
  static const Color warning = Color(0xFFB8860B);
  static const Color danger = Color(0xFFB3261E);
  static const Color info = Color(0xFF1E88E5);
  static const Color neutral = Color(0xFF6B7684);
}

/// Semantic colors that don't map cleanly onto [ColorScheme] roles —
/// gold/silver product data, buy/sell direction, and status hues.
///
/// Access via `Theme.of(context).extension<AppSemanticColors>()!`.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  final Color gold;
  final Color goldLight;
  final Color goldDark;
  final Color goldSurface;

  final Color silver;
  final Color silverSurface;

  final Color buyGreen;
  final Color buyGreenSurface;
  final Color sellCoral;
  final Color sellCoralSurface;

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color neutral;

  const AppSemanticColors({
    required this.gold,
    required this.goldLight,
    required this.goldDark,
    required this.goldSurface,
    required this.silver,
    required this.silverSurface,
    required this.buyGreen,
    required this.buyGreenSurface,
    required this.sellCoral,
    required this.sellCoralSurface,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.neutral,
  });

  static const AppSemanticColors standard = AppSemanticColors(
    gold: AppColors.gold,
    goldLight: AppColors.goldLight,
    goldDark: AppColors.goldDark,
    goldSurface: AppColors.goldSurface,
    silver: AppColors.silver,
    silverSurface: AppColors.silverSurface,
    buyGreen: AppColors.buyGreen,
    buyGreenSurface: AppColors.buyGreenSurface,
    sellCoral: AppColors.sellCoral,
    sellCoralSurface: AppColors.sellCoralSurface,
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
    info: AppColors.info,
    neutral: AppColors.neutral,
  );

  @override
  AppSemanticColors copyWith({
    Color? gold,
    Color? goldLight,
    Color? goldDark,
    Color? goldSurface,
    Color? silver,
    Color? silverSurface,
    Color? buyGreen,
    Color? buyGreenSurface,
    Color? sellCoral,
    Color? sellCoralSurface,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? neutral,
  }) {
    return AppSemanticColors(
      gold: gold ?? this.gold,
      goldLight: goldLight ?? this.goldLight,
      goldDark: goldDark ?? this.goldDark,
      goldSurface: goldSurface ?? this.goldSurface,
      silver: silver ?? this.silver,
      silverSurface: silverSurface ?? this.silverSurface,
      buyGreen: buyGreen ?? this.buyGreen,
      buyGreenSurface: buyGreenSurface ?? this.buyGreenSurface,
      sellCoral: sellCoral ?? this.sellCoral,
      sellCoralSurface: sellCoralSurface ?? this.sellCoralSurface,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      neutral: neutral ?? this.neutral,
    );
  }

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      gold: Color.lerp(gold, other.gold, t)!,
      goldLight: Color.lerp(goldLight, other.goldLight, t)!,
      goldDark: Color.lerp(goldDark, other.goldDark, t)!,
      goldSurface: Color.lerp(goldSurface, other.goldSurface, t)!,
      silver: Color.lerp(silver, other.silver, t)!,
      silverSurface: Color.lerp(silverSurface, other.silverSurface, t)!,
      buyGreen: Color.lerp(buyGreen, other.buyGreen, t)!,
      buyGreenSurface: Color.lerp(buyGreenSurface, other.buyGreenSurface, t)!,
      sellCoral: Color.lerp(sellCoral, other.sellCoral, t)!,
      sellCoralSurface:
          Color.lerp(sellCoralSurface, other.sellCoralSurface, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
    );
  }
}

/// Convenience accessor: `context.semanticColors.gold`.
extension AppSemanticColorsX on BuildContext {
  AppSemanticColors get semanticColors =>
      Theme.of(this).extension<AppSemanticColors>() ??
      AppSemanticColors.standard;
}
