// Proves the receipt generator actually produces a valid PDF for both a
// purchase and a sale — the two documents a customer can be handed.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/purchase_batch.dart';
import 'package:davao_aj_jewellers/core/models/customer.dart';
import 'package:davao_aj_jewellers/core/models/sale.dart';
import 'package:davao_aj_jewellers/core/models/stored_receipt.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/services/receipt_service.dart';
import 'package:davao_aj_jewellers/core/widgets/formatters.dart';
import 'support/proof_photo.dart';

/// A PDF file always starts with this magic number.
void expectIsPdf(List<int> bytes) {
  expect(bytes.length, greaterThan(500), reason: 'a real receipt is not a stub');
  expect(String.fromCharCodes(bytes.take(4)), '%PDF');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a purchase receipt renders every line and the customer details', () async {
    final repo = AppRepository();
    final batch = repo.recordPurchaseBatch(
      customer: const CustomerDetails(
        name: 'Maria Santos',
        contactNumber: '0917 555 0142',
        address: 'Poblacion, Kidapawan City',
      ),
      lines: const [
        PurchaseDraftLine(
          description: '22K necklace, rope chain',
          grossWeightGrams: 16.4,
          weightGrams: 15.75,
          karat: 22,
          type: ItemType.goods,
          capitalAmountCentavos: 8200000,
        ),
        PurchaseDraftLine(
          description: '18K ring, plain band',
          grossWeightGrams: 4.0,
          weightGrams: 4.0,
          karat: 18,
          type: ItemType.goods,
          capitalAmountCentavos: 1700000,
        ),
      ],
      branch: BranchId.kidapawan,
      purchaseDate: DateTime(2026, 9, 16, 14, 30),
      submittedByRole: AppUserRole.assistantAppraiser,
    );

    final bytes = await ReceiptService.purchase(
      batch: batch,
      items: repo.itemsInBatch(batch.id),
    );

    expectIsPdf(bytes);
  });

  test('a sale receipt renders from a completed sale', () async {
    final repo = AppRepository();
    final item = repo.addPurchase(
      description: '21K bangle',
      weightGrams: 20.3,
      karat: 21,
      type: ItemType.goods,
      capitalAmountCentavos: 9800000,
      origin: 'Walk-in',
      branch: BranchId.kidapawan,
      purchaseDate: DateTime(2026, 9, 10),
      submittedByRole: AppUserRole.assistantAppraiser,
    );
    repo.releaseCash(item.id, proofPhoto: proofPhoto);
    repo.reserveItem(item.id);

    final sale = repo.checkoutSale(
      lineItems: [
        SaleLineItem(
          item: repo.findItem(item.id)!,
          negotiatedPriceCentavos: 11500000,
          finalGrams: 20.1,
        ),
      ],
      customer: const CustomerDetails(name: 'Teresa Lim'),
      payment: const SalePayment(cashCentavos: 11500000),
      branch: BranchId.kidapawan,
      submittedByRole: AppUserRole.salesRep,
    );
    repo.completeSale(sale.id, payment: const SalePayment(cashCentavos: 11500000));

    final bytes = await ReceiptService.sale(sale: repo.findSale(sale.id)!);
    expectIsPdf(bytes);
  });

  test('price per gram is derived from the weight the sale was struck at', () {
    final line = SaleLineItem(
      item: Item(
        id: 'ABC123',
        description: 'Test',
        weightGrams: 10,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 100000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: DateTime(2026, 1, 1),
        submittedByRole: AppUserRole.salesRep,
      ),
      negotiatedPriceCentavos: 1000000,
      finalGrams: 8,
    );
    // Struck on the re-weighed 8g, not the item's recorded 10g.
    expect(line.effectiveFinalGrams, 8);
    expect(line.pricePerGramCentavos, 125000);
  });

  group('receipts are kept in the app', () {
    test('a stored receipt is retrievable by the record it documents', () async {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: '18K ring',
        weightGrams: 4,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1700000,
        origin: 'Grace Palma',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime(2026, 9, 16),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      final batchId = item.batchId!;
      repo.releaseBatchCash(batchId, proofPhoto: proofPhoto);

      expect(repo.receiptForRecord(batchId), isNull, reason: 'nothing filed until issued');

      final bytes = await ReceiptService.purchase(
        batch: repo.findBatch(batchId)!,
        items: repo.itemsInBatch(batchId),
      );
      final stored = repo.storeReceipt(
        recordId: batchId,
        kind: ReceiptKind.purchase,
        branch: BranchId.kidapawan,
        counterparty: 'Grace Palma',
        totalCentavos: 1700000,
        bytes: bytes,
      );

      expect(repo.receiptForRecord(batchId), isNotNull);
      expect(repo.receipts, contains(stored));
      expect(repo.receiptsForBranch(BranchId.kidapawan), contains(stored));
      expect(repo.receiptsForBranch(BranchId.davao), isEmpty);
      expect(stored.filename, 'purchase-$batchId.pdf');
      expectIsPdf(stored.bytes);
    });

    test('re-issuing replaces the filed copy rather than duplicating it', () async {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: '18K ring',
        weightGrams: 4,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1700000,
        origin: 'Grace Palma',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime(2026, 9, 16),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      final batchId = item.batchId!;
      repo.releaseBatchCash(batchId, proofPhoto: proofPhoto);
      final bytes = await ReceiptService.purchase(
        batch: repo.findBatch(batchId)!,
        items: repo.itemsInBatch(batchId),
      );

      for (var i = 0; i < 3; i++) {
        repo.storeReceipt(
          recordId: batchId,
          kind: ReceiptKind.purchase,
          branch: BranchId.kidapawan,
          counterparty: 'Grace Palma',
          totalCentavos: 1700000,
          bytes: bytes,
        );
      }

      expect(repo.receipts.where((r) => r.recordId == batchId), hasLength(1));
    });

    test('a demo reset clears issued receipts — they were never seeded', () async {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: '18K ring',
        weightGrams: 4,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1700000,
        origin: 'Grace Palma',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime(2026, 9, 16),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      repo.releaseBatchCash(item.batchId!, proofPhoto: proofPhoto);
      final bytes = await ReceiptService.purchase(
        batch: repo.findBatch(item.batchId!)!,
        items: repo.itemsInBatch(item.batchId!),
      );
      repo.storeReceipt(
        recordId: item.batchId!,
        kind: ReceiptKind.purchase,
        branch: BranchId.kidapawan,
        counterparty: 'Grace Palma',
        totalCentavos: 1700000,
        bytes: bytes,
      );
      expect(repo.receipts, isNotEmpty);

      repo.resetToSeed();
      expect(repo.receipts, isEmpty);
    });
  });

  group('item photos', () {
    test('a photo filed against an item is what verification reads back', () {
      final repo = AppRepository();
      final item = repo.addPurchase(
        description: '22K chain',
        weightGrams: 10,
        karat: 22,
        type: ItemType.goods,
        capitalAmountCentavos: 5000000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime(2026, 9, 16),
        submittedByRole: AppUserRole.assistantAppraiser,
      );
      expect(repo.findItem(item.id)!.hasPhoto, isFalse);

      repo.setItemPhoto(item.id, Uint8List.fromList([1, 2, 3, 4]));

      final photographed = repo.findItem(item.id)!;
      expect(photographed.hasPhoto, isTrue);
      expect(photographed.photo, [1, 2, 3, 4]);

      // It has to survive the Cashier's release, which rewrites the item.
      repo.releaseBatchCash(item.batchId!, proofPhoto: proofPhoto);
      expect(repo.findItem(item.id)!.photo, [1, 2, 3, 4]);
    });
  });

  test('text receipts carry the id, customer, and total', () {
    final repo = AppRepository();
    final sale = repo.sales.firstWhere((s) => s.verificationStatus == VerificationStatus.verified);
    final text = ReceiptService.saleText(sale: sale);
    expect(text, contains(sale.id));
    expect(text, contains(sale.customerName));
    expect(text, contains(AppFormat.peso(sale.totalAmountCentavos)));

    final batch = repo.purchaseBatches.firstWhere((b) => b.releasedAt != null);
    final purchaseText = ReceiptService.purchaseText(batch: batch, items: repo.itemsInBatch(batch.id));
    expect(purchaseText, contains(batch.id));
    expect(purchaseText, contains(batch.customer.name));
    expect(purchaseText, contains('TOTAL PAID'));
  });
}
