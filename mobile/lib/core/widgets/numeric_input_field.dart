import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// The kind of quantity a [NumericInputField] captures — drives the prefix,
/// suffix, and decimal precision so callers don't have to wire it up by hand.
enum NumericInputKind { peso, grams, plain }

/// Groups digits with thousands separators as the user types, so a six-figure
/// peso amount reads "1,000,000.00" instead of an unscannable run of digits.
///
/// Counter staff key these in while a customer waits and read them back to
/// confirm — an ungrouped "1000000" is exactly where a misplaced zero hides.
/// The caret is repositioned after formatting so inserting a digit mid-number
/// doesn't throw the cursor to the end.
class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  /// How many digits are allowed after the decimal point.
  final int decimalRange;

  ThousandsSeparatorInputFormatter({required this.decimalRange});

  static final NumberFormat _grouping = NumberFormat('#,##0', 'en_PH');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.replaceAll(',', '');
    if (raw.isEmpty) return const TextEditingValue();

    // Reject anything that isn't digits with at most one dot — the
    // digits-and-one-dot gate the old FilteringTextInputFormatter provided.
    if (!RegExp(r'^\d*\.?\d*$').hasMatch(raw)) return oldValue;

    final dotIndex = raw.indexOf('.');
    final intPart = dotIndex == -1 ? raw : raw.substring(0, dotIndex);
    final decPart = dotIndex == -1 ? null : raw.substring(dotIndex + 1);
    if (decPart != null && decPart.length > decimalRange) return oldValue;
    // int.parse below would overflow on an absurd paste; nothing this shop
    // records is anywhere near 15 digits.
    if (intPart.length > 15) return oldValue;

    final groupedInt = intPart.isEmpty ? '' : _grouping.format(int.parse(intPart));
    final formatted = decPart == null ? groupedInt : '$groupedInt.$decPart';

    // Keep the caret after the same count of non-separator characters it sat
    // after before regrouping shifted the commas around.
    final rawEnd = newValue.selection.end;
    final end = rawEnd < 0 ? newValue.text.length : rawEnd.clamp(0, newValue.text.length);
    final keptBeforeCaret = newValue.text.substring(0, end).replaceAll(',', '').length;

    var caret = 0;
    var seen = 0;
    while (caret < formatted.length && seen < keptBeforeCaret) {
      if (formatted[caret] != ',') seen++;
      caret++;
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: caret),
    );
  }
}

/// A numeric field purpose-built for fast, accurate counter entry —
/// large tabular digits, a locked-down keyboard, thousands separators, and a
/// clear unit — instead of a generic [TextField] that happens to take numbers.
///
/// Values are reported as doubles via [onChanged]; callers dealing in
/// centavos should multiply peso values by 100 and round.
class NumericInputField extends StatefulWidget {
  final String label;
  final NumericInputKind kind;
  final double? initialValue;
  final ValueChanged<double?> onChanged;
  final String? helperText;
  final bool autofocus;
  final FocusNode? focusNode;

  const NumericInputField({
    super.key,
    required this.label,
    required this.onChanged,
    this.kind = NumericInputKind.plain,
    this.initialValue,
    this.helperText,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<NumericInputField> createState() => _NumericInputFieldState();
}

class _NumericInputFieldState extends State<NumericInputField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialValue != null
          ? _stripTrailingZeros(widget.initialValue!)
          : '',
    );
  }

  int get _decimalRange =>
      widget.kind == NumericInputKind.peso ? 2 : 3;

  /// Grouped for display, then trimmed of the trailing zeros the fixed-decimal
  /// format pads on, so an initial 4613.00 seeds the field as "4,613".
  String _stripTrailingZeros(double value) {
    var text = NumberFormat(
      '#,##0.${'0' * _decimalRange}',
      'en_PH',
    ).format(value);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      text = text.replaceFirst(RegExp(r'\.$'), '');
    }
    return text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _prefixText {
    switch (widget.kind) {
      case NumericInputKind.peso:
        return '₱ ';
      case NumericInputKind.grams:
      case NumericInputKind.plain:
        return null;
    }
  }

  String? get _suffixText {
    switch (widget.kind) {
      case NumericInputKind.grams:
        return 'g';
      case NumericInputKind.peso:
      case NumericInputKind.plain:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          inputFormatters: [
            ThousandsSeparatorInputFormatter(decimalRange: _decimalRange),
          ],
          style: AppTextStyles.numericLarge.copyWith(
            color: AppColors.textPrimary,
            fontSize: 22,
          ),
          decoration: InputDecoration(
            isDense: true,
            prefixText: _prefixText,
            prefixStyle: AppTextStyles.numericLarge.copyWith(
              fontSize: 22,
              color: AppColors.textSecondary,
            ),
            suffixText: _suffixText,
            suffixStyle: AppTextStyles.titleMedium.copyWith(
              color: AppColors.textSecondary,
            ),
            helperText: widget.helperText,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
          ),
          // Commas are display-only — every caller still receives a plain
          // double it can convert to centavos.
          onChanged: (text) {
            widget.onChanged(double.tryParse(text.replaceAll(',', '')));
          },
        ),
      ],
    );
  }
}
