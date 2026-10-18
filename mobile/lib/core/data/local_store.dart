import 'local_store_io.dart' if (dart.library.js_interop) 'local_store_web.dart';

/// Where this device keeps its copy of the shop — the records, and the queue
/// of writes the server has not taken yet.
///
/// A phone has a file system and a browser does not, so each has its own
/// implementation and [openLocalStore] picks one at build time. Everything
/// above this — the repository, the outbox, the sync service — never learns
/// which one it got.
abstract class LocalStore {
  /// The whole shop as JSON, or null when nothing has been saved yet.
  Future<String?> readData();

  Future<void> writeData(String json);

  /// The queue of writes still owed to the server.
  Future<String?> readOutbox();

  Future<void> writeOutbox(String json);

  /// Called when what was read back could not be understood. Whatever is
  /// there is kept rather than overwritten — a save nobody can read is still
  /// the only copy of something.
  Future<void> setAsideUnreadable();

  /// Where the copy lives, for the Sync page to show.
  String get describe;
}

/// Opens this device's store, or returns null where there is nowhere to keep
/// anything — in which case the app runs in memory and says so.
Future<LocalStore?> openLocalStore() => openPlatformStore();
