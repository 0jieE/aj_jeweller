/// The two physical branches. Admin also gets a combined "all branches"
/// view, represented as `null` wherever a branch filter is optional.
enum BranchId {
  kidapawan,
  davao;

  String get label {
    switch (this) {
      case BranchId.kidapawan:
        return 'Kidapawan';
      case BranchId.davao:
        return 'Davao';
    }
  }
}

/// A branch's identity and starting cash position. Money is stored in
/// centavos (integer) to avoid floating-point drift on peso amounts.
///
/// [startingCashBalanceCentavos] is the only cash figure stored here — the
/// live, spendable cash balance is a derived value
/// (`AppRepository.cashBalance`), computed as this starting figure plus
/// every `CashEntry` posted against the branch. Nothing may add a stored
/// "current balance" field back onto this class; that's exactly the
/// drift-prone shortcut the cash ledger replaced.
///
/// This also deliberately does NOT carry a pending-scrap figure — that's
/// derived from live scrap inventory (`AppRepository.itemsForDisposal`)
/// wherever it's shown, so the Dashboard and the Scrap tab can never drift
/// out of sync with each other.
class Branch {
  final BranchId id;
  final int startingCashBalanceCentavos;

  /// Opening balance of sales cash — takings from the counter, kept apart
  /// from the purchase float. The live figure is derived like the others.
  final int startingSalesCashCentavos;

  /// Opening balance of cash in bank. Like the other two, the live figure is
  /// this plus every bank-account ledger entry
  /// (`AppRepository.accountBalance`).
  final int bankBalanceCentavos;
  final int silverValueCentavos;

  const Branch({
    required this.id,
    required this.startingCashBalanceCentavos,
    this.startingSalesCashCentavos = 0,
    this.bankBalanceCentavos = 0,
    this.silverValueCentavos = 0,
  });

  String get name => id.label;

  Branch copyWith({
    int? startingCashBalanceCentavos,
    int? startingSalesCashCentavos,
    int? bankBalanceCentavos,
    int? silverValueCentavos,
  }) {
    return Branch(
      id: id,
      startingCashBalanceCentavos:
          startingCashBalanceCentavos ?? this.startingCashBalanceCentavos,
      startingSalesCashCentavos: startingSalesCashCentavos ?? this.startingSalesCashCentavos,
      bankBalanceCentavos: bankBalanceCentavos ?? this.bankBalanceCentavos,
      silverValueCentavos: silverValueCentavos ?? this.silverValueCentavos,
    );
  }
}
