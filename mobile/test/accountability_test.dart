// Unit tests for accountability: real people on records, the append-only
// transaction log, and admin corrections — including how a correction to a
// partition or a partitioned lot keeps the two sides consistent.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/data/staff_directory.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/transaction_log.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/state/app_state.dart';
import 'support/proof_photo.dart';

final _liza = StaffDirectory.byId('USR-K-APR')!; // Kidapawan appraiser
final _grace = StaffDirectory.byId('USR-K-CSH')!; // Kidapawan cashier
final _rhea = StaffDirectory.byId('USR-K-REP')!; // Kidapawan sales rep
final _arnel = StaffDirectory.admin;

Item _released(AppRepository repo, {double grams = 50, int amount = 2000000, ItemType type = ItemType.scrap}) {
  final item = repo.addPurchase(
    description: 'Test lot',
    weightGrams: grams,
    karat: 18,
    type: type,
    capitalAmountCentavos: amount,
    origin: 'Walk-in',
    branch: BranchId.kidapawan,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
    actor: _liza,
  );
  repo.releaseCash(item.id, actor: _grace, proofPhoto: proofPhoto);
  return repo.findItem(item.id)!;
}

void main() {
  group('real people on records', () {
    test('a purchase names who encoded it and who released the cash', () {
      final repo = AppRepository();
      final item = _released(repo);
      final batch = repo.findBatch(item.batchId!)!;

      expect(item.encodedByUserId, _liza.id);
      expect(batch.submittedByUserId, _liza.id);
      expect(batch.releasedByUserId, _grace.id);
      expect(batch.releasedByUserId, isNot(batch.submittedByUserId),
          reason: 'encoder and releaser are the two sides of the control');

      final entry = repo.cashEntries.firstWhere((e) => e.linkedRecordId == batch.id);
      expect(entry.recordedByUserId, _grace.id);
    });

    test('a sale names who sold it and who took the money', () {
      final repo = AppRepository();
      final item = _released(repo, type: ItemType.goods);
      repo.reserveItem(item.id);
      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: repo.findItem(item.id)!, negotiatedPriceCentavos: 2500000)],
        customer: const CustomerDetails(name: 'Buyer'),
        payment: const SalePayment.cash(2500000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
        actor: _rhea,
      );
      repo.completeSale(sale.id, payment: const SalePayment.cash(2500000), actor: _grace);

      final done = repo.findSale(sale.id)!;
      expect(done.submittedByUserId, _rhea.id);
      expect(done.receivedByUserId, _grace.id);
    });

    test('every seeded purchase and sale names a real person', () {
      final repo = AppRepository();
      for (final batch in repo.purchaseBatches) {
        expect(StaffDirectory.byId(batch.submittedByUserId), isNotNull, reason: batch.id);
        if (batch.verificationStatus == VerificationStatus.verified) {
          expect(StaffDirectory.byId(batch.releasedByUserId), isNotNull, reason: batch.id);
        }
      }
      for (final sale in repo.sales) {
        expect(StaffDirectory.byId(sale.submittedByUserId), isNotNull, reason: sale.id);
      }
    });
  });

  group('session', () {
    test('signing in as branch staff opens on their branch', () {
      final state = AppState();
      state.setUser(StaffDirectory.byId('USR-D-CSH')!);

      expect(state.role, AppUserRole.cashier);
      expect(state.selectedBranch, BranchId.davao);
    });

    test('switching role picks the person holding it at the branch in view', () {
      final state = AppState(initialBranch: BranchId.davao);
      state.setRole(AppUserRole.salesRep);

      expect(state.currentUser.id, 'USR-D-REP');
    });
  });

  group('transaction log', () {
    test('each step of a purchase appends an entry naming the person', () {
      final repo = AppRepository();
      final before = repo.logs.length;
      final item = _released(repo);

      final entries = repo.logsForRecord(item.batchId!);
      expect(entries.map((e) => e.action), [LogAction.purchaseRecorded, LogAction.cashReleased]);
      expect(entries.first.userName, _liza.name);
      expect(entries.last.userName, _grace.name);
      expect(repo.logs.length, before + 2);
    });

    test('the seeded log only ever points at records that exist', () {
      final repo = AppRepository();
      expect(repo.logs, isNotEmpty, reason: 'the page should open on history, not nothing');

      for (final log in repo.logs) {
        switch (log.recordKind) {
          case LogRecordKind.purchaseBatch:
            expect(repo.findBatch(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.item:
            expect(repo.findItem(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.sale:
            expect(repo.findSale(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.disposal:
            expect(repo.findDisposalBatch(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.commitment:
            expect(repo.findCommitment(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.customer:
            expect(repo.findCustomer(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.user:
            expect(repo.findUser(log.recordId!), isNotNull, reason: log.summary);
          case LogRecordKind.cashEntry:
          case null:
            break;
        }
      }
    });

    test('a branch view keeps company-wide entries in sight', () {
      final repo = AppRepository();
      repo.updateGoldRate(18, 470000, actor: _arnel);

      expect(
        repo.logsForBranch(BranchId.davao).any((l) => l.action == LogAction.goldRateUpdated),
        isTrue,
      );
    });
  });

  group('admin corrections', () {
    test('a plain correction records before and after, and moves no cash', () {
      final repo = AppRepository();
      final item = _released(repo, grams: 10, amount: 500000);
      final cashBefore = repo.cashBalance(BranchId.kidapawan);

      final changes = repo.updateItem(
        item.id,
        description: 'Test lot (reweighed)',
        weightGrams: 9.5,
        capitalAmountCentavos: 480000,
        actor: _arnel,
      );

      final fixed = repo.findItem(item.id)!;
      expect(fixed.weightGrams, 9.5);
      expect(fixed.capitalAmountCentavos, 480000);
      expect(changes.map((c) => c.field), containsAll(['Description', 'Final weight', 'Amount']));
      expect(repo.cashBalance(BranchId.kidapawan), cashBefore,
          reason: 'an edit never fabricates a cash movement');

      final log = repo.logsForRecord(item.id).last;
      expect(log.action, LogAction.itemEdited);
      expect(log.userName, _arnel.name);
      expect(log.summary, contains('not moved in the ledger'));
    });

    test('changing a partition takes the difference from its lot', () {
      final repo = AppRepository();
      final lot = _released(repo, grams: 50, amount: 2000000);
      final piece = repo.createPartition(
        parentId: lot.id,
        description: 'Piece',
        type: ItemType.goods,
        weightGrams: 20,
        amountCentavos: 800000,
      );
      expect(repo.findItem(lot.id)!.effectiveRemainingGrams, 30);

      repo.updateItem(piece.id, weightGrams: 22, capitalAmountCentavos: 900000, actor: _arnel);

      final parent = repo.findItem(lot.id)!;
      expect(parent.effectiveRemainingGrams, 28);
      expect(parent.effectiveRemainingAmountCentavos, 1100000);
      expect(parent.effectiveOriginalGrams, 50, reason: 'what was bought does not change');
    });

    test('a partition cannot take more than its lot has left', () {
      final repo = AppRepository();
      final lot = _released(repo, grams: 50, amount: 2000000);
      final piece = repo.createPartition(
        parentId: lot.id,
        description: 'Piece',
        type: ItemType.goods,
        weightGrams: 45,
        amountCentavos: 1800000,
      );

      expect(
        () => repo.updateItem(piece.id, weightGrams: 60, actor: _arnel),
        throwsArgumentError,
      );
      expect(repo.findItem(piece.id)!.weightGrams, 45, reason: 'a refused edit changes nothing');
      expect(repo.findItem(lot.id)!.effectiveRemainingGrams, 5);
    });

    test('correcting a partitioned lot keeps what was drawn and moves the remainder', () {
      final repo = AppRepository();
      final lot = _released(repo, grams: 50, amount: 2000000);
      repo.createPartition(
        parentId: lot.id,
        description: 'Piece',
        type: ItemType.goods,
        weightGrams: 20,
        amountCentavos: 800000,
      );

      repo.updateItem(lot.id, weightGrams: 52, capitalAmountCentavos: 2100000, actor: _arnel);

      final fixed = repo.findItem(lot.id)!;
      expect(fixed.effectiveOriginalGrams, 52);
      expect(fixed.effectiveRemainingGrams, 32);
      expect(fixed.effectiveRemainingAmountCentavos, 1300000);
    });

    test('a lot cannot be corrected below what has already been drawn out', () {
      final repo = AppRepository();
      final lot = _released(repo, grams: 50, amount: 2000000);
      repo.createPartition(
        parentId: lot.id,
        description: 'Piece',
        type: ItemType.goods,
        weightGrams: 40,
        amountCentavos: 1600000,
      );

      expect(() => repo.updateItem(lot.id, weightGrams: 30, actor: _arnel), throwsArgumentError);
    });

    test('a lot\'s karat carries to its partitions, and a partition cannot set its own', () {
      final repo = AppRepository();
      final lot = _released(repo);
      final piece = repo.createPartition(
        parentId: lot.id,
        description: 'Piece',
        type: ItemType.goods,
        weightGrams: 10,
        amountCentavos: 400000,
      );

      expect(() => repo.updateItem(piece.id, karat: 21, actor: _arnel), throwsArgumentError);

      repo.updateItem(lot.id, karat: 21, actor: _arnel);
      expect(repo.findItem(lot.id)!.karat, 21);
      expect(repo.findItem(piece.id)!.karat, 21);
    });

    test('a type change moves the piece between shelf and disposal pool', () {
      final repo = AppRepository();
      final item = _released(repo, type: ItemType.goods);
      expect(item.itemStatus, ItemStatus.listed);

      repo.updateItem(item.id, type: ItemType.scrap, actor: _arnel);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.forDisposal);
    });

    test('a disposed piece is closed to corrections', () {
      final repo = AppRepository();
      final disposed = repo.items.firstWhere((i) => i.itemStatus == ItemStatus.disposed);

      expect(repo.canEditItem(disposed), isFalse);
      expect(() => repo.updateItem(disposed.id, description: 'x', actor: _arnel), throwsStateError);
    });

    test('a correction that changes nothing writes nothing', () {
      final repo = AppRepository();
      final item = _released(repo);
      final logsBefore = repo.logs.length;

      final changes = repo.updateItem(item.id, description: item.description, actor: _arnel);

      expect(changes, isEmpty);
      expect(repo.logs.length, logsBefore);
    });
  });

  test('resubmitting a returned item keeps its photo', () {
    final repo = AppRepository();
    final item = repo.addPurchase(
      description: 'Ring',
      weightGrams: 3,
      karat: 18,
      type: ItemType.goods,
      capitalAmountCentavos: 150000,
      origin: 'Walk-in',
      branch: BranchId.kidapawan,
      purchaseDate: DateTime.now(),
      submittedByRole: AppUserRole.assistantAppraiser,
      actor: _liza,
    );
    repo.setItemPhoto(item.id, Uint8List.fromList([9, 9, 9]), actor: _liza);
    repo.returnForCorrection(item.id, 'Recheck weight', actor: _grace);

    repo.resubmitItem(
      item.id,
      description: 'Ring',
      weightGrams: 3.1,
      karat: 18,
      type: ItemType.goods,
      capitalAmountCentavos: 155000,
      origin: 'Walk-in',
      actor: _liza,
    );

    final resubmitted = repo.findItem(item.id)!;
    expect(resubmitted.photo, [9, 9, 9]);
    expect(resubmitted.encodedByUserId, _liza.id);
  });
}
