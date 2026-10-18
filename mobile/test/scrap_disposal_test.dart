// Unit tests for the Scrap-tab repository logic: itemsForDisposal
// filtering (including exhausted partitioned lots), completeDisposal
// marking items disposed and creating the batch, and the flow-through into
// a tagged commitment's ledger (including the automatic loanPaid flip).

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

Item _seedDisposableScrap(AppRepository repo, BranchId branch, {required double grams, required int capital}) {
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
  repo.releaseCash(purchase.id, proofPhoto: proofPhoto); // -> verified, forDisposal
  return repo.findItem(purchase.id)!;
}

void main() {
  group('itemsForDisposal', () {
    test('excludes a partitioned lot that has been fully drawn down', () {
      final repo = AppRepository();
      final parent = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 10, capital: 400000);

      expect(repo.itemsForDisposal(branchId: BranchId.kidapawan).map((i) => i.id), contains(parent.id));

      repo.createPartition(
        parentId: parent.id,
        description: 'Whole thing carved out',
        type: ItemType.goods,
        weightGrams: 10,
        amountCentavos: 400000,
      );

      // Fully drawn down — nothing left of the parent lot to dispose of.
      expect(repo.itemsForDisposal(branchId: BranchId.kidapawan).map((i) => i.id), isNot(contains(parent.id)));
    });

    test('includes a partially partitioned lot at its remaining grams, not its original weight', () {
      final repo = AppRepository();
      final parent = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 20, capital: 800000);

      repo.createPartition(
        parentId: parent.id,
        description: 'Partial carve-out',
        type: ItemType.goods,
        weightGrams: 8,
        amountCentavos: 320000,
      );

      final pool = repo.itemsForDisposal(branchId: BranchId.kidapawan);
      final found = pool.firstWhere((i) => i.id == parent.id);
      expect(found.effectiveRemainingGrams, 12);
      expect(found.effectiveRemainingAmountCentavos, 480000);
    });
  });

  group('completeDisposal', () {
    test('creates the batch and marks every selected item disposed', () {
      final repo = AppRepository();
      final a = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 10, capital: 400000);
      final b = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 15, capital: 600000);
      final loan = repo.addCommitment(
        lender: 'Settling Lender',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(loan.id, proofPhoto: proofPhoto);

      final batch = repo.completeDisposal(
        branch: BranchId.kidapawan,
        itemIds: [a.id, b.id],
        capitalCentavos: 1000000,
        grossGrams: 25,
        grossAmountCentavos: 1200000,
        date: DateTime.now(),
        commitmentRef: loan.id,
      );

      expect(batch.netCentavos, 200000);
      expect(repo.findItem(a.id)!.itemStatus, ItemStatus.disposed);
      expect(repo.findItem(b.id)!.itemStatus, ItemStatus.disposed);
      expect(repo.itemsForDisposal(branchId: BranchId.kidapawan).map((i) => i.id), isNot(contains(a.id)));
      expect(repo.disposalBatches, contains(batch));
    });

    test('only the commitment it names is touched, never the others', () {
      final repo = AppRepository();
      final item = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 10, capital: 400000);
      final settled = repo.addCommitment(
        lender: 'Settled Lender',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      final untouched = repo.addCommitment(
        lender: 'Untouched Lender',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(settled.id, proofPhoto: proofPhoto);
      repo.receiveCommitmentCash(untouched.id, proofPhoto: proofPhoto);

      repo.completeDisposal(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: 400000,
        grossGrams: 10,
        grossAmountCentavos: 500000,
        date: DateTime.now(),
        commitmentRef: settled.id,
      );

      expect(repo.ledgerFor(settled.id).repaidAmountCentavos, 500000);
      expect(repo.ledgerFor(untouched.id).repaidAmountCentavos, 0);
      expect(repo.ledgerFor(untouched.id).appliedBatches, isEmpty);
    });

    test('tagged to a commitment, flips it to loanPaid the instant gross covers the balance', () {
      final repo = AppRepository();
      final item = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 20, capital: 800000);
      final commitment = repo.addCommitment(
        lender: 'Payoff Lender',
        amountCentavos: 100000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(commitment.id, proofPhoto: proofPhoto);
      expect(repo.ledgerFor(commitment.id).status, CommitmentStatus.loanReceived);

      repo.completeDisposal(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: 800000,
        grossGrams: 20,
        grossAmountCentavos: 100000000, // exactly covers the loan
        date: DateTime.now(),
        commitmentRef: commitment.id,
      );

      final ledger = repo.ledgerFor(commitment.id);
      expect(ledger.status, CommitmentStatus.loanPaid);
      expect(ledger.remainingBalanceCentavos, 0);
      expect(ledger.appliedBatches, hasLength(1));
    });

    test('does not touch any branch cash or bank balance', () {
      final repo = AppRepository();
      final item = _seedDisposableScrap(repo, BranchId.kidapawan, grams: 10, capital: 400000);
      final loan = repo.addCommitment(
        lender: 'Cash-neutral Lender',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(loan.id, proofPhoto: proofPhoto);
      final cashBefore = repo.cashBalance(BranchId.kidapawan);
      final bankBefore = repo.bankBalance(BranchId.kidapawan);

      repo.completeDisposal(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: 400000,
        grossGrams: 10,
        grossAmountCentavos: 700000,
        date: DateTime.now(),
        commitmentRef: loan.id,
      );

      expect(repo.cashBalance(BranchId.kidapawan), cashBefore);
      expect(repo.bankBalance(BranchId.kidapawan), bankBefore);
    });
  });
}
