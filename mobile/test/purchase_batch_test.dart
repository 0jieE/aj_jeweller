// Unit tests for the batch model of purchasing: a transaction is a customer
// visit, verified and paid once, however many pieces it contained.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/data/id_generator.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/purchase_batch.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

PurchaseBatch _threePieceBatch(AppRepository repo) {
  return repo.recordPurchaseBatch(
    customer: const CustomerDetails(
      name: 'Maria Santos',
      contactNumber: '0917 555 0142',
      address: 'Poblacion, Kidapawan City',
    ),
    lines: const [
      PurchaseDraftLine(
        description: '22K necklace',
        grossWeightGrams: 16.4,
        weightGrams: 15.75,
        karat: 22,
        type: ItemType.goods,
        capitalAmountCentavos: 8200000,
      ),
      PurchaseDraftLine(
        description: '18K ring',
        grossWeightGrams: 3.85,
        weightGrams: 3.2,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1350000,
      ),
      PurchaseDraftLine(
        description: 'Broken chain scrap',
        grossWeightGrams: 10.0,
        weightGrams: 10.0,
        karat: 14,
        type: ItemType.scrap,
        capitalAmountCentavos: 450000,
      ),
    ],
    branch: BranchId.kidapawan,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
  );
}

void main() {
  group('recordPurchaseBatch', () {
    test('creates one transaction holding every piece, none of it paid yet', () {
      final repo = AppRepository();
      final before = repo.cashBalance(BranchId.kidapawan);

      final batch = _threePieceBatch(repo);
      final items = repo.itemsInBatch(batch.id);

      expect(items, hasLength(3));
      expect(batch.verificationStatus, VerificationStatus.awaitingVerification);
      expect(repo.batchTotalCentavos(batch.id), 10000000);
      expect(items.every((i) => i.itemStatus == ItemStatus.pending), isTrue);
      expect(items.every((i) => i.batchId == batch.id), isTrue);
      expect(repo.cashBalance(BranchId.kidapawan), before,
          reason: 'cash moves at release, not at entry');
    });

    test('keeps the gross weight alongside the net it is priced on', () {
      final repo = AppRepository();
      final items = repo.itemsInBatch(_threePieceBatch(repo).id);
      final necklace = items.firstWhere((i) => i.description == '22K necklace');

      expect(necklace.weightGrams, 15.75);
      expect(necklace.effectiveGrossWeightGrams, 16.4);
      expect(necklace.deductedGrams, closeTo(0.65, 0.0001));
    });

    test('refuses a purchase with nothing in it', () {
      final repo = AppRepository();
      expect(
        () => repo.recordPurchaseBatch(
          customer: const CustomerDetails(name: 'Nobody'),
          lines: const [],
          branch: BranchId.kidapawan,
          purchaseDate: DateTime.now(),
          submittedByRole: AppUserRole.assistantAppraiser,
        ),
        throwsArgumentError,
      );
    });
  });

  group('releaseBatchCash', () {
    test('pays the customer once for the whole lot and writes one ledger entry', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      final before = repo.cashBalance(BranchId.kidapawan);
      final entriesBefore = repo.cashEntries.length;

      repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier, proofPhoto: proofPhoto);

      expect(repo.cashBalance(BranchId.kidapawan), before - 10000000);
      expect(repo.cashEntries, hasLength(entriesBefore + 1),
          reason: 'one release, one entry — not one per piece');

      final entry = repo.cashEntries.firstWhere((e) => e.linkedRecordId == batch.id);
      expect(entry.amountCentavos, 10000000);
      expect(entry.isManual, isFalse);
    });

    test('verifies every piece and routes each to its post-verification home', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);

      repo.releaseBatchCash(batch.id, proofPhoto: proofPhoto);

      final items = repo.itemsInBatch(batch.id);
      expect(items.every((i) => i.verificationStatus == VerificationStatus.verified), isTrue);
      // Goods go on the shelf; scrap goes to the disposal pool.
      expect(
        items.where((i) => i.type == ItemType.goods).every((i) => i.itemStatus == ItemStatus.listed),
        isTrue,
      );
      expect(
        items.where((i) => i.type == ItemType.scrap).every((i) => i.itemStatus == ItemStatus.forDisposal),
        isTrue,
      );
      expect(repo.findBatch(batch.id)!.releasedAt, isNotNull);
    });

    test('is not paid twice if the release is triggered again', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      repo.releaseBatchCash(batch.id, proofPhoto: proofPhoto);
      final after = repo.cashBalance(BranchId.kidapawan);
      final entries = repo.cashEntries.length;

      repo.releaseBatchCash(batch.id, proofPhoto: proofPhoto);

      expect(repo.cashBalance(BranchId.kidapawan), after);
      expect(repo.cashEntries, hasLength(entries));
    });
  });

  group('returnBatchForCorrection', () {
    test('sends the whole transaction back with a note and moves no cash', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      final before = repo.cashBalance(BranchId.kidapawan);

      repo.returnBatchForCorrection(batch.id, 'Recheck the 18K ring weight');

      final returned = repo.findBatch(batch.id)!;
      expect(returned.verificationStatus, VerificationStatus.returnedForCorrection);
      expect(returned.verificationNote, 'Recheck the 18K ring weight');
      expect(
        repo
            .itemsInBatch(batch.id)
            .every((i) => i.verificationStatus == VerificationStatus.returnedForCorrection),
        isTrue,
      );
      expect(repo.cashBalance(BranchId.kidapawan), before);
      expect(
        repo.purchaseBatchesAwaitingRelease(branchId: BranchId.kidapawan).map((b) => b.id),
        isNot(contains(batch.id)),
      );
    });

    test('fixing one piece puts the whole batch back in the queue', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      repo.returnBatchForCorrection(batch.id, 'Recheck weight');
      final ring = repo.itemsInBatch(batch.id).firstWhere((i) => i.description == '18K ring');

      repo.resubmitItem(
        ring.id,
        description: '18K ring (rechecked)',
        weightGrams: 3.4,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1400000,
        origin: 'Maria Santos',
      );

      final back = repo.findBatch(batch.id)!;
      expect(back.verificationStatus, VerificationStatus.awaitingVerification);
      expect(back.verificationNote, isNull);
      expect(repo.batchTotalCentavos(batch.id), 10050000);
    });
  });

  group('record ids', () {
    test('are six readable characters, with no ambiguous glyphs', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      final allowed = RegExp('^[${IdGenerator.alphabet}]{6}\$');

      for (final id in [batch.id, ...repo.itemsInBatch(batch.id).map((i) => i.id)]) {
        expect(id, hasLength(6));
        expect(allowed.hasMatch(id), isTrue, reason: '$id should avoid 0/O and 1/I');
      }
    });

    test('never collide across record kinds', () {
      final repo = AppRepository();
      for (var i = 0; i < 40; i++) {
        _threePieceBatch(repo);
      }
      final ids = <String>[
        ...repo.items.map((i) => i.id),
        ...repo.purchaseBatches.map((b) => b.id),
        ...repo.sales.map((s) => s.id),
      ];
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('karatBreakdown', () {
    test('grades a disposal batch by karat, highest karat first', () {
      final repo = AppRepository();
      final loan = repo.addCommitment(
        lender: 'Refiner Credit',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(loan.id, proofPhoto: proofPhoto);

      Item scrap(String description, double grams, int karat, int capital) {
        final item = repo.addPurchase(
          description: description,
          weightGrams: grams,
          karat: karat,
          type: ItemType.scrap,
          capitalAmountCentavos: capital,
          origin: 'Bulk',
          branch: BranchId.kidapawan,
          purchaseDate: DateTime.now(),
          submittedByRole: AppUserRole.assistantAppraiser,
        );
        repo.releaseCash(item.id, proofPhoto: proofPhoto);
        return item;
      }

      final a = scrap('18K scrap A', 10, 18, 400000);
      final b = scrap('18K scrap B', 5, 18, 200000);
      final c = scrap('21K scrap', 7, 21, 350000);

      final batch = repo.completeDisposal(
        branch: BranchId.kidapawan,
        itemIds: [a.id, b.id, c.id],
        capitalCentavos: 950000,
        grossGrams: 22,
        grossAmountCentavos: 1200000,
        date: DateTime.now(),
        commitmentRef: loan.id,
      );

      final breakdown = repo.karatBreakdown(batch.id);
      expect(breakdown.map((e) => e.key), [21, 18], reason: 'highest karat first');
      expect(breakdown.firstWhere((e) => e.key == 18).value, 15, reason: 'both 18K lots summed');
      expect(breakdown.firstWhere((e) => e.key == 21).value, 7);
    });
  });

  group('cash release proof', () {
    test('the photo taken at release is kept on the purchase', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      final proof = Uint8List.fromList([4, 2, 0]);

      repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier, proofPhoto: proof);

      expect(repo.findBatch(batch.id)!.releaseProofPhoto, proof);
    });

    test('a release without a photo is refused, and nothing moves', () {
      final repo = AppRepository();
      final batch = _threePieceBatch(repo);
      final before = repo.cashBalance(BranchId.kidapawan);

      expect(
        () => repo.releaseBatchCash(batch.id, recordedByRole: AppUserRole.cashier),
        throwsA(isA<ArgumentError>()),
      );

      final untouched = repo.findBatch(batch.id)!;
      expect(untouched.releasedAt, isNull);
      expect(untouched.verificationStatus, VerificationStatus.awaitingVerification);
      expect(repo.cashBalance(BranchId.kidapawan), before);
    });
  });
}
