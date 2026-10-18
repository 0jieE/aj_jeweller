// Unit tests for the Sell-tab repository logic: sellable inventory
// filtering, reservation, checkout, cashier completion (cash vs. bank
// balance), and the return/resubmit cycle.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

Item _seedGoods(AppRepository repo, {String description = 'Test ring'}) {
  final purchase = repo.addPurchase(
    description: description,
    weightGrams: 3.0,
    karat: 18,
    type: ItemType.goods,
    capitalAmountCentavos: 500000,
    origin: 'Walk-in',
    branch: BranchId.kidapawan,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
  );
  repo.releaseCash(purchase.id, proofPhoto: proofPhoto); // -> verified, listed
  return repo.findItem(purchase.id)!;
}

void main() {
  group('sellableGoods', () {
    test('excludes scrap and only includes verified listed goods', () {
      final repo = AppRepository();
      final goods = _seedGoods(repo, description: 'Sellable ring');

      final scrapPurchase = repo.addPurchase(
        description: 'Scrap lot',
        weightGrams: 20.0,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 800000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseCash(scrapPurchase.id, proofPhoto: proofPhoto); // -> forDisposal, never sellable

      final unverified = repo.addPurchase(
        description: 'Not yet verified',
        weightGrams: 2.0,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 200000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );

      final sellable = repo.sellableGoods(branchId: BranchId.kidapawan);
      expect(sellable.map((i) => i.id), contains(goods.id));
      expect(sellable.map((i) => i.id), isNot(contains(scrapPurchase.id)));
      expect(sellable.map((i) => i.id), isNot(contains(unverified.id)));
    });
  });

  group('reserveItem / releaseReservation', () {
    test('reserving removes an item from sellable goods; releasing restores it', () {
      final repo = AppRepository();
      final item = _seedGoods(repo);
      expect(repo.sellableGoods(branchId: BranchId.kidapawan).map((i) => i.id), contains(item.id));

      repo.reserveItem(item.id);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.reserved);
      expect(repo.sellableGoods(branchId: BranchId.kidapawan).map((i) => i.id), isNot(contains(item.id)));

      repo.releaseReservation(item.id);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.listed);
      expect(repo.sellableGoods(branchId: BranchId.kidapawan).map((i) => i.id), contains(item.id));
    });
  });

  group('checkoutSale / completeSale', () {
    test('checkout creates an awaitingVerification sale; completing marks items sold and credits cash', () {
      final repo = AppRepository();
      final item = _seedGoods(repo);
      repo.reserveItem(item.id);

      final balanceBefore = repo.salesCashBalance(BranchId.kidapawan);
      final floatBefore = repo.cashBalance(BranchId.kidapawan);
      final bankBefore = repo.bankBalance(BranchId.kidapawan);

      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 900000)],
        customer: const CustomerDetails(name: 'Test Customer'),
        payment: const SalePayment(cashCentavos: 900000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );

      expect(sale.verificationStatus, VerificationStatus.awaitingVerification);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.reserved); // untouched by checkout itself
      expect(repo.salesCashBalance(BranchId.kidapawan), balanceBefore); // not yet paid

      repo.completeSale(sale.id, payment: const SalePayment(cashCentavos: 900000));
      final completed = repo.findSale(sale.id)!;
      expect(completed.verificationStatus, VerificationStatus.verified);
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.sold);
      expect(repo.salesCashBalance(BranchId.kidapawan), balanceBefore + 900000);
      expect(repo.cashBalance(BranchId.kidapawan), floatBefore, reason: 'sale takings never top up the purchase float');
      expect(repo.bankBalance(BranchId.kidapawan), bankBefore); // untouched
    });

    test('completing with a non-cash method credits the bank balance instead', () {
      final repo = AppRepository();
      final item = _seedGoods(repo);
      repo.reserveItem(item.id);

      final cashBefore = repo.salesCashBalance(BranchId.kidapawan);
      final bankBefore = repo.bankBalance(BranchId.kidapawan);

      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 900000)],
        customer: const CustomerDetails(name: 'GCash Customer'),
        payment: const SalePayment(bankCentavos: 900000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );
      repo.completeSale(sale.id, payment: const SalePayment(bankCentavos: 900000));

      expect(repo.salesCashBalance(BranchId.kidapawan), cashBefore);
      expect(repo.bankBalance(BranchId.kidapawan), bankBefore + 900000);
    });
  });

  group('returnSaleForCorrection / resubmitSale', () {
    test('returned sale carries a note and items stay reserved; resubmit clears it', () {
      final repo = AppRepository();
      final item = _seedGoods(repo);
      repo.reserveItem(item.id);

      final sale = repo.checkoutSale(
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 900000)],
        customer: const CustomerDetails(name: 'Wrong Price Customer'),
        payment: const SalePayment(cashCentavos: 900000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );

      repo.returnSaleForCorrection(sale.id, 'Price looks wrong, please recheck');
      final returned = repo.findSale(sale.id)!;
      expect(returned.verificationStatus, VerificationStatus.returnedForCorrection);
      expect(returned.verificationNote, 'Price looks wrong, please recheck');
      expect(repo.findItem(item.id)!.itemStatus, ItemStatus.reserved); // still held
      expect(
        repo.salesReturnedForCorrectionFor(AppUserRole.salesRep, branchId: BranchId.kidapawan),
        contains(returned),
      );

      repo.resubmitSale(
        sale.id,
        lineItems: [SaleLineItem(item: item, negotiatedPriceCentavos: 950000)],
        customer: const CustomerDetails(name: 'Wrong Price Customer'),
        payment: const SalePayment(cashCentavos: 900000),
      );
      final resubmitted = repo.findSale(sale.id)!;
      expect(resubmitted.verificationStatus, VerificationStatus.awaitingVerification);
      expect(resubmitted.verificationNote, isNull);
      expect(resubmitted.totalAmountCentavos, 950000);
    });
  });
}
