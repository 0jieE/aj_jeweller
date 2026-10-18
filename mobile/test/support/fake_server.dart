import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One answer from the fake server, for a handler that has to vary its
/// status — an access token that is expired the first time and fine the
/// second, say.
class FakeReply {
  final int status;
  final Object? body;

  const FakeReply(this.status, [this.body]);
}

/// A stand-in for the Django server, so the sync tests never need one running.
///
/// Routes are matched on `METHOD path` with the base URL stripped, in the
/// order they were added, and every request is recorded — headers included —
/// so a test can check that a replay carried the same idempotency key.
class FakeServer implements http.Client {
  static const base = 'http://test.local/api/v1/';

  final List<_Route> _routes = [];
  final List<http.Request> requests = [];

  /// Answers `method path` with [status] and [body]. [body] may be a value or
  /// a function of the decoded request body, so a handler can answer
  /// differently the second time it is called.
  void on(String method, String path, {int status = 200, Object? body, Object? Function(Map<String, dynamic> request)? handler}) {
    _routes.add(_Route(method.toUpperCase(), path, status, body, handler));
  }

  /// Drops the routes named as `'METHOD path'`, so a test can replace an
  /// answer it registered earlier.
  void reset(List<String> routes) {
    for (final route in routes) {
      final parts = route.split(' ');
      _routes.removeWhere((r) => r.method == parts.first.toUpperCase() && r.path == parts.last);
    }
  }

  /// Every request made to `method path`, oldest first.
  List<http.Request> callsTo(String method, String path) => requests
      .where((r) => r.method == method.toUpperCase() && _path(r.url) == path)
      .toList();

  int countOf(String method, String path) => callsTo(method, path).length;

  static String _path(Uri url) => url.toString().replaceFirst(base, '').split('?').first;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final typed = request as http.Request;
    requests.add(typed);
    final path = _path(request.url);
    for (final route in _routes) {
      if (route.method != request.method || route.path != path) continue;
      final decoded = typed.body.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(typed.body) as Map).cast<String, dynamic>();
      final answer = route.handler != null ? route.handler!(decoded) : route.body;
      if (answer is FakeReply) return _respond(request, answer.status, answer.body);
      return _respond(request, route.status, answer);
    }
    return _respond(request, 404, {
      'error': {'code': 'not_found', 'message': 'No route for ${request.method} $path'}
    });
  }

  http.StreamedResponse _respond(http.BaseRequest request, int status, Object? body) {
    final raw = body == null ? '' : jsonEncode(body);
    final bytes = utf8.encode(raw);
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      request: request,
      headers: const {'content-type': 'application/json'},
      contentLength: bytes.length,
    );
  }

  @override
  void close() {}

  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) => throw UnimplementedError();
  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) => throw UnimplementedError();
  @override
  Future<http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      throw UnimplementedError();
  @override
  Future<http.Response> put(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      throw UnimplementedError();
  @override
  Future<http.Response> patch(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      throw UnimplementedError();
  @override
  Future<http.Response> delete(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      throw UnimplementedError();
  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) => throw UnimplementedError();
  @override
  Future<Uint8List> readBytes(Uri url, {Map<String, String>? headers}) => throw UnimplementedError();
}

class _Route {
  final String method;
  final String path;
  final int status;
  final Object? body;
  final Object? Function(Map<String, dynamic>)? handler;

  _Route(this.method, this.path, this.status, this.body, this.handler);
}
