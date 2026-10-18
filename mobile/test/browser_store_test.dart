@TestOn('browser')
library;

// The desktop's copy of the shop lives in the browser's own database, so
// this is the one test that has to run in a real browser:
//
//     flutter test --platform chrome test/browser_store_test.dart
//
// It is excluded from the ordinary suite by @TestOn, so `flutter test` on
// its own stays as fast as it was.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/data/local_store.dart';

void main() {
  late LocalStore store;

  setUp(() async {
    final opened = await openLocalStore();
    expect(opened, isNotNull, reason: 'the browser should have a database');
    store = opened!;
    // Each test starts from a known state rather than the last one's.
    await store.writeData('');
    await store.writeOutbox('');
  });

  test('nothing is saved until something is written', () async {
    await store.writeData('');
    expect(await store.readData(), '');
  });

  test('the shop goes in and comes back out whole', () async {
    final source = AppRepository();
    final json = jsonEncode(source.toSnapshot());

    await store.writeData(json);
    final read = await store.readData();

    expect(read, json);
    // And it is still a shop after the round trip, not just a matching string.
    final restored = AppRepository()..restoreSnapshot(jsonDecode(read!) as Map<String, dynamic>);
    expect(restored.users.length, source.users.length);
    expect(restored.items.length, source.items.length);
    expect(restored.cashBalance(restored.branches.first.id),
        source.cashBalance(source.branches.first.id));
  });

  test('the queue is kept apart from the records', () async {
    await store.writeData('{"version":1}');
    await store.writeOutbox('{"pending":[{"key":"abc"}]}');

    expect(await store.readData(), '{"version":1}');
    expect(await store.readOutbox(), contains('abc'));
  });

  test('a later save replaces the earlier one', () async {
    await store.writeData('first');
    await store.writeData('second');
    expect(await store.readData(), 'second');
  });

  test('a save too large for local storage is kept anyway', () async {
    // Photographs are what make a snapshot big; local storage would have
    // refused somewhere around five megabytes.
    final big = jsonEncode({'photo': 'x' * (8 * 1024 * 1024)});
    await store.writeData(big);
    expect((await store.readData())!.length, big.length);
  });

  test('what was unreadable is kept, not thrown away', () async {
    await store.writeData('not json at all');
    await store.setAsideUnreadable();
    // The copy aside is not the live one; the live one is still there to be
    // overwritten by the next good save.
    expect(await store.readData(), 'not json at all');
  });
}
