import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

/// A refusal from the server: a rule the shop lives by, in the same words the
/// app itself uses — "Payment for this order was already received".
///
/// Separate from [ApiUnavailable] on purpose: a refusal means the change is
/// wrong and must be shown to the person, while being offline means try later.
class ApiRefusal implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiRefusal({required this.statusCode, required this.code, required this.message});

  /// 422 is a business rule; 409 is an id clash. Both mean "don't retry".
  bool get isConflict => statusCode == 409;

  @override
  String toString() => message;
}

/// The server could not be reached, or it failed. The write stays queued.
class ApiUnavailable implements Exception {
  final String message;
  final int? statusCode;

  const ApiUnavailable(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// The session is no longer valid and could not be refreshed.
class ApiUnauthorized implements Exception {
  final String message;

  const ApiUnauthorized([this.message = 'Your session has ended. Sign in again.']);

  @override
  String toString() => message;
}

/// One HTTP response, already decoded.
class ApiResponse {
  final int statusCode;
  final dynamic body;

  const ApiResponse(this.statusCode, this.body);

  Map<String, dynamic> get map => (body as Map).cast<String, dynamic>();
}

/// Talks to the Django server.
///
/// Holds no session of its own: [accessToken] and [onUnauthorized] are
/// supplied by the session, so a 401 is refreshed once and the request retried
/// before anyone sees an error.
class ApiClient {
  final http.Client _http;
  final String baseUrl;

  /// The current access token, or null when signed out.
  String? Function() accessToken;

  /// Asked to refresh after a 401. Returns true when a new token is ready.
  Future<bool> Function()? onUnauthorized;

  ApiClient({
    http.Client? httpClient,
    String? baseUrl,
    String? Function()? accessToken,
    this.onUnauthorized,
  })  : _http = httpClient ?? http.Client(),
        baseUrl = baseUrl ?? ApiConfig.baseUrl,
        accessToken = accessToken ?? (() => null);

  /// Long enough to outlast a sleeping server waking up. A shop server that
  /// is idle overnight — a free hosting plan spins one down — takes the best
  /// part of a minute to answer the first request of the morning, and timing
  /// that out would tell the counter it is offline when it is not.
  static const _timeout = Duration(
    seconds: int.fromEnvironment('API_TIMEOUT_SECONDS', defaultValue: 75),
  );

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final clean = path.startsWith('/') ? path.substring(1) : path;
    final uri = Uri.parse('$baseUrl$clean');
    if (query == null || query.isEmpty) return uri;
    final params = <String, String>{
      ...uri.queryParameters,
      for (final entry in query.entries)
        if (entry.value != null) entry.key: '${entry.value}',
    };
    return uri.replace(queryParameters: params);
  }

  Future<ApiResponse> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', path, query: query);

  Future<ApiResponse> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? idempotencyKey,
    DateTime? recordedAt,
    bool refreshable = true,
  }) =>
      _send('POST', path,
          body: body,
          query: query,
          idempotencyKey: idempotencyKey,
          recordedAt: recordedAt,
          refreshable: refreshable);

  Future<ApiResponse> patch(String path, {Object? body, String? idempotencyKey}) =>
      _send('PATCH', path, body: body, idempotencyKey: idempotencyKey);

  Future<ApiResponse> put(String path, {Object? body, String? idempotencyKey}) =>
      _send('PUT', path, body: body, idempotencyKey: idempotencyKey);

  Future<ApiResponse> delete(String path, {Object? body, String? idempotencyKey}) =>
      _send('DELETE', path, body: body, idempotencyKey: idempotencyKey);

  Future<ApiResponse> _send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? idempotencyKey,
    DateTime? recordedAt,
    bool isRetry = false,
    // The refresh request itself must never ask for a refresh: a rejected
    // refresh token would otherwise chase its own tail forever.
    bool refreshable = true,
  }) async {
    final request = http.Request(method, _uri(path, query))
      ..headers['Accept'] = 'application/json';
    final token = accessToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (idempotencyKey != null) request.headers['Idempotency-Key'] = idempotencyKey;
    if (recordedAt != null) request.headers['X-Recorded-At'] = recordedAt.toIso8601String();
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    http.Response response;
    try {
      final streamed = await _http.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiUnavailable('The server did not answer in time.');
    } catch (error) {
      throw ApiUnavailable('Could not reach the server: $error');
    }

    // One refresh, one retry: a token that expired mid-use should never
    // surface as an error the person has to understand.
    if (response.statusCode == 401 && !isRetry && refreshable && onUnauthorized != null) {
      final refreshed = await onUnauthorized!();
      if (refreshed) {
        return _send(method, path,
            body: body, query: query, idempotencyKey: idempotencyKey, recordedAt: recordedAt, isRetry: true);
      }
      throw const ApiUnauthorized();
    }

    final decoded = decodeBody(response.body);
    if (response.statusCode == 401) throw const ApiUnauthorized();
    if (response.statusCode == 422 || response.statusCode == 409) {
      throw refusalFrom(response.statusCode, decoded);
    }
    if (response.statusCode >= 400) {
      throw ApiUnavailable(
        _messageFrom(decoded) ?? 'The server returned ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    return ApiResponse(response.statusCode, decoded);
  }

  static dynamic decodeBody(String raw) {
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  /// Pulls `{"error": {"code", "message"}}` out of a refused response.
  static ApiRefusal refusalFrom(int statusCode, dynamic decoded) {
    return ApiRefusal(
      statusCode: statusCode,
      code: _codeFrom(decoded) ?? (statusCode == 409 ? 'conflict' : 'refused'),
      message: _messageFrom(decoded) ?? 'The server refused this change.',
    );
  }

  static String? _codeFrom(dynamic decoded) {
    if (decoded is Map && decoded['error'] is Map) {
      final code = (decoded['error'] as Map)['code'];
      if (code is String) return code;
    }
    return null;
  }

  static String? _messageFrom(dynamic decoded) {
    if (decoded is Map) {
      if (decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String && message.isNotEmpty) return message;
      }
      for (final key in ['detail', 'message']) {
        final value = decoded[key];
        if (value is String && value.isNotEmpty) return value;
      }
      // DRF field errors: {"pin": ["This field is required."]}
      for (final value in decoded.values) {
        if (value is List && value.isNotEmpty && value.first is String) {
          return value.first as String;
        }
      }
    }
    if (decoded is String && decoded.isNotEmpty && decoded.length < 300) return decoded;
    return null;
  }

  @visibleForTesting
  void close() => _http.close();
}
