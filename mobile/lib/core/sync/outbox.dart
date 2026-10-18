import 'dart:convert';

/// One write the phone made, waiting to be told to the server.
///
/// The app never waits for the network: a purchase typed at the counter is
/// applied locally at once and queued here. The [key] is what makes replaying
/// the queue safe — the server returns the first result for a key it has
/// already seen, so a dropped connection mid-push can never double-release
/// cash.
class SyncOperation {
  final String key;
  final String method;
  final String path;
  final Map<String, dynamic> body;
  final DateTime recordedAt;

  /// What the person was doing, for the pending list and refusal inbox:
  /// "Release cash · A7K2M9".
  final String summary;

  const SyncOperation({
    required this.key,
    required this.method,
    required this.path,
    required this.body,
    required this.recordedAt,
    required this.summary,
  });

  /// The shape `POST /sync/push` expects.
  Map<String, dynamic> toPushJson() => {
        'key': key,
        'method': method,
        'path': path,
        'body': body,
        'recorded_at': recordedAt.toIso8601String(),
      };

  Map<String, dynamic> toJson() => {
        ...toPushJson(),
        'summary': summary,
      };

  static SyncOperation fromJson(Map<String, dynamic> json) => SyncOperation(
        key: json['key'] as String,
        method: json['method'] as String,
        path: json['path'] as String,
        body: ((json['body'] as Map?) ?? const {}).cast<String, dynamic>(),
        recordedAt: DateTime.parse(json['recorded_at'] as String).toLocal(),
        summary: (json['summary'] as String?) ?? json['path'] as String,
      );
}

/// A write the server refused — a rule, not a glitch. Kept until the person
/// has seen it, because the phone has already applied it locally and the two
/// now disagree.
class SyncRefusal {
  final SyncOperation operation;
  final String message;
  final String code;
  final int statusCode;
  final DateTime refusedAt;
  final bool acknowledged;

  const SyncRefusal({
    required this.operation,
    required this.message,
    required this.code,
    required this.statusCode,
    required this.refusedAt,
    this.acknowledged = false,
  });

  SyncRefusal acknowledge() => SyncRefusal(
        operation: operation,
        message: message,
        code: code,
        statusCode: statusCode,
        refusedAt: refusedAt,
        acknowledged: true,
      );

  Map<String, dynamic> toJson() => {
        'operation': operation.toJson(),
        'message': message,
        'code': code,
        'status': statusCode,
        'refused_at': refusedAt.toIso8601String(),
        'acknowledged': acknowledged,
      };

  static SyncRefusal fromJson(Map<String, dynamic> json) => SyncRefusal(
        operation: SyncOperation.fromJson((json['operation'] as Map).cast<String, dynamic>()),
        message: json['message'] as String,
        code: (json['code'] as String?) ?? 'refused',
        statusCode: (json['status'] as int?) ?? 422,
        refusedAt: DateTime.parse(json['refused_at'] as String).toLocal(),
        acknowledged: (json['acknowledged'] as bool?) ?? false,
      );
}

/// The queue of unsent writes, the refusals that came back, and the sync
/// cursor — everything the phone must not lose when it is closed.
class Outbox {
  final List<SyncOperation> _pending = [];
  final List<SyncRefusal> _refusals = [];
  int cursor = 0;
  DateTime? lastSyncedAt;

  /// Called whenever the queue changes, so it can be written to disk.
  void Function()? onChanged;

  List<SyncOperation> get pending => List.unmodifiable(_pending);
  List<SyncRefusal> get refusals => List.unmodifiable(_refusals);
  int get pendingCount => _pending.length;
  int get unseenRefusalCount => _refusals.where((r) => !r.acknowledged).length;

  void add(SyncOperation operation) {
    _pending.add(operation);
    onChanged?.call();
  }

  /// Drops an operation once the server has accepted — or refused — it.
  void remove(String key) {
    _pending.removeWhere((o) => o.key == key);
    onChanged?.call();
  }

  void addRefusal(SyncRefusal refusal) {
    _refusals.insert(0, refusal);
    onChanged?.call();
  }

  void acknowledgeRefusal(String key) {
    final index = _refusals.indexWhere((r) => r.operation.key == key);
    if (index == -1) return;
    _refusals[index] = _refusals[index].acknowledge();
    onChanged?.call();
  }

  void clearRefusals() {
    _refusals.clear();
    onChanged?.call();
  }

  void reset() {
    _pending.clear();
    _refusals.clear();
    cursor = 0;
    lastSyncedAt = null;
    onChanged?.call();
  }

  Map<String, dynamic> toJson() => {
        'cursor': cursor,
        'last_synced_at': lastSyncedAt?.toIso8601String(),
        'pending': [for (final o in _pending) o.toJson()],
        'refusals': [for (final r in _refusals) r.toJson()],
      };

  void restoreFrom(Map<String, dynamic> json) {
    _pending
      ..clear()
      ..addAll([
        for (final raw in (json['pending'] as List? ?? const []))
          SyncOperation.fromJson((raw as Map).cast<String, dynamic>()),
      ]);
    _refusals
      ..clear()
      ..addAll([
        for (final raw in (json['refusals'] as List? ?? const []))
          SyncRefusal.fromJson((raw as Map).cast<String, dynamic>()),
      ]);
    cursor = (json['cursor'] as int?) ?? 0;
    final synced = json['last_synced_at'];
    lastSyncedAt = synced is String ? DateTime.tryParse(synced) : null;
  }

  String encode() => jsonEncode(toJson());
}
