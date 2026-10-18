import 'package:flutter/material.dart';

/// Type scale plus the numeric styles used for every peso amount, gram
/// weight, and rate.
///
/// Numeric styles carry [FontFeature.tabularFigures] so columns of figures
/// align like a printed receipt — a misread digit here is real money.
class AppTextStyles {
  AppTextStyles._();

  static const String fontFamily = 'Roboto';

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  // Headings / body copy.
  static const TextStyle headlineLarge = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );
  static const TextStyle headlineMedium = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
  );
  static const TextStyle titleLarge = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle titleMedium = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle bodyLarge = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle bodyMedium = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle labelSmall = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
  );

  // Numeric styles — always tabular. Use these for every ₱ amount, gram
  // weight, and rate, never a plain body style.
  static const TextStyle numericLarge = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    fontFeatures: _tabular,
    letterSpacing: -0.3,
  );
  static const TextStyle numericMedium = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    fontFeatures: _tabular,
  );
  static const TextStyle numericBody = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    fontFeatures: _tabular,
  );
  static const TextStyle numericSmall = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    fontFeatures: _tabular,
  );
}
