import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the signed-in session is kept between launches.
///
/// Tokens go in Android's Keystore-backed storage rather than a plain file:
/// a stolen or backed-up phone should not hand someone the shop's cash ledger.
abstract class TokenStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> session);
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  static const _key = 'aj_jeweler_session';
  final FlutterSecureStorage _storage;

  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<Map<String, dynamic>?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return null;
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (error) {
      // A session that cannot be read is a session that has ended.
      debugPrint('Could not read the saved session: $error');
      return null;
    }
  }

  @override
  Future<void> write(Map<String, dynamic> session) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(session));
    } catch (error) {
      debugPrint('Could not save the session: $error');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (error) {
      debugPrint('Could not clear the session: $error');
    }
  }
}

/// In-memory store, for tests and for platforms without secure storage.
class MemoryTokenStore implements TokenStore {
  Map<String, dynamic>? _session;

  @override
  Future<Map<String, dynamic>?> read() async => _session;

  @override
  Future<void> write(Map<String, dynamic> session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
