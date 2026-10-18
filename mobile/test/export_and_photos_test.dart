// Unit tests for CSV exports and the photos filed on partitions, loan cash
// receipts, and disposals.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/services/export_service.dart';
import 'support/proof_photo.dart';

void main() {
  final photo = Uint8List.fromList([9, 8, 7]);

  group('exports', () {
    test('purchases export one row per purchased lot, with a matching total', () {
      final repo = AppRepository();
      final table = ExportService.build(repo, ExportKind.purchases, branch: BranchId.kidapawan, range: null);

      final lots = repo
          .purchaseBatchesForBranch(BranchId.kidapawan)
          .expand((b) => repo.itemsInBatch(b.id).where((i) => !i.isPartitioned))
          .toList();
      expect(table.rows, hasLength(lots.length));
      expect(table.totalCentavos, lots.fold<int>(0, (s, i) => s + i.effectiveOriginalAmountCentavos));
      expect(table.rows.every((r) => r.length == table.headers.length), isTrue);
    });

    test('sales export one row per line item', () {
      final repo = AppRepository();
      final table = ExportService.build(repo, ExportKind.sales, branch: null, range: null);
      final lines = repo.sales.fold<int>(0, (s, sale) => s + sale.lineItems.length);
      expect(table.rows, hasLength(lines));
    });

    test('expenses and withdrawals export only their own entry type, within the date range', () {
      final repo = AppRepository();
      final today = DateTime.now();
      repo.recordCashEntry(
        branch: BranchId.davao,
        type: CashEntryType.expense,
        account: CashAccount.sales,
        amountCentavos: 120000,
        note: 'Electric bill, August',
        category: 'Utilities',
        date: today,
        recordedByRole: AppUserRole.admin,
      );
      repo.recordCashEntry(
        branch: BranchId.davao,
        type: CashEntryType.withdrawal,
        amountCentavos: 50000,
        note: 'Owner draw',
        date: today,
        recordedByRole: AppUserRole.admin,
      );
      final range = DateTimeRange(start: DateTime(today.year, today.month, today.day), end: DateTime(today.year, today.month, today.day));

      final expenses = ExportService.build(repo, ExportKind.expenses, branch: BranchId.davao, range: range);
      final withdrawals = ExportService.build(repo, ExportKind.withdrawals, branch: BranchId.davao, range: range);

      expect(expenses.rows.where((r) => r.contains('Electric bill, August')), hasLength(1));
      expect(expenses.rows.every((r) => !r.contains('Owner draw')), isTrue);
      expect(withdrawals.rows.single, contains('Owner draw'));
      expect(withdrawals.totalCentavos, 50000);
    });

    test('CSV quotes cells with commas and starts with a BOM', () {
      const table = ExportTable(headers: ['A', 'B'], rows: [['x, y', 'say "hi"']], totalCentavos: 0);
      final bytes = table.toCsvBytes();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      final text = utf8.decode(bytes.skip(3).toList());
      expect(text, contains('"x, y","say ""hi"""'));
    });
  });

  group('photos', () {
    test('a partition keeps its photo', () {
      final repo = AppRepository();
      final lot = repo.items.firstWhere((i) =>
          i.type == ItemType.scrap && i.itemStatus == ItemStatus.forDisposal && !i.isPartitioned && i.effectiveRemainingGrams > 2);
      final child = repo.createPartition(
        parentId: lot.id,
        description: 'Cut piece',
        type: ItemType.scrap,
        weightGrams: 1,
        amountCentavos: 100,
        photo: photo,
      );
      expect(repo.findItem(child.id)!.photo, photo);
    });

    test('loan cash received keeps its proof photo', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Proof Lender',
        amountCentavos: 1000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.davao,
      );
      repo.receiveCommitmentCash(c.id, proofPhoto: photo);
      expect(repo.findCommitment(c.id)!.receivedProofPhoto, photo);
    });

    test('a disposal batch keeps its photo', () {
      final repo = AppRepository();
      final item = repo.itemsForDisposal(branchId: BranchId.kidapawan).first;
      final loan = repo.addCommitment(
        lender: 'Disposal Lender',
        amountCentavos: 50000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.kidapawan,
      );
      repo.receiveCommitmentCash(loan.id, proofPhoto: proofPhoto);
      final batch = repo.completeDisposal(
        branch: BranchId.kidapawan,
        itemIds: [item.id],
        capitalCentavos: item.effectiveRemainingAmountCentavos,
        grossGrams: item.effectiveRemainingGrams,
        grossAmountCentavos: 100000,
        date: DateTime.now(),
        commitmentRef: loan.id,
        photo: photo,
      );
      expect(repo.findDisposalBatch(batch.id)!.photo, photo);
    });
  });
}
