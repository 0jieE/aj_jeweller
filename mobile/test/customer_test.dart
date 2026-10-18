// Unit tests for the customer book and for split settlement — the two places
// where a transaction stops being self-contained and has to agree with
// something outside itself.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/purchase_batch.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/transaction_log.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'support/proof_photo.dart';

PurchaseBatch _purchaseFrom(AppRepository repo, CustomerDetails customer, {int amount = 500000}) {
  return repo.recordPurchaseBatch(
    customer: customer,
    lines: [
      PurchaseDraftLine(
        description: 'Test piece',
        grossWeightGrams: 5,
        weightGrams: 5,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: amount,
      ),
    ],
    branch: BranchId.kidapawan,
    purchaseDate: DateTime.now(),
    submittedByRole: AppUserRole.assistantAppraiser,
  );
}

void main() {
  group('the customer book', () {
    test('a purchase files its customer and links back to the record', () {
      final repo = AppRepository();
      final before = repo.customers.length;

      final batch = _purchaseFrom(
        repo,
        const CustomerDetails(
          name: 'Nora Salcedo',
          contactNumber: '0917 000 1111',
          address: 'Amas, Kidapawan City',
        ),
      );

      expect(repo.customers, hasLength(before + 1));
      final customer = repo.customerByName('Nora Salcedo')!;
      expect(customer.contactNumber, '0917 000 1111');
      expect(repo.findBatch(batch.id)!.customer.customerId, customer.id);
      expect(repo.purchasesByCustomer(customer.id).map((b) => b.id), contains(batch.id));
    });

    test('the same person across visits is one record, however it was typed', () {
      final repo = AppRepository();
      _purchaseFrom(repo, const CustomerDetails(name: 'Nora Salcedo'));
      final before = repo.customers.length;

      _purchaseFrom(repo, const CustomerDetails(name: '  nora   SALCEDO '));

      expect(repo.customers, hasLength(before), reason: 'casing and spacing are not new people');
      expect(repo.purchasesByCustomer(repo.customerByName('Nora Salcedo')!.id), hasLength(2));
    });

    test('a later visit fills gaps but never blanks what is already on file', () {
      final repo = AppRepository();
      _purchaseFrom(
        repo,
        const CustomerDetails(name: 'Nora Salcedo', contactNumber: '0917 000 1111'),
      );

      // A rushed entry with no contact must not erase the number.
      _purchaseFrom(repo, const CustomerDetails(name: 'Nora Salcedo', address: 'Lanao'));

      final customer = repo.customerByName('Nora Salcedo')!;
      expect(customer.contactNumber, '0917 000 1111');
      expect(customer.address, 'Lanao');
    });

    test('search ranks names that start with the query above ones that contain it', () {
      final repo = AppRepository();
      _purchaseFrom(repo, const CustomerDetails(name: 'Norma Reyes'));
      _purchaseFrom(repo, const CustomerDetails(name: 'Nora Salcedo'));
      _purchaseFrom(repo, const CustomerDetails(name: 'Elenora Cruz'));

      final names = repo.searchCustomers('nor').map((c) => c.name).toList();
      expect(names.take(2), containsAll(['Nora Salcedo', 'Norma Reyes']));
      expect(names.last, 'Elenora Cruz', reason: 'a mid-name match ranks last');
    });

    test('a customer history spans both directions of trade', () {
      final repo = AppRepository();
      const details = CustomerDetails(name: 'Two-way Tina');
      final batch = _purchaseFrom(repo, details);
      repo.releaseBatchCash(batch.id, proofPhoto: proofPhoto);

      final item = repo.itemsInBatch(batch.id).first;
      repo.reserveItem(item.id);
      final sale = repo.checkoutSale(
        lineItems: [
          SaleLineItem(item: repo.findItem(item.id)!, negotiatedPriceCentavos: 800000),
        ],
        customer: details,
        payment: const SalePayment.cash(800000),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );

      final customer = repo.customerByName('Two-way Tina')!;
      expect(repo.purchasesByCustomer(customer.id).map((b) => b.id), contains(batch.id));
      expect(repo.salesByCustomer(customer.id).map((s) => s.id), contains(sale.id));
    });
  });

  group('customer photos', () {
    final photoA = Uint8List.fromList([1, 2, 3]);
    final photoB = Uint8List.fromList([4, 5, 6]);

    test('a photo taken at the counter is filed on the customer record', () {
      final repo = AppRepository();
      final batch = _purchaseFrom(repo, CustomerDetails(name: 'Photo Person', photo: photoA));

      final customer = repo.findCustomer(batch.customer.customerId!)!;
      expect(customer.photo, photoA);
      expect(repo.customerFor(batch.customer)!.photo, photoA);
    });

    test('a visit without a photo keeps the one on file; a new photo replaces it', () {
      final repo = AppRepository();
      final first = _purchaseFrom(repo, CustomerDetails(name: 'Regular', photo: photoA));
      final id = first.customer.customerId!;

      _purchaseFrom(repo, CustomerDetails(name: 'Regular', customerId: id));
      expect(repo.findCustomer(id)!.photo, photoA);

      _purchaseFrom(repo, CustomerDetails(name: 'Regular', customerId: id, photo: photoB));
      expect(repo.findCustomer(id)!.photo, photoB);
    });

    test('changing a photo from the customer book is logged', () {
      final repo = AppRepository();
      final customer = repo.customers.first;

      repo.setCustomerPhoto(customer.id, photoA);

      expect(repo.findCustomer(customer.id)!.photo, photoA);
      final log = repo.logsForRecord(customer.id).last;
      expect(log.action, LogAction.customerPhotoUpdated);
      expect(log.recordKind, LogRecordKind.customer);
    });
  });

  group('the seeded book', () {
    test('every seeded transaction links to a customer record', () {
      final repo = AppRepository();

      for (final batch in repo.purchaseBatches) {
        expect(batch.customer.customerId, isNotNull,
            reason: '${batch.id} (${batch.customer.name}) must point at a record');
        expect(repo.findCustomer(batch.customer.customerId!), isNotNull);
      }
      for (final sale in repo.sales) {
        expect(sale.customer.customerId, isNotNull,
            reason: '${sale.id} (${sale.customerName}) must point at a record');
      }
    });

    test('a seeded customer can answer what was done with them', () {
      final repo = AppRepository();
      final maria = repo.customerByName('Maria Santos');

      expect(maria, isNotNull);
      expect(repo.purchasesByCustomer(maria!.id), isNotEmpty,
          reason: 'her purchases must be reachable from her record');
      expect(maria.contactNumber, isNotNull);
    });

    test('nobody in the book is stranded without a transaction', () {
      final repo = AppRepository();

      for (final customer in repo.customers) {
        final total = repo.purchasesByCustomer(customer.id).length +
            repo.salesByCustomer(customer.id).length;
        expect(total, greaterThan(0), reason: '${customer.name} has no history');
      }
    });
  });

  group('split settlement', () {
    Sale soldFor(AppRepository repo, int price) {
      final batch = _purchaseFrom(repo, const CustomerDetails(name: 'Buyer'), amount: 400000);
      repo.releaseBatchCash(batch.id, proofPhoto: proofPhoto);
      final item = repo.itemsInBatch(batch.id).first;
      repo.reserveItem(item.id);
      return repo.checkoutSale(
        lineItems: [
          SaleLineItem(item: repo.findItem(item.id)!, negotiatedPriceCentavos: price),
        ],
        customer: const CustomerDetails(name: 'Buyer'),
        payment: SalePayment.cash(price),
        branch: BranchId.kidapawan,
        submittedByRole: AppUserRole.salesRep,
      );
    }

    test('each half lands where the money physically went', () {
      final repo = AppRepository();
      final sale = soldFor(repo, 1000000);
      final cashBefore = repo.salesCashBalance(BranchId.kidapawan);
      final bankBefore = repo.bankBalance(BranchId.kidapawan);

      repo.completeSale(
        sale.id,
        payment: const SalePayment(cashCentavos: 400000, bankCentavos: 600000),
      );

      expect(repo.salesCashBalance(BranchId.kidapawan), cashBefore + 400000);
      expect(repo.bankBalance(BranchId.kidapawan), bankBefore + 600000);
    });

    test('a split writes one entry to sales cash and one to the bank', () {
      final repo = AppRepository();
      final sale = soldFor(repo, 1000000);

      repo.completeSale(
        sale.id,
        payment: const SalePayment(cashCentavos: 400000, bankCentavos: 600000),
      );

      final entries = repo.cashEntries.where((e) => e.linkedRecordId == sale.id).toList();
      expect(entries, hasLength(2));
      expect(entries.firstWhere((e) => e.account == CashAccount.sales).amountCentavos, 400000);
      expect(entries.firstWhere((e) => e.account == CashAccount.bank).amountCentavos, 600000);
    });

    test('a fully transferred sale touches only the bank', () {
      final repo = AppRepository();
      final sale = soldFor(repo, 1000000);
      final floatBefore = repo.cashBalance(BranchId.kidapawan);
      final salesBefore = repo.salesCashBalance(BranchId.kidapawan);

      repo.completeSale(sale.id, payment: const SalePayment.bank(1000000));

      expect(repo.cashBalance(BranchId.kidapawan), floatBefore);
      expect(repo.salesCashBalance(BranchId.kidapawan), salesBefore);
      final entries = repo.cashEntries.where((e) => e.linkedRecordId == sale.id).toList();
      expect(entries.map((e) => e.account), [CashAccount.bank]);
    });

    test('a payment knows whether it covers the order', () {
      const exact = SalePayment(cashCentavos: 400000, bankCentavos: 600000);
      expect(exact.covers(1000000), isTrue);
      expect(exact.totalCentavos, 1000000);
      expect(exact.isSplit, isTrue);
      expect(exact.label, 'Cash + Bank');

      const short = SalePayment(cashCentavos: 400000);
      expect(short.covers(1000000), isFalse);
      expect(short.label, 'Cash');
      expect(const SalePayment.bank(500).label, 'Bank Transfer');
    });
  });
}
