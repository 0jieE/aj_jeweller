// Unit tests for the Commitment-tab repository logic: the ledger
// derivation (balance/status/progress computed from applied disposal
// batches, never stored), the automatic loanPaid transition, cash receipt,
// and branch-specific vs. company-wide filtering.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

Item _seedDisposedScrap(AppRepository repo, BranchId branch, {required double grams, required int capital}) {
  final purchase = repo.addPurchase(
    description: 'Test scrap',
    weightGrams: grams,
    karat: 18,
    type: ItemType.scrap,
    capitalAmountCentavos: capital,
    origin: 'Bulk buy',
    branch: branch,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
  );
  repo.releaseCash(purchase.id, proofPhoto: proofPhoto); // -> forDisposal
  return repo.findItem(purchase.id)!;
}

void main() {
  group('addCommitment', () {
    test('starts loanPending with a zero balance ledger and no history', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Test Lender',
        amountCentavos: 100000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );

      final ledger = repo.ledgerFor(c.id);
      expect(ledger.status, CommitmentStatus.loanPending);
      expect(ledger.repaidAmountCentavos, 0);
      expect(ledger.remainingBalanceCentavos, 100000000);
      expect(ledger.appliedBatches, isEmpty);
      expect(ledger.repaymentProgress, 0);
    });
  });

  group('ledgerFor', () {
    test('balance is derived purely from disposal batches referencing the commitment', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Partial Lender',
        amountCentavos: 100000000, // ₱1,000,000
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(c.id, proofPhoto: proofPhoto);

      final item = _seedDisposedScrap(repo, BranchId.kidapawan, grams: 50, capital: 20000000);
      repo.recordDisposalBatch(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: 20000000,
        grossGrams: 50,
        grossAmountCentavos: 40000000, // ₱400,000 applied
        date: DateTime.now(),
        commitmentRef: c.id,
      );

      final ledger = repo.ledgerFor(c.id);
      expect(ledger.repaidAmountCentavos, 40000000);
      expect(ledger.remainingBalanceCentavos, 60000000);
      expect(ledger.repaymentProgress, closeTo(0.4, 0.0001));
      expect(ledger.status, CommitmentStatus.loanReceived);
      expect(ledger.appliedBatches, hasLength(1));
    });

    test('status becomes loanPaid automatically once applied gross covers the amount', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Payoff Lender',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(c.id, proofPhoto: proofPhoto);

      final item = _seedDisposedScrap(repo, BranchId.kidapawan, grams: 100, capital: 40000000);
      repo.recordDisposalBatch(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: 40000000,
        grossGrams: 100,
        grossAmountCentavos: 50000000, // exactly covers it
        date: DateTime.now(),
        commitmentRef: c.id,
      );

      final ledger = repo.ledgerFor(c.id);
      expect(ledger.status, CommitmentStatus.loanPaid);
      expect(ledger.remainingBalanceCentavos, 0);
      expect(ledger.repaymentProgress, 1.0);
    });

    test('remaining balance never goes negative even if a batch overshoots the loan', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Overshoot Lender',
        amountCentavos: 30000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(c.id, proofPhoto: proofPhoto);

      final item = _seedDisposedScrap(repo, BranchId.kidapawan, grams: 80, capital: 25000000);
      repo.recordDisposalBatch(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: 25000000,
        grossGrams: 80,
        grossAmountCentavos: 40000000, // overshoots the ₱300,000 loan
        date: DateTime.now(),
        commitmentRef: c.id,
      );

      final ledger = repo.ledgerFor(c.id);
      expect(ledger.remainingBalanceCentavos, 0);
      expect(ledger.status, CommitmentStatus.loanPaid);
      expect(ledger.repaymentProgress, 1.0);
    });
  });

  group('receiveCommitmentCash', () {
    test('advances pending to received and credits the branch cash balance', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Cash Lender',
        amountCentavos: 20000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.davao,
      );
      final before = repo.cashBalance(BranchId.davao);

      repo.receiveCommitmentCash(c.id, proofPhoto: proofPhoto);

      final updated = repo.findCommitment(c.id)!;
      expect(updated.dateReceived, isNotNull);
      expect(repo.cashBalance(BranchId.davao), before + 20000000);
      expect(repo.ledgerFor(c.id).status, CommitmentStatus.loanReceived);
    });

    test('a company-wide commitment records receipt without crediting any single branch', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Company Lender',
        amountCentavos: 20000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: null,
      );
      final kidapawanBefore = repo.cashBalance(BranchId.kidapawan);
      final davaoBefore = repo.cashBalance(BranchId.davao);

      repo.receiveCommitmentCash(c.id, proofPhoto: proofPhoto);

      expect(repo.findCommitment(c.id)!.dateReceived, isNotNull);
      expect(repo.cashBalance(BranchId.kidapawan), kidapawanBefore);
      expect(repo.cashBalance(BranchId.davao), davaoBefore);
    });
  });

  group('commitmentsForBranch', () {
    test('a branch view includes both that branch\'s commitments and company-wide ones', () {
      final repo = AppRepository();
      final specific = repo.addCommitment(
        lender: 'Kidapawan Only',
        amountCentavos: 10000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      final companyWide = repo.addCommitment(
        lender: 'Company Wide',
        amountCentavos: 10000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: null,
      );
      final davaoOnly = repo.addCommitment(
        lender: 'Davao Only',
        amountCentavos: 10000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.davao,
      );

      final kidapawanView = repo.commitmentsForBranch(BranchId.kidapawan).map((c) => c.id);
      expect(kidapawanView, containsAll([specific.id, companyWide.id]));
      expect(kidapawanView, isNot(contains(davaoOnly.id)));
    });
  });
}
