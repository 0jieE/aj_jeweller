/// Where the server is.
///
/// The shop's server is the default, so a build with no arguments is the one
/// the counter should be running. Point a build somewhere else — a laptop on
/// the shop's Wi-Fi, a staging server — at build time:
///
/// ```
/// flutter run --dart-define=API_BASE_URL=http://192.168.0.107:8000/api/v1
/// ```
class ApiConfig {
  ApiConfig._();

  /// The shop's own server.
  static const shopServer = 'https://aj-jeweller.onrender.com/api/v1/';

  static const _override = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl => _normalise(_override.isEmpty ? shopServer : _override);

  /// True when this build talks to somewhere other than the shop's server —
  /// shown where it matters, so nobody mistakes a test build for the real one.
  static bool get isPointedElsewhere => _override.isNotEmpty;

  static String _normalise(String url) => url.endsWith('/') ? url : '$url/';
}
