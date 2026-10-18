import 'package:intl/intl.dart';

/// The single source of formatting for every peso amount and gram weight in
/// the app. Money is stored as integer centavos everywhere else — these
/// helpers are the only place that should convert to display strings.
class AppFormat {
  AppFormat._();

  static final NumberFormat _peso = NumberFormat.currency(
    locale: 'en_PH',
    symbol: '₱',
    decimalDigits: 2,
  );

  static final NumberFormat _pesoWhole = NumberFormat.currency(
    locale: 'en_PH',
    symbol: '₱',
    decimalDigits: 0,
  );

  static final NumberFormat _grams = NumberFormat('#,##0.000', 'en_PH');

  /// e.g. 103790350 centavos -> "₱1,037,903.50"
  static String peso(int centavos, {bool whole = false}) {
    final pesos = centavos / 100;
    return whole ? _pesoWhole.format(pesos) : _peso.format(pesos);
  }

  /// Signed variant for net figures, e.g. "+₱1,200.00" / "-₱850.00".
  static String pesoSigned(int centavos) {
    final formatted = peso(centavos.abs());
    if (centavos > 0) return '+$formatted';
    if (centavos < 0) return '-$formatted';
    return formatted;
  }

  /// e.g. 15.375 -> "15.375g"
  static String grams(double grams) => '${_grams.format(grams)}g';

  /// e.g. 24 -> "24K"; silver fineness stays bare: 925 -> "925"
  static String karat(int karat) => karat >= 100 ? '$karat' : '${karat}K';

  /// Purity with its metal, for prose: "18K gold", "925 silver".
  static String purity(int karat) => karat >= 100 ? '$karat silver' : '${karat}K gold';

  static String dateShort(DateTime date) => DateFormat('MMM d, y').format(date);

  /// Compact range label for a filter chip. Drops the year when the range
  /// sits inside the current one, and the repeated month within a single
  /// month, so the chip still leaves room for its clear button on a phone.
  static String dateRangeShort(DateTime start, DateTime end) {
    final thisYear = DateTime.now().year;
    if (start.year == thisYear && end.year == thisYear) {
      final from = DateFormat('MMM d').format(start);
      final to = start.month == end.month
          ? DateFormat('d').format(end)
          : DateFormat('MMM d').format(end);
      return '$from – $to';
    }
    return '${dateShort(start)} – ${dateShort(end)}';
  }

  static String dateTimeShort(DateTime date) =>
      DateFormat('MMM d, y · h:mm a').format(date);
}
