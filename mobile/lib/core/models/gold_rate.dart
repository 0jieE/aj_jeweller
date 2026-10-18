/// Whether a purity figure is silver fineness (925, 999 — parts per
/// thousand) rather than a gold karat (24 and under). One number field
/// carries both, and the ranges never overlap.
bool isSilverPurity(int purity) => purity >= 100;

/// The buying rate for a given purity, in centavos per gram — a gold karat,
/// or a silver fineness (see [isSilverPurity]).
class GoldRate {
  final int karat;
  final int pricePerGramCentavos;
  final DateTime updatedAt;

  const GoldRate({
    required this.karat,
    required this.pricePerGramCentavos,
    required this.updatedAt,
  });

  bool get isSilver => isSilverPurity(karat);

  GoldRate copyWith({int? pricePerGramCentavos, DateTime? updatedAt}) {
    return GoldRate(
      karat: karat,
      pricePerGramCentavos: pricePerGramCentavos ?? this.pricePerGramCentavos,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
