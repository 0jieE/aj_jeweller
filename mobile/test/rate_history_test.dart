// Unit tests for adding gold/silver rates (one per purity, never a
// duplicate) and for the price history each rate keeps.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/transaction_log.dart';

void main() {
  group('addRate', () {
    test('adds a new gold karat and a new silver fineness', () {
      final repo = AppRepository();

      repo.addRate(16, 400000, silver: false);
      repo.addRate(950, 7000, silver: true);

      expect(repo.goldRates.map((r) => r.karat), contains(16));
      expect(repo.silverRates.map((r) => r.karat), contains(950));
      expect(repo.logs.first.action, LogAction.goldRateAdded);
    });

    test('refuses a karat or fineness that already has a rate', () {
      final repo = AppRepository();
      final goldBefore = repo.goldRates.length;
      final silverBefore = repo.silverRates.length;

      expect(repo.rateAddProblem(18, silver: false), contains('already has a rate'));
      expect(() => repo.addRate(18, 500000, silver: false), throwsArgumentError);
      expect(() => repo.addRate(925, 7000, silver: true), throwsArgumentError);

      expect(repo.goldRates.length, goldBefore);
      expect(repo.silverRates.length, silverBefore);
      expect(repo.rateForKarat(18)!.pricePerGramCentavos, isNot(500000));
    });

    test('refuses a purity outside its metal\'s range', () {
      final repo = AppRepository();
      expect(() => repo.addRate(25, 500000, silver: false), throwsArgumentError);
      expect(() => repo.addRate(0, 500000, silver: false), throwsArgumentError);
      expect(() => repo.addRate(50, 7000, silver: true), throwsArgumentError);
      expect(() => repo.addRate(16, 0, silver: false), throwsArgumentError);
    });
  });

  group('rate history', () {
    test('seeded rates open on a history that ends at the current price', () {
      final repo = AppRepository();
      for (final rate in [...repo.goldRates, ...repo.silverRates]) {
        final history = repo.rateHistory(rate.karat);
        expect(history, isNotEmpty, reason: '${rate.karat}');
        expect(history.first.afterCentavos, rate.pricePerGramCentavos, reason: '${rate.karat}');
        expect(history.last.isInitial, isTrue);
      }
    });

    test('an edit is recorded with the before, after, and who', () {
      final repo = AppRepository();
      final before = repo.rateForKarat(18)!.pricePerGramCentavos;
      final count = repo.rateHistory(18).length;

      repo.updateGoldRate(18, before + 5000, actor: repo.users.first);

      final history = repo.rateHistory(18);
      expect(history, hasLength(count + 1));
      expect(history.first.beforeCentavos, before);
      expect(history.first.afterCentavos, before + 5000);
      expect(history.first.deltaCentavos, 5000);
      expect(history.first.userId, repo.users.first.id);
    });

    test('saving the same price adds nothing to the history', () {
      final repo = AppRepository();
      final rate = repo.rateForKarat(24)!;
      final count = repo.rateHistory(24).length;

      repo.updateGoldRate(24, rate.pricePerGramCentavos);

      expect(repo.rateHistory(24), hasLength(count));
    });

    test('a newly added rate starts its history with the first price', () {
      final repo = AppRepository();
      repo.addRate(16, 400000, silver: false);

      final history = repo.rateHistory(16);
      expect(history, hasLength(1));
      expect(history.single.isInitial, isTrue);
      expect(history.single.afterCentavos, 400000);
    });
  });

  group('rates by date', () {
    test('rateOn reads the price in force at the close of a day', () {
      final repo = AppRepository();
      final history = repo.rateHistory(18); // newest first: today, 14d, 30d
      final twoWeeksAgo = history[1];
      final monthAgo = history[2];

      expect(repo.rateOn(18, DateTime.now()), repo.rateForKarat(18)!.pricePerGramCentavos);
      expect(repo.rateOn(18, twoWeeksAgo.at), twoWeeksAgo.afterCentavos);
      expect(repo.rateOn(18, twoWeeksAgo.at.subtract(const Duration(days: 1))), monthAgo.afterCentavos);
      expect(repo.rateOn(18, monthAgo.at.subtract(const Duration(days: 1))), isNull);
    });

    test('applyRatesFrom sets every gold rate to that day, leaving silver alone', () {
      final repo = AppRepository();
      final day = repo.rateHistory(18)[1].at;
      final silverBefore = {for (final r in repo.silverRates) r.karat: r.pricePerGramCentavos};

      final changed = repo.applyRatesFrom(day, silver: false, actor: repo.users.first);

      expect(changed, repo.goldRates.length);
      for (final r in repo.goldRates) {
        expect(r.pricePerGramCentavos, repo.rateOn(r.karat, day), reason: '${r.karat}K');
        expect(repo.rateHistory(r.karat).first.restoredFrom, DateTime(day.year, day.month, day.day));
      }
      for (final r in repo.silverRates) {
        expect(r.pricePerGramCentavos, silverBefore[r.karat]);
      }
    });

    test('applyRatesFrom for silver only touches silver', () {
      final repo = AppRepository();
      final day = repo.rateHistory(925)[1].at;
      final goldBefore = {for (final r in repo.goldRates) r.karat: r.pricePerGramCentavos};

      repo.applyRatesFrom(day, silver: true);

      for (final r in repo.silverRates) {
        expect(r.pricePerGramCentavos, repo.rateOn(r.karat, day));
      }
      for (final r in repo.goldRates) {
        expect(r.pricePerGramCentavos, goldBefore[r.karat]);
      }
    });

    test('applying today\'s rates changes nothing and adds no history', () {
      final repo = AppRepository();
      final count = repo.allRateHistory.length;
      expect(repo.applyRatesFrom(DateTime.now(), silver: false), 0);
      expect(repo.allRateHistory, hasLength(count));
    });

    test('a rate not set yet on the chosen day is left as it is', () {
      final repo = AppRepository();
      repo.addRate(16, 400000, silver: false);
      final day = repo.rateHistory(18)[1].at;

      repo.applyRatesFrom(day, silver: false);

      expect(repo.rateForKarat(16)!.pricePerGramCentavos, 400000);
    });

    test('the combined history covers every rate, newest first', () {
      final repo = AppRepository();
      final all = repo.allRateHistory;
      final perRate = [...repo.goldRates, ...repo.silverRates]
          .fold<int>(0, (sum, r) => sum + repo.rateHistory(r.karat).length);
      expect(all, hasLength(perRate));
      for (var i = 1; i < all.length; i++) {
        expect(all[i - 1].at.isBefore(all[i].at), isFalse);
      }
    });
  });
}
