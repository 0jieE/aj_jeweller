import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../data/app_repository.dart';
import 'outbox.dart';

enum SyncPhase { idle, loading, pushing, pulling, offline, failed }

/// Keeps the phone and the server in step.
///
/// The phone is the one that works: every write lands locally first and is
/// queued. This pushes the queue in order, then takes the server's version of
/// whatever changed. The server's version always wins — it is the one that
/// applied the shop's rules.
class SyncService extends ChangeNotifier {
  final ApiClient api;
  final AppRepository repository;
  final Outbox outbox;

  /// Where the queue, the refusals and the cursor are written.
  final Future<void> Function(String json)? persist;

  SyncPhase _phase = SyncPhase.idle;
  String? _error;
  bool _running = false;

  SyncService({
    required this.api,
    required this.repository,
    Outbox? outbox,
    this.persist,
  }) : outbox = outbox ?? Outbox() {
    this.outbox.onChanged = _save;
    repository.onWrite = _enqueue;
  }

  SyncPhase get phase => _phase;

  String? get error => _error;
  int get pendingCount => outbox.pendingCount;
  int get unseenRefusalCount => outbox.unseenRefusalCount;
  List<SyncRefusal> get refusals => outbox.refusals;
  DateTime? get lastSyncedAt => outbox.lastSyncedAt;
  bool get hasPending => outbox.pendingCount > 0;

  void _enqueue(SyncOperation operation) {
    outbox.add(operation);
    notifyListeners();
    // Try straight away; failure just leaves it queued.
    unawaited(syncNow());
  }

  void _save() {
    persist?.call(outbox.encode());
  }

  /// Reads a queue left over from a previous run.
  void restoreOutbox(Map<String, dynamic> json) {
    outbox.restoreFrom(json);
    notifyListeners();
  }

  /// First sync after signing in: take the server's whole picture.
  Future<void> loadSnapshot() async {
    _set(SyncPhase.loading);
    try {
      final response = await api.get('sync/snapshot');
      final body = response.map;
      repository.applyServerSnapshot(body);
      outbox.cursor = (body['cursor'] as int?) ?? outbox.cursor;
      outbox.lastSyncedAt = DateTime.now();
      _save();
      _set(SyncPhase.idle);
    } on ApiUnavailable catch (error) {
      _fail(SyncPhase.offline, error.message);
      rethrow;
    } catch (error) {
      _fail(SyncPhase.failed, '$error');
      rethrow;
    }
  }

  /// Push what is queued, then pull what changed. Safe to call often: it
  /// never runs twice at once.
  Future<void> syncNow() async {
    if (_running) return;
    _running = true;
    try {
      if (outbox.pendingCount > 0) {
        _set(SyncPhase.pushing);
        await _push();
      }
      _set(SyncPhase.pulling);
      await _pull();
      outbox.lastSyncedAt = DateTime.now();
      _save();
      _set(SyncPhase.idle);
    } on ApiUnavailable catch (error) {
      _fail(SyncPhase.offline, error.message);
    } on ApiUnauthorized catch (error) {
      _fail(SyncPhase.failed, error.message);
    } catch (error) {
      _fail(SyncPhase.failed, '$error');
    } finally {
      _running = false;
    }
  }

  Future<void> _push() async {
    // In order, and in batches: a day's work offline is still one queue.
    while (outbox.pendingCount > 0) {
      final batch = outbox.pending.take(100).toList();
      final response = await api.post('sync/push', body: {
        'operations': [for (final op in batch) op.toPushJson()],
        'stop_on_error': false,
      });
      final results = (response.map['results'] as List? ?? const []);
      var handled = 0;
      for (final raw in results) {
        final result = (raw as Map).cast<String, dynamic>();
        final key = result['key'] as String?;
        if (key == null) continue;
        final operation = batch.firstWhere(
          (op) => op.key == key,
          orElse: () => batch.first,
        );
        final status = result['status'] as int?;
        if (status == null) continue; // skipped — it stays queued
        handled++;
        if (status < 400) {
          outbox.remove(key);
          continue;
        }
        if (status == 422 || status == 409 || status == 400 || status == 403 || status == 404) {
          // A rule, not a glitch: the person has to see it.
          final refusal = ApiClient.refusalFrom(status, result['body']);
          outbox.addRefusal(SyncRefusal(
            operation: operation,
            message: refusal.message,
            code: refusal.code,
            statusCode: status,
            refusedAt: DateTime.now(),
          ));
          outbox.remove(key);
        }
        // 5xx stays queued, with its key, for the next attempt.
      }
      if (handled == 0) break;
      if (results.length < batch.length) break;
      if (outbox.pending.isNotEmpty && outbox.pending.first.key == batch.first.key) break;
    }
  }

  Future<void> _pull() async {
    var guard = 0;
    while (guard++ < 50) {
      final response = await api.get('sync/changes', query: {'since': outbox.cursor});
      final body = response.map;
      repository.applySyncChanges(
        changes: ((body['changes'] as Map?) ?? const {}).cast<String, dynamic>(),
        deleted: ((body['deleted'] as Map?) ?? const {}).cast<String, dynamic>(),
      );
      outbox.cursor = (body['cursor'] as int?) ?? outbox.cursor;
      _save();
      if (body['has_more'] != true) break;
    }
  }

  /// Sends the phone's own saved file to the server, once.
  Future<Map<String, dynamic>> importSnapshot(
    Map<String, dynamic> snapshot, {
    bool dryRun = true,
  }) async {
    final response = await api.post(
      'sync/import',
      body: snapshot,
      query: {'dry_run': dryRun},
    );
    return response.map;
  }

  void acknowledgeRefusal(String key) {
    outbox.acknowledgeRefusal(key);
    notifyListeners();
  }

  void clearRefusals() {
    outbox.clearRefusals();
    notifyListeners();
  }

  /// Signing out leaves nothing of the previous person behind.
  void reset() {
    outbox.reset();
    _phase = SyncPhase.idle;
    _error = null;
    notifyListeners();
  }

  void _set(SyncPhase phase) {
    _phase = phase;
    if (phase != SyncPhase.failed && phase != SyncPhase.offline) _error = null;
    notifyListeners();
  }

  void _fail(SyncPhase phase, String message) {
    _phase = phase;
    _error = message;
    notifyListeners();
  }

  static Map<String, dynamic> decode(String json) =>
      (jsonDecode(json) as Map).cast<String, dynamic>();
}
