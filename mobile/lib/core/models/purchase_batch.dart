import 'dart:typed_data';

import 'branch.dart';
import 'customer.dart';
import 'item.dart';
import 'item_status.dart';
import 'user_role.dart';

/// One purchase transaction: everything bought from one customer at one
/// counter visit, however many pieces that turned out to be.
///
/// This is the unit a Cashier verifies and releases cash against — a
/// customer is paid once for the whole lot they brought in, so the batch
/// carries the verification status and the items carry the goods. A
/// single-item purchase is simply a batch of one.
class PurchaseBatch {
  final String id;
  final CustomerDetails customer;
  final BranchId branch;
  final DateTime date;
  final AppUserRole submittedByRole;
  final VerificationStatus verificationStatus;

  /// Set by a Cashier's "return for correction" — cleared on resubmission.
  final String? verificationNote;

  /// When the Cashier actually released the cash; null until then.
  final DateTime? releasedAt;

  /// The person who encoded the purchase at the counter.
  final String? submittedByUserId;

  /// The person who released the cash. Null until release — and deliberately
  /// separate from [submittedByUserId], because the two being different
  /// people is the control this whole flow exists to enforce.
  final String? releasedByUserId;

  /// Photo taken as the cash was handed over — the counted money, or the
  /// customer holding it. Proof the payment actually left the drawer.
  final Uint8List? releaseProofPhoto;

  const PurchaseBatch({
    required this.id,
    required this.customer,
    required this.branch,
    required this.date,
    required this.submittedByRole,
    required this.verificationStatus,
    this.verificationNote,
    this.releasedAt,
    this.submittedByUserId,
    this.releasedByUserId,
    this.releaseProofPhoto,
  });

  PurchaseBatch copyWith({
    CustomerDetails? customer,
    VerificationStatus? verificationStatus,
    String? verificationNote,
    bool clearVerificationNote = false,
    DateTime? releasedAt,
    String? releasedByUserId,
    Uint8List? releaseProofPhoto,
  }) {
    return PurchaseBatch(
      id: id,
      customer: customer ?? this.customer,
      branch: branch,
      date: date,
      submittedByRole: submittedByRole,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      verificationNote: clearVerificationNote ? null : (verificationNote ?? this.verificationNote),
      releasedAt: releasedAt ?? this.releasedAt,
      submittedByUserId: submittedByUserId,
      releasedByUserId: releasedByUserId ?? this.releasedByUserId,
      releaseProofPhoto: releaseProofPhoto ?? this.releaseProofPhoto,
    );
  }
}

/// One line a Sales Rep or Appraiser has staged but not yet submitted — the
/// purchase-side equivalent of a cart line. Held only in memory by the
/// basket state; it becomes an [Item] the moment the batch is submitted.
class PurchaseDraftLine {
  final String description;

  /// As-presented weight, before stones and clasps are deducted.
  final double grossWeightGrams;

  /// Net gold weight — what the amount is actually calculated from.
  final double weightGrams;

  final int karat;
  final ItemType type;
  final int capitalAmountCentavos;

  /// Photo of the piece, carried through to the [Item] on submit.
  final Uint8List? photo;

  const PurchaseDraftLine({
    required this.description,
    required this.grossWeightGrams,
    required this.weightGrams,
    required this.karat,
    required this.type,
    required this.capitalAmountCentavos,
    this.photo,
  });

  bool get hasPhoto => photo != null;

  double get deductedGrams => grossWeightGrams - weightGrams;
}
