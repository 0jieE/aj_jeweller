import 'package:flutter/material.dart';

/// Where an item sits in the inventory lifecycle. Unrelated to
/// [VerificationStatus] and [CommitmentStatus] — an item that is "pending"
/// has nothing to do with a loan that is "loan pending".
enum ItemStatus {
  pending,
  listed,
  sold,
  reserved,
  forDisposal,
  disposed;

  String get label {
    switch (this) {
      case ItemStatus.pending:
        return 'Pending';
      case ItemStatus.listed:
        return 'Listed';
      case ItemStatus.sold:
        return 'Sold';
      case ItemStatus.reserved:
        return 'Reserved';
      case ItemStatus.forDisposal:
        return 'For Disposal';
      case ItemStatus.disposed:
        return 'Disposed';
    }
  }

  IconData get icon {
    switch (this) {
      case ItemStatus.pending:
        return Icons.hourglass_top_rounded;
      case ItemStatus.listed:
        return Icons.sell_outlined;
      case ItemStatus.sold:
        return Icons.check_circle_rounded;
      case ItemStatus.reserved:
        return Icons.lock_clock_rounded;
      case ItemStatus.forDisposal:
        return Icons.delete_sweep_outlined;
      case ItemStatus.disposed:
        return Icons.inventory_2_outlined;
    }
  }
}

/// Whether a record (item or sale) has been checked by a Cashier/Admin.
/// Unrelated to [ItemStatus] and [CommitmentStatus].
enum VerificationStatus {
  awaitingVerification,
  verified,
  returnedForCorrection;

  String get label {
    switch (this) {
      case VerificationStatus.awaitingVerification:
        return 'Awaiting Verification';
      case VerificationStatus.verified:
        return 'Verified';
      case VerificationStatus.returnedForCorrection:
        return 'Returned for Correction';
    }
  }
}

/// The sequential lifecycle of a commitment (a loan to be repaid in gold).
/// Unlike [ItemStatus] and [VerificationStatus], this always progresses in
/// order: loanPending -> loanReceived -> loanPaid.
enum CommitmentStatus {
  loanPending,
  loanReceived,
  loanPaid;

  String get label {
    switch (this) {
      case CommitmentStatus.loanPending:
        return 'Loan Pending';
      case CommitmentStatus.loanReceived:
        return 'Loan Received';
      case CommitmentStatus.loanPaid:
        return 'Loan Paid';
    }
  }

  int get stepIndex => index;
}
