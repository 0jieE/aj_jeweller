import 'dart:typed_data';

import 'branch.dart';
import 'disposal_batch.dart';
import 'item_status.dart';

/// A cash loan the shop receives from a lender, repaid not in cash but in
/// scrap gold — the gross amount of each disposal batch applied to it draws
/// the balance down until it's covered.
///
/// [branch] is `null` for a company-wide commitment, consistent with how
/// branch filtering works everywhere else in the app.
///
/// This model intentionally does NOT store a balance, a repaid amount, or a
/// status — all three are derived from the disposal batches applied
/// against it (see [CommitmentLedger]), never entered or set directly.
/// `loanPaid` in particular must never be a button someone presses; it's
/// what the math says once the balance hits zero.
class Commitment {
  final String id;
  final String lender;
  final int amountCentavos;

  /// The lender's locked-in ₱-per-gram rate — reference and loan terms
  /// only. Never used to compute a disposal batch's actual gross; that's
  /// always entered by hand at disposal time.
  final int ratePerGramCentavos;

  /// `null` for a company-wide commitment.
  final BranchId? branch;

  final DateTime dateApproved;

  /// `null` while the loan is still `loanPending` — cash not yet in hand.
  final DateTime? dateReceived;

  /// Photo taken when the loan cash was received — the counted cash, or the
  /// lender's slip — as proof the money actually arrived.
  final Uint8List? receivedProofPhoto;

  const Commitment({
    required this.id,
    required this.lender,
    required this.amountCentavos,
    required this.ratePerGramCentavos,
    required this.branch,
    required this.dateApproved,
    this.dateReceived,
    this.receivedProofPhoto,
  });

  /// Derived — the full weight this loan represents at its locked-in rate.
  double get totalGramsOwed => amountCentavos / ratePerGramCentavos;

  Commitment copyWith({DateTime? dateReceived, Uint8List? receivedProofPhoto}) {
    return Commitment(
      id: id,
      lender: lender,
      amountCentavos: amountCentavos,
      ratePerGramCentavos: ratePerGramCentavos,
      branch: branch,
      dateApproved: dateApproved,
      dateReceived: dateReceived ?? this.dateReceived,
      receivedProofPhoto: receivedProofPhoto ?? this.receivedProofPhoto,
    );
  }
}

/// A [Commitment] together with every [DisposalBatch] applied against it —
/// the computed view that both the list and detail screens read from.
/// Built by `AppRepository.ledgerFor` so the derivation logic lives in one
/// place.
class CommitmentLedger {
  final Commitment commitment;

  /// Every disposal batch whose `commitmentRef` points at this commitment,
  /// oldest first — the audit trail.
  final List<DisposalBatch> appliedBatches;

  const CommitmentLedger({required this.commitment, required this.appliedBatches});

  /// Derived — sum of every applied batch's gross amount. This is the
  /// figure that pays down the loan; it is NOT the shop's profit on those
  /// batches (see [DisposalBatch.netCentavos] for that, kept separate).
  int get repaidAmountCentavos =>
      appliedBatches.fold(0, (sum, b) => sum + b.grossAmountCentavos);

  /// Derived — never negative even if batches happen to overshoot the loan.
  int get remainingBalanceCentavos =>
      (commitment.amountCentavos - repaidAmountCentavos) < 0 ? 0 : commitment.amountCentavos - repaidAmountCentavos;

  /// Derived — 0.0 to 1.0.
  double get repaymentProgress => commitment.amountCentavos == 0
      ? 0
      : (repaidAmountCentavos / commitment.amountCentavos).clamp(0.0, 1.0);

  double get repaidGrams => repaidAmountCentavos / commitment.ratePerGramCentavos;

  /// Derived — roughly how much weight still stands between the shop and a
  /// cleared loan, at the lender's locked-in rate.
  double get remainingGrams => remainingBalanceCentavos / commitment.ratePerGramCentavos;

  /// The only computed status: `loanPending` until cash is received,
  /// `loanPaid` the instant the balance reaches zero, `loanReceived`
  /// in between. Never stored, never set by a button.
  CommitmentStatus get status {
    if (commitment.dateReceived == null) return CommitmentStatus.loanPending;
    if (remainingBalanceCentavos <= 0) return CommitmentStatus.loanPaid;
    return CommitmentStatus.loanReceived;
  }
}
