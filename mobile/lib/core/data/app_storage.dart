import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'app_repository.dart';
import 'local_store.dart';

/// Keeps the shop's data on this device between launches.
///
/// The whole repository is written out shortly after every change (writes
/// are coalesced, so a burst of edits is one save) and read back on startup,
/// so everything entered survives closing the app — on a phone and in the
/// desktop browser alike. Where it actually goes is [LocalStore]'s business.
class AppStorage {
  static const _saveDelay = Duration(milliseconds: 400);

  final AppRepository repository;
  final LocalStore store;
  Timer? _pending;
  // Held so the listener lives as long as the storage does.
  // ignore: unused_field
  AppLifecycleListener? _lifecycle;
  bool _saving = false;
  bool _dirtyWhileSaving = false;

  /// The queue is written on every change, and changes can arrive faster
  /// than a file is written. Only the newest is worth keeping, so a save in
  /// flight takes the latest when it comes back round instead of a second
  /// one racing it onto the same temporary file.
  String? _outboxWaiting;
  bool _savingOutbox = false;

  AppStorage._(this.repository, this.store);

  /// Where this device's copy lives, for the Sync page.
  String get location => store.describe;

  /// Loads saved data into [repository] if there is any, then starts saving
  /// every change. Returns null where there is nowhere to keep anything — a
  /// private window, or site data blocked — in which case the app runs in
  /// memory and the queue lives only as long as the tab does.
  static Future<AppStorage?> attach(AppRepository repository) async {
    try {
      final store = await openLocalStore();
      if (store == null) return null;
      final storage = AppStorage._(repository, store);
      await storage._load();
      repository.addListener(storage._schedule);
      // Flush straight away when the app is backgrounded or closed, rather
      // than trusting the short save delay to finish first.
      storage._lifecycle = AppLifecycleListener(
        onInactive: storage.save,
        onHide: storage.save,
        onPause: storage.save,
        onDetach: storage.save,
      );
      return storage;
    } catch (error) {
      debugPrint('AppStorage unavailable: $error');
      return null;
    }
  }

  /// The queue of unsent writes is kept beside the data, so a device closed
  /// mid-shift still owes the server exactly what it owed before.
  Future<void> saveOutbox(String json) async {
    _outboxWaiting = json;
    if (_savingOutbox) return;
    _savingOutbox = true;
    try {
      while (_outboxWaiting != null) {
        final next = _outboxWaiting!;
        _outboxWaiting = null;
        await store.writeOutbox(next);
      }
    } catch (error) {
      debugPrint('Could not save the sync queue: $error');
    } finally {
      _savingOutbox = false;
    }
  }

  Future<Map<String, dynamic>?> readOutbox() async {
    try {
      final raw = await store.readOutbox();
      if (raw == null) return null;
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (error) {
      debugPrint('Could not read the sync queue: $error');
      return null;
    }
  }

  Future<void> _load() async {
    final raw = await store.readData();
    if (raw == null) {
      // First launch: nothing saved yet, so what the app starts with stands —
      // and is written now, so the next launch reads it back.
      await save();
      return;
    }
    try {
      repository.restoreSnapshot(jsonDecode(raw) as Map<String, dynamic>);
    } catch (error) {
      // An unreadable save is kept aside rather than overwritten, so nothing
      // is silently destroyed; the app falls back to what it starts with.
      debugPrint('Could not read saved data: $error');
      await store.setAsideUnreadable();
    }
  }

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(_saveDelay, save);
  }

  /// Writes the current data now. Safe to call repeatedly.
  Future<void> save() async {
    _pending?.cancel();
    if (_saving) {
      _dirtyWhileSaving = true;
      return;
    }
    _saving = true;
    try {
      await store.writeData(jsonEncode(repository.toSnapshot()));
    } catch (error) {
      debugPrint('Could not save data: $error');
    } finally {
      _saving = false;
      if (_dirtyWhileSaving) {
        _dirtyWhileSaving = false;
        _schedule();
      }
    }
  }
}
