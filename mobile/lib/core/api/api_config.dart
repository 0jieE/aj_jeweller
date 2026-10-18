import 'package:flutter/foundation.dart';

/// Where the server is, per build.
///
/// Set at build time so a release APK never points at a laptop:
/// `flutter build apk --dart-define=API_BASE_URL=https://api.example.com/api/v1/`.
/// Without it, debug builds assume the Django dev server: the Android emulator
/// reaches the host machine at 10.0.2.2, everything else at localhost.
class ApiConfig {
  ApiConfig._();

  static const _override = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl {
    if (_override.isNotEmpty) return _normalise(_override);
    final host = (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
        ? '10.0.2.2'
        : '192.168.0.107'; // localhost on the dev machine
    return 'http://$host:8000/api/v1/';
  }

  /// True when no server was named — the app is pointed at a dev machine.
  static bool get isDevelopmentDefault => _override.isEmpty;

  static String _normalise(String url) => url.endsWith('/') ? url : '$url/';
}
