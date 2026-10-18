import 'branch.dart';
import 'user_role.dart';

/// What kind of movement a [CashEntry] represents. `cashIn`, `expense`, and
/// `withdrawal` are the three single-sided types a Cashier/Admin picks from
/// in New Cash Entry; a transfer always writes as a `transferOut` +
/// `transferIn` pair (see [AppRepository.recordTransfer]) rather than a
/// type someone selects directly.
enum CashEntryType {
  cashIn,
  expense,
  withdrawal,
  transferOut,
  transferIn;

  String get label {
    switch (this) {
      case CashEntryType.cashIn:
        return 'Cash in';
      case CashEntryType.expense:
        return 'Expense';
      case CashEntryType.withdrawal:
        return 'Withdrawal';
      case CashEntryType.transferOut:
        return 'Transfer out';
      case CashEntryType.transferIn:
        return 'Transfer in';
    }
  }

  /// True for a type that increases the branch balance; false for one that
  /// decreases it. Drives both the running-balance math and how an amount
  /// is signed for display.
  bool get isCredit => this == CashEntryType.cashIn || this == CashEntryType.transferIn;
}

/// Which of a branch's three pools of money an entry moves.
///
/// They are kept apart because they are spent differently: purchase cash is
/// the float the Cashier pays customers out of, sales cash is what came in
/// over the counter, and bank is money that never sat in a drawer at all.
/// Mixing sales takings into the purchase float is exactly how a branch
/// ends up not knowing whether it made money or just moved it.
enum CashAccount {
  purchase,
  sales,
  bank;

  String get label {
    switch (this) {
      case CashAccount.purchase:
        return 'Purchase Cash';
      case CashAccount.sales:
        return 'Sales Cash';
      case CashAccount.bank:
        return 'Cash in Bank';
    }
  }

  String get shortLabel {
    switch (this) {
      case CashAccount.purchase:
        return 'Purchase';
      case CashAccount.sales:
        return 'Sales';
      case CashAccount.bank:
        return 'Bank';
    }
  }
}

/// Where a [CashEntry] came from. A `manual` entry is one a Cashier/Admin
/// typed into New Cash Entry; the other three are written automatically as
/// the side effect of a purchase cash release, a sale payment, or a
/// commitment receipt — see [AppRepository.releaseCash],
/// [AppRepository.completeSale], and [AppRepository.receiveCommitmentCash].
enum CashEntrySourceType { manual, purchase, sale, commitment }

/// One line in a branch's cash ledger. Every branch balance is the sum of
/// its starting balance plus every [CashEntry] against it — nothing else is
/// allowed to move a balance directly (see [AppRepository.cashBalance]).
///
/// An entry linked to a source record ([sourceType] other than `manual`) is
/// read-only in the ledger UI: corrections happen on the source transaction,
/// never by editing or deleting the entry itself.
class CashEntry {
  final String id;
  final BranchId branch;
  final CashEntryType type;

  /// Which pool of the branch's money this moves.
  final CashAccount account;

  /// Always positive — [type] determines whether it adds to or subtracts
  /// from the branch balance (see [signedAmountCentavos]).
  final int amountCentavos;

  /// Required for every entry — what makes the ledger auditable.
  final String note;

  /// Set for `expense` entries only.
  final String? category;

  final DateTime date;
  final AppUserRole recordedByRole;

  /// The person behind the entry, where one is known.
  final String? recordedByUserId;
  final CashEntrySourceType sourceType;

  /// The purchase/sale/commitment id this entry was written for, when
  /// [sourceType] isn't `manual`.
  final String? linkedRecordId;

  /// Shared by both halves of a transfer so they can never be edited or
  /// deleted independently of each other.
  final String? transferPairId;

  const CashEntry({
    required this.id,
    required this.branch,
    required this.type,
    this.account = CashAccount.purchase,
    required this.amountCentavos,
    required this.note,
    this.category,
    required this.date,
    required this.recordedByRole,
    this.recordedByUserId,
    this.sourceType = CashEntrySourceType.manual,
    this.linkedRecordId,
    this.transferPairId,
  });

  bool get isManual => sourceType == CashEntrySourceType.manual;

  bool get isTransfer => transferPairId != null;

  CashEntry copyWith({
    CashEntryType? type,
    CashAccount? account,
    int? amountCentavos,
    String? note,
    String? category,
    bool clearCategory = false,
    DateTime? date,
  }) {
    return CashEntry(
      id: id,
      branch: branch,
      type: type ?? this.type,
      account: account ?? this.account,
      amountCentavos: amountCentavos ?? this.amountCentavos,
      note: note ?? this.note,
      category: clearCategory ? null : (category ?? this.category),
      date: date ?? this.date,
      recordedByRole: recordedByRole,
      recordedByUserId: recordedByUserId,
      sourceType: sourceType,
      linkedRecordId: linkedRecordId,
      transferPairId: transferPairId,
    );
  }

  /// Signed so callers can fold straight into a running balance.
  int get signedAmountCentavos => type.isCredit ? amountCentavos : -amountCentavos;
}
