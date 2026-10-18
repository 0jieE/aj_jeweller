/// Peso amounts as plain text, for records written by the data layer (log
/// summaries, ledger notes) that must not depend on the widget layer's
/// formatters. Always two decimals and grouped: "₱1,037,903.00".
String pesoText(int centavos) {
  final negative = centavos < 0;
  final whole = (centavos.abs() ~/ 100).toString();
  final cents = (centavos.abs() % 100).toString().padLeft(2, '0');
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${negative ? '-' : ''}₱$grouped.$cents';
}
