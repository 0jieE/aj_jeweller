import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';

/// A phone's copy: two files in the app's own directory.
///
/// Each save is written to a temporary file and renamed over the real one,
/// so a phone dying mid-write leaves the previous save whole rather than a
/// half-written one.
class FileStore implements LocalStore {
  static const _fileName = 'aj_jeweler_data.json';

  final File file;

  FileStore(this.file);

  File get _outboxFile => File('${file.path}.outbox');

  @override
  String get describe => file.path;

  @override
  Future<String?> readData() async =>
      await file.exists() ? file.readAsString() : null;

  @override
  Future<void> writeData(String json) => _writeThroughTemp(file, json);

  @override
  Future<String?> readOutbox() async =>
      await _outboxFile.exists() ? _outboxFile.readAsString() : null;

  @override
  Future<void> writeOutbox(String json) => _writeThroughTemp(_outboxFile, json);

  @override
  Future<void> setAsideUnreadable() async {
    if (!await file.exists()) return;
    await file.rename('${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}');
  }

  static Future<void> _writeThroughTemp(File target, String json) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(json, flush: true);
    await temp.rename(target.path);
  }
}

Future<LocalStore?> openPlatformStore() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return FileStore(File('${dir.path}${Platform.pathSeparator}${FileStore._fileName}'));
  } catch (error) {
    debugPrint('No local store: $error');
    return null;
  }
}
