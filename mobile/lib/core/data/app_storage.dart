import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app_repository.dart';

/// Keeps the shop's data on the device between launches.
///
/// The whole repository is written to one JSON file shortly after every
/// change (writes are coalesced, so a burst of edits is one save), and read
/// back on startup. Starting empty, resetting to demo data, and every record
/// entered all survive closing the app.
///
/// Saves go to a temporary file first and are then renamed over the real one,
/// so a phone dying mid-write leaves the previous save intact rather than a
/// half-written file.
class AppStorage {
  static const _fileName = 'aj_jeweler_data.json';
  static const _saveDelay = Duration(milliseconds: 400);

  final AppRepository repository;
  final File file;
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

  AppStorage._(this.repository, this.file);

  /// Loads saved data into [repository] if there is any, then starts saving
  /// every change. Returns null where there is no file system (the web
  /// preview), in which case the app simply runs in memory as before.
  static Future<AppStorage?> attach(AppRepository repository) async {
    if (kIsWeb) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
      final storage = AppStorage._(repository, file);
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

  /// The queue of unsent writes lives beside the data, so a phone closed
  /// mid-shift still owes the server exactly what it owed before.
  File get _outboxFile => File('${file.path}.outbox');

  Future<void> saveOutbox(String json) async {
    _outboxWaiting = json;
    if (_savingOutbox) return;
    _savingOutbox = true;
    try {
      while (_outboxWaiting != null) {
        final next = _outboxWaiting!;
        _outboxWaiting = null;
        final temp = File('${_outboxFile.path}.tmp');
        await temp.writeAsString(next, flush: true);
        await temp.rename(_outboxFile.path);
      }
    } catch (error) {
      debugPrint('Could not save the sync queue: $error');
    } finally {
      _savingOutbox = false;
    }
  }

  Future<Map<String, dynamic>?> readOutbox() async {
    try {
      if (!await _outboxFile.exists()) return null;
      return (jsonDecode(await _outboxFile.readAsString()) as Map).cast<String, dynamic>();
    } catch (error) {
      debugPrint('Could not read the sync queue: $error');
      return null;
    }
  }

  Future<void> _load() async {
    if (!await file.exists()) {
      // First launch: nothing saved yet, so the demo data stands — and is
      // written now, so the next launch reads it back instead of re-seeding.
      await save();
      return;
    }
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      repository.restoreSnapshot(json);
    } catch (error) {
      // An unreadable save is kept aside rather than overwritten, so nothing
      // is silently destroyed; the app falls back to demo data.
      debugPrint('Could not read saved data: $error');
      final aside = File('${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}');
      await file.rename(aside.path);
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
      final json = jsonEncode(repository.toSnapshot());
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(json, flush: true);
      await temp.rename(file.path);
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
