// Unit tests for silver as a third item type: its own purity scale and
// rates, sold over the counter like goods, and never mixed up with gold.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/purchase_batch.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

PurchaseBatch _buy(AppRepository repo, {required ItemType type, required int purity}) {
  return repo.recordPurchaseBatch(
    customer: const CustomerDetails(name: 'Silver Seller'),
    lines: [
      PurchaseDraftLine(
        description: 'Test piece',
        grossWeightGrams: 20,
        weightGrams: 20,
        karat: purity,
        type: type,
        capitalAmountCentavos: 130000,
      ),
    ],
    branch: BranchId.kidapawan,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
  );
}

void main() {
  test('gold and silver rates are listed separately', () {
    final repo = AppRepository();
    expect(repo.goldRates.every((r) => !r.isSilver), isTrue);
    expect(repo.silverRates.map((r) => r.karat), [999, 925]);
    expect(repo.ratesForType(ItemType.silver), repo.silverRates);
    expect(repo.ratesForType(ItemType.scrap), repo.goldRates);
  });

  test('a released silver purchase is listed and sellable, like goods', () {
    final repo = AppRepository();
    final batch = _buy(repo, type: ItemType.silver, purity: 925);
    repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier, proofPhoto: proofPhoto);

    final item = repo.itemsInBatch(batch.id).single;
    expect(item.itemStatus, ItemStatus.listed);
    expect(repo.sellableGoods(branchId: BranchId.kidapawan).map((i) => i.id), contains(item.id));
    expect(repo.allScrap(branchId: BranchId.kidapawan).map((i) => i.id), isNot(contains(item.id)));
  });

  test('silver must carry a silver purity, and gold a karat', () {
    final repo = AppRepository();
    expect(() => _buy(repo, type: ItemType.silver, purity: 18), throwsArgumentError);
    expect(() => _buy(repo, type: ItemType.goods, purity: 925), throwsArgumentError);
  });

  test('a correction cannot switch metal without switching purity', () {
    final repo = AppRepository();
    final batch = _buy(repo, type: ItemType.goods, purity: 18);
    final item = repo.itemsInBatch(batch.id).single;

    expect(() => repo.updateItem(item.id, type: ItemType.silver), throwsArgumentError);

    repo.updateItem(item.id, type: ItemType.silver, karat: 925);
    final fixed = repo.findItem(item.id)!;
    expect(fixed.type, ItemType.silver);
    expect(fixed.karat, 925);
  });

  test('a partition stays the same metal as its lot', () {
    final repo = AppRepository();
    final batch = _buy(repo, type: ItemType.silver, purity: 999);
    repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier, proofPhoto: proofPhoto);
    final lot = repo.itemsInBatch(batch.id).single;

    expect(
      () => repo.createPartition(
        parentId: lot.id,
        description: 'Gold from silver?',
        type: ItemType.goods,
        weightGrams: 5,
        amountCentavos: 30000,
      ),
      throwsArgumentError,
    );
    final child = repo.createPartition(
      parentId: lot.id,
      description: 'Silver cut',
      type: ItemType.silver,
      weightGrams: 5,
      amountCentavos: 30000,
    );
    expect(child.karat, 999);
  });

  test('the demo data has silver waiting for release and silver on hand in each branch', () {
    final repo = AppRepository();
    final silver = repo.itemsForBranch(null).where((i) => i.type == ItemType.silver).toList();
    expect(silver.where((i) => i.itemStatus == ItemStatus.pending), isNotEmpty);
    for (final branch in BranchId.values) {
      expect(repo.sellableGoods(branchId: branch, silver: true), isNotEmpty, reason: branch.label);
      expect(repo.itemsForDisposal(branchId: branch, silver: true), isNotEmpty, reason: branch.label);
    }
  });

  test('released silver can be disposed, and disposing it takes it off the Sell list', () {
    final repo = AppRepository();
    final batch = _buy(repo, type: ItemType.silver, purity: 925);
    repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier, proofPhoto: proofPhoto);
    final item = repo.itemsInBatch(batch.id).single;

    expect(repo.itemsForDisposal(branchId: BranchId.kidapawan, silver: true).map((i) => i.id), contains(item.id));
    expect(repo.itemsForDisposal(branchId: BranchId.kidapawan).map((i) => i.id), isNot(contains(item.id)),
        reason: 'the gold scrap pool stays gold');
    expect(repo.sellableGoods(branchId: BranchId.kidapawan, silver: true).map((i) => i.id), contains(item.id));
    expect(repo.sellableGoods(branchId: BranchId.kidapawan, silver: false).map((i) => i.id), isNot(contains(item.id)));

    final loan = repo.addCommitment(
      lender: 'Silver buyer',
      amountCentavos: 1000000,
      ratePerGramCentavos: 6000,
      dateApproved: DateTime.now(),
      branch: BranchId.kidapawan,
    );
    repo.receiveCommitmentCash(loan.id, proofPhoto: proofPhoto);
    repo.completeDisposal(
      branch: BranchId.kidapawan,
      itemIds: [item.id],
      capitalCentavos: item.capitalAmountCentavos,
      grossGrams: item.weightGrams,
      grossAmountCentavos: 140000,
      date: DateTime.now(),
      commitmentRef: loan.id,
    );

    expect(repo.findItem(item.id)!.itemStatus, ItemStatus.disposed);
    expect(repo.sellableGoods(branchId: BranchId.kidapawan, silver: true).map((i) => i.id), isNot(contains(item.id)));
    expect(repo.itemsForDisposal(branchId: BranchId.kidapawan, silver: true).map((i) => i.id), isNot(contains(item.id)));
    expect(repo.allSilver(branchId: BranchId.kidapawan).map((i) => i.id), contains(item.id));
  });

  test('silver held in an order cannot be disposed', () {
    final repo = AppRepository();
    final batch = _buy(repo, type: ItemType.silver, purity: 999);
    repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier, proofPhoto: proofPhoto);
    final item = repo.itemsInBatch(batch.id).single;
    repo.reserveItem(item.id);
    expect(repo.itemsForDisposal(branchId: BranchId.kidapawan, silver: true).map((i) => i.id), isNot(contains(item.id)));
  });
}
