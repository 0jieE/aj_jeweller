// Unit tests for the cash ledger: the seed backfill's exact reconciliation
// with the figures the Dashboard showed before this feature existed, manual
// entry recording, atomic transfers, and that every existing cash-moving
// flow (purchase release, cash sale, commitment receipt) now writes a
// linked ledger entry instead of touching a branch balance directly.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

void main() {
  group('seed backfill reconciliation', () {
    test('cashBalance matches the exact figures the app showed before the cash ledger existed', () {
      final repo = AppRepository();
      // These are the Dashboard's original hardcoded "current balance"
      // figures. The cash ledger refactor must not move them — if this
      // test ever fails, the backfill (not the app) is wrong.
      expect(repo.cashBalance(BranchId.kidapawan), 103790300);
      expect(repo.cashBalance(BranchId.davao), 69416900);

      // The figures above are the headline ones, but the invariant is what
      // actually matters and survives seed edits: every balance is its
      // starting figure plus its own ledger, with nothing unaccounted for.
      for (final branch in BranchId.values) {
        for (final account in CashAccount.values) {
          final net = repo
              .cashEntriesForBranch(branch, account: account)
              .fold<int>(0, (sum, e) => sum + e.signedAmountCentavos);
          expect(
            repo.accountBalance(branch, account),
            repo.startingBalance(branch, account) + net,
            reason: '${branch.label} ${account.label} must reconcile to its own entries',
          );
        }
      }
    });

    test('every seed cash entry is linked to a source record, none are manual', () {
      final repo = AppRepository();
      expect(repo.cashEntries, isNotEmpty);
      expect(repo.cashEntries.every((e) => !e.isManual), isTrue);
    });
  });

  group('recordCashEntry', () {
    test('cash-in increases the branch balance and appears in the ledger', () {
      final repo = AppRepository();
      final before = repo.cashBalance(BranchId.kidapawan);

      final entry = repo.recordCashEntry(
        branch: BranchId.kidapawan,
        type: CashEntryType.cashIn,
        amountCentavos: 500000,
        note: 'Owner capital injection',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );

      expect(repo.cashBalance(BranchId.kidapawan), before + 500000);
      expect(repo.cashEntriesForBranch(BranchId.kidapawan), contains(entry));
      expect(entry.isManual, isTrue);
    });

    test('expense and withdrawal both decrease the branch balance', () {
      final repo = AppRepository();
      final before = repo.cashBalance(BranchId.davao);

      repo.recordCashEntry(
        branch: BranchId.davao,
        type: CashEntryType.expense,
        amountCentavos: 200000,
        note: 'Electricity bill',
        category: 'Utilities',
        date: DateTime.now(),
        recordedByRole: AppUserRole.cashier,
      );
      expect(repo.cashBalance(BranchId.davao), before - 200000);

      repo.recordCashEntry(
        branch: BranchId.davao,
        type: CashEntryType.withdrawal,
        amountCentavos: 100000,
        note: 'Owner personal withdrawal',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );
      expect(repo.cashBalance(BranchId.davao), before - 300000);
    });

    test('rejects a transfer type — recordTransfer must be used instead', () {
      final repo = AppRepository();
      expect(
        () => repo.recordCashEntry(
          branch: BranchId.kidapawan,
          type: CashEntryType.transferOut,
          amountCentavos: 100000,
          note: 'Should not be allowed',
          date: DateTime.now(),
          recordedByRole: AppUserRole.admin,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('recordTransfer', () {
    test('moves cash atomically: source decreases, destination increases, by the same amount', () {
      final repo = AppRepository();
      final kidapawanBefore = repo.cashBalance(BranchId.kidapawan);
      final davaoBefore = repo.cashBalance(BranchId.davao);

      final (out, inn) = repo.recordTransfer(
        from: BranchId.kidapawan,
        to: BranchId.davao,
        amountCentavos: 300000,
        note: 'Rebalancing branch float',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );

      expect(repo.cashBalance(BranchId.kidapawan), kidapawanBefore - 300000);
      expect(repo.cashBalance(BranchId.davao), davaoBefore + 300000);
      expect(out.transferPairId, isNotNull);
      expect(out.transferPairId, inn.transferPairId);
      expect(out.type, CashEntryType.transferOut);
      expect(inn.type, CashEntryType.transferIn);
    });

    test('never changes the combined total across both branches', () {
      final repo = AppRepository();
      final combinedBefore = repo.combinedCashBalance();

      repo.recordTransfer(
        from: BranchId.davao,
        to: BranchId.kidapawan,
        amountCentavos: 750000,
        note: 'Moving float to Kidapawan',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );

      expect(repo.combinedCashBalance(), combinedBefore);
    });
  });

  group('linked entries from existing flows', () {
    test('releaseCash writes a linked expense entry instead of mutating a stored balance', () {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: 'Test ring',
        weightGrams: 3.0,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 500000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      final before = repo.cashBalance(BranchId.kidapawan);

      repo.releaseCash(item.id, recordedByRole: AppUserRole.cashier, proofPhoto: proofPhoto);

      expect(repo.cashBalance(BranchId.kidapawan), before - 500000);
      // Cash moves per purchase batch — a customer is paid once for
      // everything they brought in — so the entry names the batch.
      final linked = repo.cashEntriesForBranch(BranchId.kidapawan)
          .firstWhere((e) => e.linkedRecordId == item.batchId);
      expect(linked.type, CashEntryType.expense);
      expect(linked.sourceType, CashEntrySourceType.purchase);
      expect(linked.isManual, isFalse);
      expect(linked.recordedByRole, AppUserRole.cashier);
    });

    test('completeSale with cash writes a linked cash-in entry', () {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: 'Test bangle',
        weightGrams: 5.0,
        karat: 21,
        type: ItemType.goods,
        capitalAmountCentavos: 700000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(item.id, proofPhoto: proofPhoto);
      repo.reserveItem(item.id);
      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 900000)],
        customer: const CustomerDetails(name: 'Test Customer'),
        payment: const SalePayment(cashCentavos: 900000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );
      final before = repo.salesCashBalance(BranchId.kidapawan);

      repo.completeSale(sale.id, payment: const SalePayment(cashCentavos: 900000), recordedByRole: AppUserRole.cashier);

      expect(repo.salesCashBalance(BranchId.kidapawan), before + 900000);
      final linked = repo.cashEntriesForBranch(BranchId.kidapawan)
          .firstWhere((e) => e.linkedRecordId == sale.id);
      expect(linked.type, CashEntryType.cashIn);
      expect(linked.account, CashAccount.sales);
      expect(linked.sourceType, CashEntrySourceType.sale);
    });

    test('completeSale with a non-cash method writes only a bank entry', () {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: 'Test earrings',
        weightGrams: 2.0,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 300000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(item.id, proofPhoto: proofPhoto);
      repo.reserveItem(item.id);
      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 900000)],
        customer: const CustomerDetails(name: 'GCash Customer'),
        payment: const SalePayment(bankCentavos: 900000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );
      final before = repo.cashBalance(BranchId.kidapawan);
      final salesBefore = repo.salesCashBalance(BranchId.kidapawan);
      final bankBefore = repo.bankBalance(BranchId.kidapawan);

      repo.completeSale(sale.id, payment: const SalePayment(bankCentavos: 900000));

      expect(repo.cashBalance(BranchId.kidapawan), before);
      expect(repo.salesCashBalance(BranchId.kidapawan), salesBefore);
      expect(repo.bankBalance(BranchId.kidapawan), bankBefore + 900000);
    });

    test('receiveCommitmentCash for a branch-specific commitment writes a linked cash-in entry', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Test Lender',
        amountCentavos: 1000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: BranchId.davao,
      );
      final before = repo.cashBalance(BranchId.davao);

      repo.receiveCommitmentCash(c.id, recordedByRole: AppUserRole.admin, proofPhoto: proofPhoto);

      expect(repo.cashBalance(BranchId.davao), before + 1000000);
      final linked = repo.cashEntriesForBranch(BranchId.davao)
          .firstWhere((e) => e.linkedRecordId == c.id);
      expect(linked.sourceType, CashEntrySourceType.commitment);
    });

    test('receiveCommitmentCash for a company-wide commitment writes no ledger entry', () {
      final repo = AppRepository();
      final c = repo.addCommitment(
        lender: 'Company Lender',
        amountCentavos: 1000000,
        ratePerGramCentavos: 500000,
        dateApproved: DateTime.now(),
        branch: null,
      );
      final entryCountBefore = repo.cashEntries.length;

      repo.receiveCommitmentCash(c.id, proofPhoto: proofPhoto);

      expect(repo.cashEntries.length, entryCountBefore);
    });
  });

  group('reset behavior', () {
    test('resetToEmpty clears every cash entry alongside the other records', () {
      final repo = AppRepository();
      expect(repo.cashEntries, isNotEmpty);

      repo.resetToEmpty();

      expect(repo.cashEntries, isEmpty);
      expect(repo.cashBalance(BranchId.kidapawan), 0);
      expect(repo.cashBalance(BranchId.davao), 0);
    });

    test('resetToSeed restores the backfilled entries and the exact reconciled balances', () {
      final repo = AppRepository();
      repo.resetToEmpty();

      repo.resetToSeed();

      expect(repo.cashBalance(BranchId.kidapawan), 103790300);
      expect(repo.cashBalance(BranchId.davao), 69416900);
    });
  });

  group('three cash sources', () {
    test('each account balances on its own; the seed keeps the float where it was', () {
      final repo = AppRepository();
      expect(repo.salesCashBalance(BranchId.kidapawan), 11500000);
      expect(repo.bankBalance(BranchId.kidapawan), 25850000);
      expect(repo.bankBalance(BranchId.davao), 18420000);
    });

    test('a manual expense can come out of any source', () {
      final repo = AppRepository();
      final bankBefore = repo.bankBalance(BranchId.davao);
      final floatBefore = repo.cashBalance(BranchId.davao);

      repo.recordCashEntry(
        branch: BranchId.davao,
        type: CashEntryType.expense,
        account: CashAccount.bank,
        amountCentavos: 150000,
        note: 'Bank charges',
        category: 'Other',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );

      expect(repo.bankBalance(BranchId.davao), bankBefore - 150000);
      expect(repo.cashBalance(BranchId.davao), floatBefore);
    });

    test('a transfer can move money between sources within one branch', () {
      final repo = AppRepository();
      final salesBefore = repo.salesCashBalance(BranchId.kidapawan);
      final floatBefore = repo.cashBalance(BranchId.kidapawan);

      final (out, inn) = repo.recordTransfer(
        from: BranchId.kidapawan,
        fromAccount: CashAccount.sales,
        to: BranchId.kidapawan,
        toAccount: CashAccount.purchase,
        amountCentavos: 5000000,
        note: 'Top up purchase float from takings',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );

      expect(out.account, CashAccount.sales);
      expect(inn.account, CashAccount.purchase);
      expect(repo.salesCashBalance(BranchId.kidapawan), salesBefore - 5000000);
      expect(repo.cashBalance(BranchId.kidapawan), floatBefore + 5000000);
    });

    test('a transfer across branches can land in a different source', () {
      final repo = AppRepository();
      final bankBefore = repo.bankBalance(BranchId.davao);
      final kidFloatBefore = repo.cashBalance(BranchId.kidapawan);

      repo.recordTransfer(
        from: BranchId.kidapawan,
        fromAccount: CashAccount.purchase,
        to: BranchId.davao,
        toAccount: CashAccount.bank,
        amountCentavos: 100000,
        note: 'Deposit to Davao account',
        date: DateTime.now(),
        recordedByRole: AppUserRole.admin,
      );

      expect(repo.cashBalance(BranchId.kidapawan), kidFloatBefore - 100000);
      expect(repo.bankBalance(BranchId.davao), bankBefore + 100000);
    });

    test('a transfer to the same branch and the same source is refused', () {
      final repo = AppRepository();
      expect(
        () => repo.recordTransfer(
          from: BranchId.davao,
          to: BranchId.davao,
          fromAccount: CashAccount.bank,
          toAccount: CashAccount.bank,
          amountCentavos: 100,
          note: 'nowhere',
          date: DateTime.now(),
          recordedByRole: AppUserRole.admin,
        ),
        throwsArgumentError,
      );
    });
  });

  test('cashFlowOn totals money in and out per source', () {
    final repo = AppRepository();
    final before = repo.cashFlowOn(BranchId.davao, CashAccount.sales);
    repo.recordCashEntry(
      branch: BranchId.davao,
      type: CashEntryType.cashIn,
      account: CashAccount.sales,
      amountCentavos: 300000,
      note: 'Walk-in',
      date: DateTime.now(),
      recordedByRole: AppUserRole.cashier,
    );
    repo.recordCashEntry(
      branch: BranchId.davao,
      type: CashEntryType.expense,
      account: CashAccount.sales,
      amountCentavos: 50000,
      note: 'Snacks',
      category: 'Other',
      date: DateTime.now(),
      recordedByRole: AppUserRole.cashier,
    );
    repo.recordCashEntry(
      branch: BranchId.davao,
      type: CashEntryType.expense,
      account: CashAccount.sales,
      amountCentavos: 99900,
      note: 'Last week',
      category: 'Other',
      date: DateTime.now().subtract(const Duration(days: 7)),
      recordedByRole: AppUserRole.cashier,
    );
    final after = repo.cashFlowOn(BranchId.davao, CashAccount.sales);
    expect(after.inCentavos - before.inCentavos, 300000);
    expect(after.outCentavos - before.outCentavos, 50000);
  });
}
