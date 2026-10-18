// Unit tests for the thousands-separator formatter behind every numeric
// entry field — grouping, decimal limits, and caret handling.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/widgets/numeric_input_field.dart';

/// Simulates typing [next] into a field currently holding [current], with the
/// caret at the end of the new text (what a normal keystroke looks like).
TextEditingValue _type(ThousandsSeparatorInputFormatter f, String current, String next) {
  return f.formatEditUpdate(
    TextEditingValue(text: current, selection: TextSelection.collapsed(offset: current.length)),
    TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length)),
  );
}

void main() {
  final peso = ThousandsSeparatorInputFormatter(decimalRange: 2);
  final grams = ThousandsSeparatorInputFormatter(decimalRange: 3);

  group('grouping', () {
    test('inserts separators once the number passes three digits', () {
      expect(_type(peso, '100', '1000').text, '1,000');
      expect(_type(peso, '100000', '1000000').text, '1,000,000');
    });

    test('groups only the integer part, leaving decimals alone', () {
      expect(_type(peso, '1000000.', '1000000.5').text, '1,000,000.5');
      expect(_type(peso, '1000000.5', '1000000.50').text, '1,000,000.50');
    });

    test('short numbers and zero are left ungrouped', () {
      expect(_type(peso, '4', '46').text, '46');
      expect(_type(peso, '0.', '0.5').text, '0.5');
    });

    test('an emptied field clears rather than throwing', () {
      expect(_type(peso, '1,000', '').text, '');
    });
  });

  group('decimal limits', () {
    test('a peso field refuses a third decimal place', () {
      final result = _type(peso, '10.12', '10.123');
      expect(result.text, '10.12', reason: 'the rejected keystroke leaves the old value');
    });

    test('a grams field accepts three decimals but not four', () {
      expect(_type(grams, '10.12', '10.123').text, '10.123');
      expect(_type(grams, '10.123', '10.1234').text, '10.123');
    });

    test('letters and a second dot are rejected', () {
      expect(_type(peso, '10', '10a').text, '10');
      expect(_type(peso, '10.5', '10.5.').text, '10.5');
    });
  });

  group('caret', () {
    test('stays after the digit just typed, not at the end of the string', () {
      // Typing "4" into "1,000" right before the final 0 -> "10,040" here the
      // caret must land after the inserted 4, i.e. offset 5.
      final result = peso.formatEditUpdate(
        const TextEditingValue(text: '1,000', selection: TextSelection.collapsed(offset: 4)),
        const TextEditingValue(text: '1,040', selection: TextSelection.collapsed(offset: 5)),
      );
      expect(result.text, '1,040');
      expect(result.selection.baseOffset, 5);
    });

    test('accounts for a separator the edit pushed in', () {
      // "100" -> typing a trailing "0" makes "1,000": four digits precede the
      // caret, so it must sit at the very end (offset 5, past the comma).
      final result = _type(peso, '100', '1000');
      expect(result.text, '1,000');
      expect(result.selection.baseOffset, 5);
    });
  });
}
