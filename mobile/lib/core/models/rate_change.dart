/// One entry in a karat's (or silver fineness's) price history: the rate
/// being set for the first time, or changed from one figure to another.
///
/// Kept per purity rather than read back out of the transaction log, so the
/// question the counter actually asks — "what was 18K a week ago?" — is a
/// straight lookup, not a text search through everything else that happened.
class RateChange {
  final int karat;

  /// Null when this entry is the rate being added.
  final int? beforeCentavos;
  final int afterCentavos;
  final DateTime at;
  final String userId;
  final String userName;

  /// When this entry put back an earlier price, the time that price was
  /// originally set — so the history reads "restored", not a fresh quote.
  final DateTime? restoredFrom;

  const RateChange({
    required this.karat,
    this.beforeCentavos,
    required this.afterCentavos,
    required this.at,
    required this.userId,
    required this.userName,
    this.restoredFrom,
  });

  bool get isInitial => beforeCentavos == null;

  int get deltaCentavos => beforeCentavos == null ? 0 : afterCentavos - beforeCentavos!;
}
