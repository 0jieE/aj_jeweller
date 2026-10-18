import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'local_store.dart';

/// The desktop's copy, in the browser's own database.
///
/// IndexedDB rather than local storage: the shop's records carry photographs,
/// and local storage is a few megabytes before it starts refusing writes. A
/// browser can still clear this — "clear site data", a private window, a
/// machine wiped — so it is a copy of the shop, never the only one. Anything
/// not yet sent is in the queue beside it and goes up when the server answers.
class BrowserStore implements LocalStore {
  static const _dbName = 'aj_jeweler';
  static const _storeName = 'shop';
  static const _dataKey = 'data';
  static const _outboxKey = 'outbox';
  static const _asideKey = 'unreadable';

  final web.IDBDatabase _db;

  BrowserStore._(this._db);

  @override
  String get describe => 'this browser (IndexedDB)';

  @override
  Future<String?> readData() => _read(_dataKey);

  @override
  Future<void> writeData(String json) => _write(_dataKey, json);

  @override
  Future<String?> readOutbox() => _read(_outboxKey);

  @override
  Future<void> writeOutbox(String json) => _write(_outboxKey, json);

  @override
  Future<void> setAsideUnreadable() async {
    final existing = await _read(_dataKey);
    if (existing == null) return;
    await _write('$_asideKey-${DateTime.now().millisecondsSinceEpoch}', existing);
  }

  Future<String?> _read(String key) async {
    final transaction = _db.transaction(_storeName.toJS, 'readonly');
    final request = transaction.objectStore(_storeName).get(key.toJS);
    final value = await _await(request);
    if (value == null || value.isUndefinedOrNull) return null;
    return (value as JSString).toDart;
  }

  Future<void> _write(String key, String json) async {
    final transaction = _db.transaction(_storeName.toJS, 'readwrite');
    await _await(transaction.objectStore(_storeName).put(json.toJS, key.toJS));
  }

  /// One IndexedDB request, as a future.
  static Future<JSAny?> _await(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request.onsuccess = (web.Event _) {
      if (!done.isCompleted) done.complete(request.result);
    }.toJS;
    request.onerror = (web.Event _) {
      if (!done.isCompleted) done.completeError(StateError('${request.error?.message}'));
    }.toJS;
    return done.future;
  }

  static Future<LocalStore?> open() async {
    final done = Completer<LocalStore?>();
    final request = web.window.indexedDB.open(_dbName, 1);
    request.onupgradeneeded = (web.Event _) {
      final db = request.result! as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;
    request.onsuccess = (web.Event _) {
      if (!done.isCompleted) done.complete(BrowserStore._(request.result! as web.IDBDatabase));
    }.toJS;
    request.onerror = (web.Event _) {
      // A private window, or site data blocked. The app still runs; it just
      // keeps nothing when the tab closes, and says so.
      debugPrint('No browser database: ${request.error?.message}');
      if (!done.isCompleted) done.complete(null);
    }.toJS;
    return done.future;
  }
}

Future<LocalStore?> openPlatformStore() => BrowserStore.open();
