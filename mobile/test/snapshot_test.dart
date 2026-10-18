// Unit tests for saving and restoring all shop data between launches.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';

/// Save to JSON text and load into a brand-new repository, as a restart does.
AppRepository _restart(AppRepository repo) {
  final text = jsonEncode(repo.toSnapshot());
  final fresh = AppRepository();
  fresh.restoreSnapshot(jsonDecode(text) as Map<String, dynamic>);
  return fresh;
}

void main() {
  test('the demo data survives a restart unchanged', () {
    final repo = AppRepository();
    final back = _restart(repo);

    expect(back.items.length, repo.items.length);
    expect(back.sales.length, repo.sales.length);
    expect(back.purchaseBatches.length, repo.purchaseBatches.length);
    expect(back.cashEntries.length, repo.cashEntries.length);
    expect(back.customers.length, repo.customers.length);
    expect(back.logs.length, repo.logs.length);
    expect(back.goldRates.length, repo.goldRates.length);
    for (final b in BranchId.values) {
      for (final a in CashAccount.values) {
        expect(back.accountBalance(b, a), repo.accountBalance(b, a), reason: '${b.name} ${a.name}');
      }
    }
  });

  test('Start Empty stays empty after a restart, with new work kept', () {
    final repo = AppRepository()..resetToEmpty();
    repo.recordCashEntry(
      branch: BranchId.davao,
      type: CashEntryType.cashIn,
      account: CashAccount.bank,
      amountCentavos: 1234500,
      note: 'Opening deposit',
      date: DateTime.now(),
      recordedByRole: AppUserRole.admin,
    );
    final photo = Uint8List.fromList(List.generate(50, (i) => i));
    final customer = repo.upsertCustomer(CustomerDetails(name: 'Kept Customer', photo: photo));

    final back = _restart(repo);

    expect(back.items, isEmpty);
    expect(back.sales, isEmpty);
    expect(back.cashEntries, hasLength(1));
    expect(back.bankBalance(BranchId.davao), 1234500);
    expect(back.findCustomer(customer.id)!.photo, photo);
  });

  test('an unfinished cart reservation is released on restart, an open order keeps its items', () {
    final repo = AppRepository();
    final goods = repo.sellableGoods(branchId: BranchId.kidapawan, silver: false);
    final inCart = goods[0];
    final inOrder = goods[1];
    repo.reserveItem(inCart.id);
    repo.reserveItem(inOrder.id);
    repo.checkoutSale(
      lineItems: [SaleLineItem(item: repo.findItem(inOrder.id)!, negotiatedPriceCentavos: 500000)],
      customer: const CustomerDetails(name: 'Order Customer'),
      payment: const SalePayment(cashCentavos: 500000),
      branch: BranchId.kidapawan,
      submittedByRole: AppUserRole.salesRep,
    );

    final back = _restart(repo);

    expect(back.findItem(inCart.id)!.itemStatus, ItemStatus.listed);
    expect(back.findItem(inOrder.id)!.itemStatus, ItemStatus.reserved);
  });

  test('a snapshot missing a branch is refused and leaves the data untouched', () {
    final repo = AppRepository();
    final before = repo.items.length;
    final broken = repo.toSnapshot()..['branches'] = <Object>[];
    expect(() => repo.restoreSnapshot(broken), throwsFormatException);
    expect(repo.items.length, before);
  });
}
