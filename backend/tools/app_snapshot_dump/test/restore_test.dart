// Loads a snapshot the *server* produced (GET /sync/snapshot) with the app's
// own parser, to prove the phone can read what the server hands it.
//
//   SNAPSHOT_IN=server_snapshot.json flutter test test/restore_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';

void main() {
  test('the app restores the server snapshot', () {
    final path = Platform.environment['SNAPSHOT_IN'];
    if (path == null) {
      markTestSkipped('Set SNAPSHOT_IN to a file from GET /sync/snapshot');
      return;
    }
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final repo = AppRepository()..resetToEmpty();
    repo.restoreSnapshot(json);

    expect(repo.items.length, (json['items'] as List).length);
    expect(repo.sales.length, (json['sales'] as List).length);
    expect(repo.logs.length, (json['logs'] as List).length);
    for (final b in BranchId.values) {
      for (final a in CashAccount.values) {
        // ignore: avoid_print
        print('${b.name} ${a.name}: ${repo.accountBalance(b, a)}');
      }
    }
  });
}
