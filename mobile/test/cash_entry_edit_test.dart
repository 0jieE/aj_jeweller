// Unit tests for correcting and deleting hand-typed cash entries, and that
// every correction lands in the transaction log.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';
import 'package:davao_aj_jewellers/core/models/transaction_log.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';

CashEntry _expense(AppRepository repo) => repo.recordCashEntry(
      branch: BranchId.davao,
      type: CashEntryType.expense,
      amountCentavos: 500000,
      note: 'Electric bill',
      category: 'Utilities',
      date: DateTime.now(),
      recordedByRole: AppUserRole.cashier,
    );

void main() {
  test('editing an entry moves the balance and logs before/after', () {
    final repo = AppRepository();
    final before = repo.cashBalance(BranchId.davao);
    final entry = _expense(repo);

    final changes = repo.updateCashEntry(entry.id, amountCentavos: 50000, note: 'Electric bill (typo fixed)');

    expect(changes.map((c) => c.field), containsAll(['Amount', 'Note']));
    expect(repo.cashBalance(BranchId.davao), before - 50000);
    final log = repo.logs.first;
    expect(log.action, LogAction.cashEntryEdited);
    expect(log.recordId, entry.id);
    expect(log.changes.firstWhere((c) => c.field == 'Amount').before, contains('5,000'));
  });

  test('moving an entry to another cash source moves the money with it', () {
    final repo = AppRepository();
    final entry = _expense(repo);
    final salesBefore = repo.salesCashBalance(BranchId.davao);
    final floatBefore = repo.cashBalance(BranchId.davao);

    repo.updateCashEntry(entry.id, account: CashAccount.sales);

    expect(repo.cashBalance(BranchId.davao), floatBefore + 500000);
    expect(repo.salesCashBalance(BranchId.davao), salesBefore - 500000);
  });

  test('changing an expense to a withdrawal drops its category', () {
    final repo = AppRepository();
    final entry = _expense(repo);
    repo.updateCashEntry(entry.id, type: CashEntryType.withdrawal);
    final updated = repo.findCashEntry(entry.id)!;
    expect(updated.type, CashEntryType.withdrawal);
    expect(updated.category, isNull);
  });

  test('deleting an entry restores the balance and is logged with a reason', () {
    final repo = AppRepository();
    final before = repo.cashBalance(BranchId.davao);
    final entry = _expense(repo);

    repo.deleteCashEntry(entry.id, reason: 'entered twice');

    expect(repo.cashBalance(BranchId.davao), before);
    expect(repo.findCashEntry(entry.id), isNull);
    final log = repo.logs.first;
    expect(log.action, LogAction.cashEntryDeleted);
    expect(log.summary, contains('entered twice'));
    expect(log.changes, isNotEmpty);
  });

  test('a transfer is edited and deleted as one', () {
    final repo = AppRepository();
    final kidBefore = repo.cashBalance(BranchId.kidapawan);
    final davBefore = repo.bankBalance(BranchId.davao);
    final (out, inn) = repo.recordTransfer(
      from: BranchId.kidapawan,
      to: BranchId.davao,
      toAccount: CashAccount.bank,
      amountCentavos: 300000,
      note: 'Deposit',
      date: DateTime.now(),
      recordedByRole: AppUserRole.admin,
    );

    repo.updateCashEntry(inn.id, amountCentavos: 200000);
    expect(repo.findCashEntry(out.id)!.amountCentavos, 200000);
    expect(repo.findCashEntry(inn.id)!.amountCentavos, 200000);
    expect(repo.cashBalance(BranchId.kidapawan), kidBefore - 200000);

    repo.deleteCashEntry(out.id);
    expect(repo.findCashEntry(inn.id), isNull);
    expect(repo.cashBalance(BranchId.kidapawan), kidBefore);
    expect(repo.bankBalance(BranchId.davao), davBefore);
  });

  test('entries written by a purchase, sale, or loan cannot be edited or deleted', () {
    final repo = AppRepository();
    final linked = repo.cashEntries.firstWhere((e) => !e.isManual);
    expect(repo.cashEntryLockReason(linked), isNotNull);
    expect(() => repo.updateCashEntry(linked.id, amountCentavos: 1), throwsStateError);
    expect(() => repo.deleteCashEntry(linked.id), throwsStateError);
  });
}
