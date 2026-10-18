// Unit tests for the two drawer reset actions: restoring seed data and
// clearing to a genuinely empty state.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';

void main() {
  group('resetToEmpty', () {
    test('clears every transactional record and zeroes branch balances', () {
      final repo = AppRepository();

      // Sanity check: seed data actually has records to clear.
      expect(repo.items, isNotEmpty);
      expect(repo.sales, isNotEmpty);
      expect(repo.commitments, isNotEmpty);
      expect(repo.disposalBatches, isNotEmpty);
      expect(repo.cashBalance(BranchId.kidapawan), greaterThan(0));

      repo.resetToEmpty();

      expect(repo.items, isEmpty);
      expect(repo.sales, isEmpty);
      expect(repo.commitments, isEmpty);
      expect(repo.disposalBatches, isEmpty);
      expect(repo.cashBalance(BranchId.kidapawan), 0);
      expect(repo.branch(BranchId.kidapawan).startingCashBalanceCentavos, 0);
      expect(repo.cashBalance(BranchId.davao), 0);

      // Branches and gold rates survive — there's nowhere to record a new
      // purchase or loan without them.
      expect(repo.branches, hasLength(2));
      expect(repo.goldRates, isNotEmpty);
    });

    test('the app still works after clearing — a fresh purchase can be recorded', () {
      final repo = AppRepository();
      repo.resetToEmpty();

      final item = repo.addPurchase(
        description: 'First purchase after clearing',
        weightGrams: 5.0,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 200000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );

      expect(repo.items, hasLength(1));
      expect(repo.findItem(item.id), isNotNull);
    });

    test('resetToSeed after resetToEmpty brings the sample data back', () {
      final repo = AppRepository();
      repo.resetToEmpty();
      expect(repo.items, isEmpty);

      repo.resetToSeed();

      expect(repo.items, isNotEmpty);
      expect(repo.cashBalance(BranchId.kidapawan), greaterThan(0));
    });
  });

  group('updateGoldRate', () {
    test('updates the price for the matching karat only', () {
      final repo = AppRepository();
      final before18k = repo.rateForKarat(18)!;
      final before24k = repo.rateForKarat(24)!;

      repo.updateGoldRate(18, 700000);

      expect(repo.rateForKarat(18)!.pricePerGramCentavos, 700000);
      expect(repo.rateForKarat(24)!.pricePerGramCentavos, before24k.pricePerGramCentavos);
      expect(repo.rateForKarat(18)!.updatedAt.isAfter(before18k.updatedAt) ||
          repo.rateForKarat(18)!.updatedAt.isAtSameMomentAs(before18k.updatedAt),
          isTrue);
    });

    test('is a no-op for a karat that has no rate', () {
      final repo = AppRepository();
      final ratesBefore = repo.goldRates.length;

      repo.updateGoldRate(23, 123456);

      expect(repo.goldRates.length, ratesBefore);
    });

    test('a custom rate survives resetToEmpty as the seeded value, not the edit', () {
      final repo = AppRepository();
      repo.updateGoldRate(18, 700000);
      repo.resetToEmpty();

      expect(repo.rateForKarat(18)!.pricePerGramCentavos, isNot(700000));
    });
  });
}
