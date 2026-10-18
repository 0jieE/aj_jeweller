// The offline-first seam: a write made at the counter is applied locally and
// queued, pushed in order under its own idempotency key, refused changes are
// shown rather than silently dropped, and a page of server changes is applied
// on top. All against a fake server — nothing needs to be running.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/api/api_client.dart';
import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/cash_entry.dart';
import 'package:davao_aj_jewellers/core/models/item.dart';
import 'package:davao_aj_jewellers/core/models/transaction_log.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/sync/outbox.dart';
import 'package:davao_aj_jewellers/core/sync/sync_service.dart';

import 'support/fake_server.dart';

({SyncService sync, AppRepository repo, FakeServer server, Outbox outbox}) _wire({
  AppRepository? repository,
}) {
  final server = FakeServer();
  final repo = repository ?? AppRepository();
  final outbox = Outbox();
  final sync = SyncService(
    api: ApiClient(httpClient: server, baseUrl: FakeServer.base, accessToken: () => 'token'),
    repository: repo,
    outbox: outbox,
  );
  return (sync: sync, repo: repo, server: server, outbox: outbox);
}

SyncOperation _op(String key, {String summary = 'Release cash · A1B2C3'}) => SyncOperation(
      key: key,
      method: 'POST',
      path: 'purchases/A1B2C3/release',
      body: {'cash_entry_id': 'CSH001'},
      recordedAt: DateTime(2026, 10, 18, 9, 30),
      summary: summary,
    );

/// A page of changes that says it is the last one.
Map<String, dynamic> _page({
  Map<String, dynamic> changes = const {},
  Map<String, dynamic> deleted = const {},
  int cursor = 12,
  bool hasMore = false,
}) =>
    {'changes': changes, 'deleted': deleted, 'cursor': cursor, 'has_more': hasMore};

Map<String, dynamic> _cashEntryJson(String id, {int amount = 500000, String note = 'From the server'}) => {
      'id': id,
      'branch': 'kidapawan',
      'type': 'cashIn',
      'account': 'sales',
      'amount': amount,
      'note': note,
      'category': null,
      'date': '2026-10-18T09:30:00+08:00',
      'recordedByRole': 'cashier',
      'recordedBy': null,
      'source': 'manual',
      'linkedRecordId': null,
      'transferPairId': null,
    };

void main() {
  group('the outbox', () {
    test('a write made at the counter is queued with its own key', () async {
      final w = _wire();
      // Nothing is routed, so the push fails and the work stays queued.
      w.repo.addPurchase(
        description: '18K ring',
        weightGrams: 4,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1700000,
        origin: 'Walk-in',
        branch: BranchId.kidapawan,
        purchaseDate: DateTime.now(),
        submittedByRole: AppUserRole.assistantAppraiser,
      );

      expect(w.sync.pendingCount, greaterThan(0));
      final queued = w.outbox.pending.first;
      expect(queued.method, 'POST');
      expect(queued.key, isNotEmpty);
      expect(queued.body['id'], isNotEmpty, reason: 'the phone names the record');
      // The write kicked off a push of its own; nothing is routed, so it
      // comes back offline and the work is still here afterwards.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(w.sync.phase, anyOf(SyncPhase.offline, SyncPhase.failed));
      expect(w.sync.pendingCount, greaterThan(0), reason: 'kept for the next try');
    });

    test('nothing the server sends back is queued again', () async {
      final w = _wire();
      w.server.on('GET', 'sync/changes', body: _page(changes: {'cashEntries': [_cashEntryJson('SRV001')]}));

      await w.sync.syncNow();

      expect(w.repo.cashEntries.any((e) => e.id == 'SRV001'), isTrue);
      expect(w.sync.pendingCount, 0, reason: 'the server already knows');
    });

    test('the queue survives being written out and read back', () {
      final w = _wire();
      w.outbox.add(_op('key-1'));
      w.outbox.add(_op('key-2', summary: 'Receive payment · S1'));
      w.outbox.cursor = 42;

      final restored = Outbox()..restoreFrom(SyncService.decode(w.outbox.encode()));

      expect(restored.pending.map((o) => o.key), ['key-1', 'key-2']);
      expect(restored.pending.first.body['cash_entry_id'], 'CSH001');
      expect(restored.pending.last.summary, 'Receive payment · S1');
      expect(restored.cursor, 42);
    });
  });

  group('pushing', () {
    test('queued writes go up in order and leave the queue once taken', () async {
      final w = _wire();
      w.outbox.add(_op('key-1'));
      w.outbox.add(_op('key-2'));
      w.server.on('POST', 'sync/push', handler: (request) {
        final ops = (request['operations'] as List).cast<Map<String, dynamic>>();
        return {
          'results': [
            for (final op in ops) {'key': op['key'], 'status': 200, 'body': {}},
          ]
        };
      });
      w.server.on('GET', 'sync/changes', body: _page());

      await w.sync.syncNow();

      final sent = w.server.callsTo('POST', 'sync/push').single;
      expect(sent.body.indexOf('key-1') < sent.body.indexOf('key-2'), isTrue, reason: 'in order');
      expect(sent.body, contains('"recorded_at":"2026-10-18T09:30:00.000"'));
      expect(w.sync.pendingCount, 0);
      expect(w.sync.phase, SyncPhase.idle);
      expect(w.sync.lastSyncedAt, isNotNull);
    });

    test('a server failure keeps the write, and the replay carries the same key', () async {
      final w = _wire();
      w.outbox.add(_op('key-1'));
      var attempt = 0;
      w.server.on('POST', 'sync/push', handler: (request) {
        attempt++;
        final key = ((request['operations'] as List).first as Map)['key'];
        return attempt == 1
            ? {'results': [{'key': key, 'status': 503, 'body': {'error': {'code': 'unavailable', 'message': 'try later'}}}]}
            : {'results': [{'key': key, 'status': 200, 'body': {}}]};
      });
      w.server.on('GET', 'sync/changes', body: _page());

      await w.sync.syncNow();
      expect(w.sync.pendingCount, 1, reason: 'a 5xx is not the shop being wrong');
      expect(w.outbox.pending.single.key, 'key-1');
      expect(w.sync.refusals, isEmpty);

      await w.sync.syncNow();

      expect(w.sync.pendingCount, 0);
      final pushes = w.server.callsTo('POST', 'sync/push');
      expect(pushes, hasLength(2));
      expect(pushes.last.body, contains('"key":"key-1"'),
          reason: 'the same key, so the server can tell a replay from a second release');
    });

    test('an unreachable server leaves the queue exactly as it was', () async {
      final w = _wire();
      w.outbox.add(_op('key-1'));
      w.server.on('POST', 'sync/push', status: 500, body: {'detail': 'boom'});

      await w.sync.syncNow();

      expect(w.sync.phase, SyncPhase.offline);
      expect(w.sync.error, isNotNull);
      expect(w.outbox.pending.single.key, 'key-1');
    });
  });

  group('a refused change', () {
    test('a 422 is dropped from the queue and shown in the refusal inbox', () async {
      final w = _wire();
      w.outbox.add(_op('key-1', summary: 'Release cash · A1B2C3'));
      w.server.on('POST', 'sync/push', body: {
        'results': [
          {
            'key': 'key-1',
            'status': 422,
            'body': {
              'error': {
                'code': 'photo_required',
                'message': 'A photo of the cash being handed over is required to release it',
              }
            }
          }
        ]
      });
      w.server.on('GET', 'sync/changes', body: _page());

      await w.sync.syncNow();

      expect(w.sync.pendingCount, 0, reason: 'retrying would be refused again');
      final refusal = w.sync.refusals.single;
      expect(refusal.operation.summary, 'Release cash · A1B2C3');
      expect(refusal.message, 'A photo of the cash being handed over is required to release it');
      expect(refusal.code, 'photo_required');
      expect(refusal.statusCode, 422);
      expect(refusal.acknowledged, isFalse);
      expect(w.sync.unseenRefusalCount, 1);

      w.sync.acknowledgeRefusal('key-1');
      expect(w.sync.unseenRefusalCount, 0);
      expect(w.sync.refusals, hasLength(1), reason: 'seen is not gone');

      w.sync.clearRefusals();
      expect(w.sync.refusals, isEmpty);
    });

    test('a 409 on an id already used is a refusal too, not a retry', () async {
      final w = _wire();
      w.outbox.add(_op('key-1'));
      w.server.on('POST', 'sync/push', body: {
        'results': [
          {
            'key': 'key-1',
            'status': 409,
            'body': {'error': {'code': 'id_taken', 'message': 'That id is already used'}}
          }
        ]
      });
      w.server.on('GET', 'sync/changes', body: _page());

      await w.sync.syncNow();

      expect(w.sync.pendingCount, 0);
      expect(w.sync.refusals.single.statusCode, 409);
    });

    test('refusals survive being written out and read back', () async {
      final w = _wire();
      w.outbox.add(_op('key-1'));
      w.server.on('POST', 'sync/push', body: {
        'results': [
          {'key': 'key-1', 'status': 422, 'body': {'error': {'code': 'rule', 'message': 'Refused'}}}
        ]
      });
      w.server.on('GET', 'sync/changes', body: _page());
      await w.sync.syncNow();

      final restored = Outbox()..restoreFrom(SyncService.decode(w.outbox.encode()));

      expect(restored.refusals.single.message, 'Refused');
      expect(restored.pendingCount, 0);
    });
  });

  group('pulling changes', () {
    test('a page of changes is applied, and what the server deleted goes', () async {
      final repo = AppRepository();
      final doomed = repo.cashEntries.first.id;
      final w = _wire(repository: repo);
      w.server.on('GET', 'sync/changes', body: _page(
        changes: {
          'cashEntries': [_cashEntryJson('SRV001', amount: 750000, note: 'Entered at the other branch')],
        },
        deleted: {'cashEntries': [doomed]},
        cursor: 31,
      ));

      await w.sync.syncNow();

      final arrived = w.repo.cashEntries.firstWhere((e) => e.id == 'SRV001');
      expect(arrived.amountCentavos, 750000);
      expect(arrived.account, CashAccount.sales);
      // +08:00 read back on the phone's own clock, so "today" means today.
      expect(arrived.date.isUtc, isFalse);
      expect(w.repo.cashEntries.any((e) => e.id == doomed), isFalse);
      expect(w.outbox.cursor, 31);
    });

    test('the server version replaces the phone version, it does not duplicate it', () async {
      final repo = AppRepository();
      final existing = repo.cashEntries.first;
      final w = _wire(repository: repo);
      final before = repo.cashEntries.length;
      w.server.on('GET', 'sync/changes', body: _page(
        changes: {
          'cashEntries': [_cashEntryJson(existing.id, amount: 111, note: 'Corrected on the server')],
        },
      ));

      await w.sync.syncNow();

      expect(w.repo.cashEntries, hasLength(before));
      final updated = w.repo.cashEntries.firstWhere((e) => e.id == existing.id);
      expect(updated.amountCentavos, 111);
      expect(updated.note, 'Corrected on the server');
    });

    test('paging keeps going while has_more is true, from the cursor it was given', () async {
      final w = _wire();
      var page = 0;
      w.server.on('GET', 'sync/changes', handler: (_) {
        page++;
        if (page == 1) {
          return _page(changes: {'cashEntries': [_cashEntryJson('SRV001')]}, cursor: 10, hasMore: true);
        }
        return _page(changes: {'cashEntries': [_cashEntryJson('SRV002')]}, cursor: 20);
      });

      await w.sync.syncNow();

      expect(page, 2);
      final asked = w.server.callsTo('GET', 'sync/changes');
      expect(asked.first.url.queryParameters['since'], '0');
      expect(asked.last.url.queryParameters['since'], '10', reason: 'from where the last page ended');
      expect(w.repo.cashEntries.map((e) => e.id), containsAll(['SRV001', 'SRV002']));
      expect(w.outbox.cursor, 20);
    });

    test('the first sync after signing in takes the whole snapshot', () async {
      final repo = AppRepository();
      final w = _wire(repository: repo);
      final snapshot = repo.toSnapshot();
      // A figure only the server could know, to prove the snapshot landed.
      final branches = (snapshot['branches'] as List).cast<Map<String, dynamic>>();
      branches.first['startingCash'] = 123456789;
      (snapshot['cashEntries'] as List).add(_cashEntryJson('SRV777'));
      w.server.on('GET', 'sync/snapshot', body: {...snapshot, 'cursor': 99});

      await w.sync.loadSnapshot();

      expect(w.repo.branches.first.startingCashBalanceCentavos, 123456789);
      expect(w.repo.cashEntries.any((e) => e.id == 'SRV777'), isTrue);
      expect(w.outbox.cursor, 99);
      expect(w.sync.pendingCount, 0, reason: 'a snapshot is not the phone\'s work');
      expect(w.sync.phase, SyncPhase.idle);
    });
  });

  group('one event, two log rows', () {
    test("the server's log row replaces the phone's, instead of doubling it", () async {
      final repo = AppRepository();
      final w = _wire(repository: repo);
      // Routed before the write, because the write pushes by itself.
      w.server.on('POST', 'sync/push', handler: (request) {
        final ops = (request['operations'] as List).cast<Map<String, dynamic>>();
        return {
          'results': [
            for (final op in ops) {'key': op['key'], 'status': 200, 'body': {}},
          ]
        };
      });
      TransactionLog? mine;
      w.server.on('GET', 'sync/changes', handler: (_) {
        final row = mine;
        if (row == null) return _page();
        return _page(changes: {
          'logs': [
            {
              'id': 'LOG999',
              'at': row.at.add(const Duration(seconds: 3)).toIso8601String(),
              'action': row.action.name,
              'userId': row.userId,
              'userName': row.userName,
              'role': row.role.name,
              'branch': row.branch?.name,
              'recordId': row.recordId,
              'recordKind': row.recordKind?.name,
              'summary': row.summary,
              'amount': row.amountCentavos,
              'changes': const [],
            }
          ],
        });
      });

      // The phone's own row, written the moment the cash moved.
      final batch = repo.purchaseBatchesAwaitingRelease(branchId: BranchId.kidapawan).first;
      repo.releaseBatchCash(batch.id, proofPhoto: Uint8List.fromList([1, 2, 3]));
      mine = repo.logs.firstWhere((l) => l.action == LogAction.cashReleased && l.recordId == batch.id);
      final before = repo.logs.length;

      // Let the push the write started finish, then sync deliberately.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await w.sync.syncNow();

      expect(repo.logs, hasLength(before), reason: 'one event, one row');
      expect(repo.logs.any((l) => l.id == 'LOG999'), isTrue, reason: "the server's version wins");
      expect(repo.logs.any((l) => l.id == mine!.id), isFalse);
    });
  });

  group('sending this phone to the server', () {
    test('the dry run is checked first and writes nothing', () async {
      final w = _wire();
      w.server.on('POST', 'sync/import', body: {
        'created': {'items': 12},
        'warnings': ['Two customers share a contact number'],
      });

      final report = await w.sync.importSnapshot(w.repo.toSnapshot(), dryRun: true);

      expect((report['created'] as Map)['items'], 12);
      expect(w.server.callsTo('POST', 'sync/import').single.url.queryParameters['dry_run'], 'true');
    });
  });
}
