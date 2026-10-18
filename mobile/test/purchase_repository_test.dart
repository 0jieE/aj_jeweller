// Unit tests for the Purchase-tab repository logic: cash release, return
// for correction, resubmission, and lot partitioning (the trickiest part —
// atomic draw-down and over-draw prevention).

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

void main() {
  group('addPurchase', () {
    test('creates an item awaiting verification with cash not yet moved', () {
      final repo = AppRepository();
      final branchBefore = repo.cashBalance(BranchId.kidapawan);

      final item = repo.addPurchase(
        description: 'Test ring',
        weightGrams: 3.0,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 500000,
        origin: 'Walk-in – Test',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );

      expect(item.itemStatus, ItemStatus.pending);
      expect(item.verificationStatus, VerificationStatus.awaitingVerification);
      expect(repo.cashBalance(BranchId.kidapawan), branchBefore);
      expect(repo.findItem(item.id), isNotNull);
    });
  });

  group('releaseCash', () {
    test('marks verified, sets post-verification item status, and deducts branch cash', () {
      final repo = AppRepository();
      final goodsItem = repo.addPurchase(
        description: 'Test bangle',
        weightGrams: 10.0,
        karat: 21,
        type: ItemType.goods,
        capitalAmountCentavos: 1000000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      final scrapItem = repo.addPurchase(
        description: 'Test scrap',
        weightGrams: 20.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 800000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );

      final balanceBefore = repo.cashBalance(BranchId.kidapawan);

      repo.releaseCash(goodsItem.id, proofPhoto: proofPhoto);
      final releasedGoods = repo.findItem(goodsItem.id)!;
      expect(releasedGoods.verificationStatus, VerificationStatus.verified);
      expect(releasedGoods.itemStatus, ItemStatus.listed);
      expect(
        repo.cashBalance(BranchId.kidapawan),
        balanceBefore - goodsItem.capitalAmountCentavos,
      );

      repo.releaseCash(scrapItem.id, proofPhoto: proofPhoto);
      final releasedScrap = repo.findItem(scrapItem.id)!;
      expect(releasedScrap.itemStatus, ItemStatus.forDisposal);
      expect(
        repo.cashBalance(BranchId.kidapawan),
        balanceBefore - goodsItem.capitalAmountCentavos - scrapItem.capitalAmountCentavos,
      );
    });
  });

  group('returnForCorrection / resubmitItem', () {
    test('returned item carries a note and is not verified; resubmit clears it', () {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: 'Wrong weight ring',
        weightGrams: 3.0,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 500000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );

      repo.returnForCorrection(item.id, 'Weight looks off — recheck on scale');
      final returned = repo.findItem(item.id)!;
      expect(returned.verificationStatus, VerificationStatus.returnedForCorrection);
      expect(returned.verificationNote, 'Weight looks off — recheck on scale');
      expect(
        repo.returnedForCorrectionFor(AppUserRole.assistantAppraiser, branchId: BranchId.kidapawan),
        contains(returned),
      );

      repo.resubmitItem(
        item.id,
        description: 'Wrong weight ring (fixed)',
        weightGrams: 3.2,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 520000,
        origin: 'Walk-in',
      );
      final resubmitted = repo.findItem(item.id)!;
      expect(resubmitted.verificationStatus, VerificationStatus.awaitingVerification);
      expect(resubmitted.itemStatus, ItemStatus.pending);
      expect(resubmitted.verificationNote, isNull);
      expect(resubmitted.weightGrams, 3.2);
    });
  });

  group('createPartition', () {
    test('draws down parent grams and amount atomically', () {
      final repo = AppRepository();
      final parent = repo.addPurchase(
        description: 'Bulk scrap lot',
        weightGrams: 50.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 2000000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(parent.id, proofPhoto: proofPhoto);

      final child = repo.createPartition(
        parentId: parent.id,
        description: 'First partition',
        type: ItemType.goods,
        weightGrams: 20.0,
        amountCentavos: 800000,
      );

      final updatedParent = repo.findItem(parent.id)!;
      expect(updatedParent.effectiveOriginalGrams, 50.0);
      expect(updatedParent.effectiveOriginalAmountCentavos, 2000000);
      expect(updatedParent.effectiveRemainingGrams, 30.0);
      expect(updatedParent.effectiveRemainingAmountCentavos, 1200000);
      expect(updatedParent.isExhausted, isFalse);

      expect(child.parentLotId, parent.id);
      expect(child.weightGrams, 20.0);
      expect(child.capitalAmountCentavos, 800000);
      expect(child.karat, parent.karat);
      expect(child.verificationStatus, VerificationStatus.verified);
      expect(repo.partitionsOf(parent.id), contains(child));
    });

    test('rejects a partition that draws more grams than remain', () {
      final repo = AppRepository();
      final parent = repo.addPurchase(
        description: 'Small lot',
        weightGrams: 10.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 400000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(parent.id, proofPhoto: proofPhoto);

      expect(
        () => repo.createPartition(
          parentId: parent.id,
          description: 'Over-draw',
          type: ItemType.goods,
          weightGrams: 15.0,
          amountCentavos: 100000,
        ),
        throwsArgumentError,
      );
      // Parent must be untouched after a rejected draw.
      final untouched = repo.findItem(parent.id)!;
      expect(untouched.effectiveRemainingGrams, 10.0);
    });

    test('rejects a partition that draws more amount than remains', () {
      final repo = AppRepository();
      final parent = repo.addPurchase(
        description: 'Small lot',
        weightGrams: 10.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 400000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(parent.id, proofPhoto: proofPhoto);

      expect(
        () => repo.createPartition(
          parentId: parent.id,
          description: 'Over-draw',
          type: ItemType.goods,
          weightGrams: 5.0,
          amountCentavos: 500000,
        ),
        throwsArgumentError,
      );
    });

    test('a lot fully drawn down in two partitions reports exhausted', () {
      final repo = AppRepository();
      final parent = repo.addPurchase(
        description: 'Two-way lot',
        weightGrams: 10.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 400000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(parent.id, proofPhoto: proofPhoto);

      repo.createPartition(
        parentId: parent.id,
        description: 'Part A',
        type: ItemType.goods,
        weightGrams: 6.0,
        amountCentavos: 240000,
      );
      expect(repo.findItem(parent.id)!.isExhausted, isFalse);

      repo.createPartition(
        parentId: parent.id,
        description: 'Part B',
        type: ItemType.goods,
        weightGrams: 4.0,
        amountCentavos: 160000,
      );
      final exhausted = repo.findItem(parent.id)!;
      expect(exhausted.effectiveRemainingGrams, 0.0);
      expect(exhausted.effectiveRemainingAmountCentavos, 0);
      expect(exhausted.isExhausted, isTrue);
      expect(repo.partitionsOf(parent.id).length, 2);
    });
  });

  group('deletePartition', () {
    Item seedPartitionedLot(AppRepository repo) {
      final parent = repo.addPurchase(
        description: 'Bulk lot to unwind',
        weightGrams: 50.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 2000000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(parent.id, proofPhoto: proofPhoto);
      return repo.findItem(parent.id)!;
    }

    test('returns the drawn grams and amount to the parent lot', () {
      final repo = AppRepository();
      final parent = seedPartitionedLot(repo);
      final a = repo.createPartition(
        parentId: parent.id,
        description: 'Part A',
        type: ItemType.goods,
        weightGrams: 20.0,
        amountCentavos: 800000,
      );
      repo.createPartition(
        parentId: parent.id,
        description: 'Part B',
        type: ItemType.goods,
        weightGrams: 5.0,
        amountCentavos: 200000,
      );
      expect(repo.findItem(parent.id)!.effectiveRemainingGrams, 25.0);

      repo.deletePartition(a.id);

      final restored = repo.findItem(parent.id)!;
      expect(restored.effectiveRemainingGrams, 45.0);
      expect(restored.effectiveRemainingAmountCentavos, 1800000);
      expect(repo.findItem(a.id), isNull, reason: 'the partition itself is gone');
      expect(repo.partitionsOf(parent.id), hasLength(1));
      // The original figures still stand — one sibling is still drawn out.
      expect(restored.hasPartitions, isTrue);
      expect(restored.effectiveOriginalGrams, 50.0);
    });

    test('returning the last partition makes the lot read as never partitioned', () {
      final repo = AppRepository();
      final parent = seedPartitionedLot(repo);
      final only = repo.createPartition(
        parentId: parent.id,
        description: 'Only part',
        type: ItemType.goods,
        weightGrams: 20.0,
        amountCentavos: 800000,
      );
      expect(repo.findItem(parent.id)!.hasPartitions, isTrue);

      repo.deletePartition(only.id);

      final restored = repo.findItem(parent.id)!;
      expect(restored.hasPartitions, isFalse);
      expect(restored.effectiveRemainingGrams, 50.0);
      expect(restored.effectiveRemainingAmountCentavos, 2000000);
      expect(restored.isExhausted, isFalse);
      expect(repo.partitionsOf(parent.id), isEmpty);
    });

    test('a seed lot recorded at its remainder keeps its full original figures', () {
      // The bulk scrap lot is stored the way real data arrives: weightGrams is already
      // the post-partition remainder (27.5g of an original 42.5g), so the
      // original/remaining fields are the only record of the whole lot.
      // Returning its last partition must hand the grams back, not reset the
      // lot to the remainder it happened to be carrying.
      final repo = AppRepository();
      final lot = repo.findItem('X2P7LN')!;
      expect(lot.weightGrams, 27.5);
      expect(lot.effectiveOriginalGrams, 42.5);

      repo.deletePartition('M9Q4RT');

      final restored = repo.findItem('X2P7LN')!;
      expect(restored.effectiveRemainingGrams, 42.5);
      expect(restored.effectiveRemainingAmountCentavos, 16500000);
      expect(restored.effectiveOriginalGrams, 42.5);
      expect(restored.isExhausted, isFalse);
      expect(repo.partitionsOf('X2P7LN'), isEmpty);
    });

    test('refuses a partition that has already been sold', () {
      final repo = AppRepository();
      final parent = seedPartitionedLot(repo);
      final child = repo.createPartition(
        parentId: parent.id,
        description: 'Sold part',
        type: ItemType.goods,
        weightGrams: 10.0,
        amountCentavos: 400000,
      );
      repo.reserveItem(child.id);
      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: repo.findItem(child.id)!, negotiatedPriceCentavos: 500000)],
        customer: const CustomerDetails(name: 'Buyer'),
        payment: const SalePayment(cashCentavos: 500000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );
      repo.completeSale(sale.id, payment: const SalePayment(cashCentavos: 500000));

      expect(() => repo.deletePartition(child.id), throwsStateError);
      expect(repo.findItem(child.id), isNotNull, reason: 'nothing was removed');
      expect(repo.findItem(parent.id)!.effectiveRemainingGrams, 40.0);
    });

    test('refuses an item that is not a partition at all', () {
      final repo = AppRepository();
      final parent = seedPartitionedLot(repo);
      expect(() => repo.deletePartition(parent.id), throwsArgumentError);
    });

    test('moves no cash — the lot was paid for once, at release', () {
      final repo = AppRepository();
      final parent = seedPartitionedLot(repo);
      final child = repo.createPartition(
        parentId: parent.id,
        description: 'Part',
        type: ItemType.goods,
        weightGrams: 20.0,
        amountCentavos: 800000,
      );
      final balanceBefore = repo.cashBalance(BranchId.kidapawan);
      final entriesBefore = repo.cashEntries.length;

      repo.deletePartition(child.id);

      expect(repo.cashBalance(BranchId.kidapawan), balanceBefore);
      expect(repo.cashEntries, hasLength(entriesBefore));
    });
  });
}
