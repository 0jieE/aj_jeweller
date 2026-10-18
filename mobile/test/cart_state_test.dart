// Unit tests for CartState — the app-level cart that must survive
// navigation. Verifies reservation bookkeeping stays consistent with the
// repository through add/remove/cancel/checkout/edit-a-returned-sale.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/state/cart_state.dart';
import 'support/proof_photo.dart';

Item _seedGoods(AppRepository repo, BranchId branch, {String description = 'Test ring'}) {
  final purchase = repo.addPurchase(
    description: description,
    weightGrams: 3.0,
    karat: 18,
    type: ItemType.goods,
    capitalAmountCentavos: 500000,
    origin: 'Walk-in',
    branch: branch,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
  );
  repo.releaseCash(purchase.id, proofPhoto: proofPhoto);
  return repo.findItem(purchase.id)!;
}

void main() {
  group('addLine / removeLine', () {
    test('adding reserves the item; removing releases it back to listed', () {
      final repo = AppRepository();
      final cart = CartState(repo);
      final item = _seedGoods(repo, BranchId.kidapawan);

      cart.addLine(item, 900000);
      expect(cart.itemCount, 1);
      expect(cart.totalCentavos, 900000);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.reserved);

      cart.removeLine(item.id);
      expect(cart.isEmpty, isTrue);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.listed);
    });
  });

  group('branch consistency', () {
    test('rejects adding an item from a different branch than what is already in the cart', () {
      final repo = AppRepository();
      final cart = CartState(repo);
      final kidapawanItem = _seedGoods(repo, BranchId.kidapawan, description: 'Kidapawan ring');
      final davaoItem = _seedGoods(repo, BranchId.davao, description: 'Davao ring');

      cart.addLine(kidapawanItem, 900000);
      expect(cart.canAdd(davaoItem), isFalse);
      expect(() => cart.addLine(davaoItem, 500000), throwsStateError);
      // The rejected item must not have been reserved.
      expect(repo.findItem(davaoItem.id)!.itemStatus, ItemStatus.listed);
    });
  });

  group('updatePrice', () {
    test('changes the line price and the running total', () {
      final repo = AppRepository();
      final cart = CartState(repo);
      final item = _seedGoods(repo, BranchId.kidapawan);

      cart.addLine(item, 900000);
      cart.updatePrice(item.id, 950000);
      expect(cart.lines.single.priceCentavos, 950000);
      expect(cart.totalCentavos, 950000);
    });
  });

  group('cancelCart', () {
    test('releases every held item and clears the cart', () {
      final repo = AppRepository();
      final cart = CartState(repo);
      final a = _seedGoods(repo, BranchId.kidapawan, description: 'A');
      final b = _seedGoods(repo, BranchId.kidapawan, description: 'B');

      cart.addLine(a, 100000);
      cart.addLine(b, 200000);
      cart.cancelCart();

      expect(cart.isEmpty, isTrue);
      expect(repo.findItem(a.id)!.itemStatus, ItemStatus.listed);
      expect(repo.findItem(b.id)!.itemStatus, ItemStatus.listed);
    });
  });

  group('clearAfterCheckout', () {
    test('empties the working cart without releasing item reservations', () {
      final repo = AppRepository();
      final cart = CartState(repo);
      final item = _seedGoods(repo, BranchId.kidapawan);

      cart.addLine(item, 900000);
      cart.clearAfterCheckout();

      expect(cart.isEmpty, isTrue);
      // Still reserved — now legitimately tied to the sale that was created.
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.reserved);
    });
  });

  group('startEditingSale', () {
    test('loads a returned sale into the cart without re-reserving its items', () {
      final repo = AppRepository();
      final cart = CartState(repo);
      final item = _seedGoods(repo, BranchId.kidapawan);

      cart.addLine(item, 900000);
      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 900000)],
        customer: const CustomerDetails(name: 'Returning Customer'),
        payment: const SalePayment(cashCentavos: 900000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );
      cart.clearAfterCheckout();
      repo.returnSaleForCorrection(sale.id, 'Please recheck the price');

      final returnedSale = repo.findSale(sale.id)!;
      cart.startEditingSale(returnedSale);

      expect(cart.editingSaleId, sale.id);
      expect(cart.editingSaleNote, 'Please recheck the price');
      expect(cart.customerName, 'Returning Customer');
      expect(cart.itemCount, 1);
      expect(cart.lines.single.item.id, item.id);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.reserved); // unchanged, not double-reserved
    });
  });
}
