import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/token_store.dart';
import '../models/app_user.dart';
import '../models/branch.dart';
import '../models/user_role.dart';

/// Who is signed in, and the tokens that prove it.
///
/// This replaces the app bar's person picker: the acting user now comes from
/// the server at sign-in and is never chosen from a list, so a record can only
/// name the person who actually typed it.
class SessionState extends ChangeNotifier {
  final ApiClient api;
  final TokenStore store;

  String? _access;
  String? _refresh;
  AppUser? _user;
  bool _restoring = true;

  /// Several requests can come back 401 at once; they all wait on the one
  /// refresh rather than each spending the refresh token in turn.
  Future<bool>? _refreshing;

  SessionState({required this.api, required this.store}) {
    api.accessToken = () => _access;
    api.onUnauthorized = refreshTokens;
  }

  AppUser? get user => _user;
  bool get isSignedIn => _user != null && _access != null;

  /// True until the saved session has been read — the app shows a splash
  /// rather than flashing the sign-in screen at someone already signed in.
  bool get isRestoring => _restoring;

  /// Reads any saved session. Returns true when someone is still signed in.
  Future<bool> restore() async {
    final saved = await store.read();
    if (saved != null && saved['access'] is String && saved['user'] is Map) {
      _access = saved['access'] as String;
      _refresh = saved['refresh'] as String?;
      _user = parseUser((saved['user'] as Map).cast<String, dynamic>());
    }
    _restoring = false;
    notifyListeners();
    return isSignedIn;
  }

  /// The people who can sign in, for the PIN-pad picker. Needs no token.
  Future<List<AppUser>> staff() async {
    final response = await api.get('auth/staff');
    final list = _listFrom(response.body);
    return [for (final raw in list) parseUser((raw as Map).cast<String, dynamic>())];
  }

  Future<void> signIn({required String userId, required String pin}) async {
    final response = await api.post('auth/login', body: {'user_id': userId, 'pin': pin});
    await _adopt(response.map);
  }

  /// Swaps the refresh token for a new access token. Called by [ApiClient]
  /// the moment a request comes back 401.
  Future<bool> refreshTokens() {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final attempt = _refresh == null ? Future.value(false) : _refreshOnce();
    _refreshing = attempt;
    return attempt.whenComplete(() => _refreshing = null);
  }

  Future<bool> _refreshOnce() async {
    final refresh = _refresh;
    if (refresh == null) return false;
    try {
      final response = await api.post(
        'auth/refresh',
        body: {'refresh': refresh},
        refreshable: false,
      );
      final body = response.map;
      final access = body['access'];
      if (access is! String) return false;
      _access = access;
      if (body['refresh'] is String) _refresh = body['refresh'] as String;
      await _save();
      notifyListeners();
      return true;
    } on ApiUnauthorized {
      return false;
    } on ApiRefusal {
      return false;
    }
  }

  /// Changes your own PIN. The server hands back fresh tokens, because
  /// changing a PIN ends every other session that person had.
  Future<void> changePin({required String currentPin, required String newPin}) async {
    final response = await api.post('me/pin', body: {'current_pin': currentPin, 'new_pin': newPin});
    final body = response.body;
    if (body is Map && body['access'] is String) {
      await _adopt(body.cast<String, dynamic>());
    }
  }

  Future<void> signOut() async {
    _access = null;
    _refresh = null;
    _user = null;
    await store.clear();
    notifyListeners();
  }

  /// Keeps the signed-in person in step with staff edits made elsewhere.
  void updateUser(AppUser user) {
    if (_user?.id != user.id) return;
    _user = user;
    _save();
    notifyListeners();
  }

  Future<void> _adopt(Map<String, dynamic> body) async {
    _access = body['access'] as String?;
    _refresh = body['refresh'] as String?;
    final user = body['user'];
    if (user is Map) _user = parseUser(user.cast<String, dynamic>());
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final user = _user;
    final access = _access;
    if (user == null || access == null) return;
    await store.write({
      'access': access,
      'refresh': _refresh,
      'user': userToJson(user),
    });
  }

  /// Reads a staff member from either shape the server uses: the REST
  /// serializer's snake_case, or the phone's own snapshot format.
  static AppUser parseUser(Map<String, dynamic> json) {
    final branch = json['home_branch'] ?? json['homeBranch'];
    final contact = json['contact_number'] ?? json['contact'];
    return AppUser(
      id: json['id'] as String,
      name: json['name'] as String,
      role: AppUserRole.parse(json['role'] as String?),
      homeBranch: branch == null ? null : BranchId.values.byName(branch as String),
      contactNumber: contact as String?,
      active: (json['active'] as bool?) ?? true,
    );
  }

  static Map<String, dynamic> userToJson(AppUser user) => {
        'id': user.id,
        'name': user.name,
        'role': user.role.name,
        'home_branch': user.homeBranch?.name,
        'contact_number': user.contactNumber,
        'active': user.active,
      };

  static List<dynamic> _listFrom(dynamic body) {
    if (body is List) return body;
    if (body is Map && body['results'] is List) return body['results'] as List;
    if (body is Map && body['staff'] is List) return body['staff'] as List;
    return const [];
  }
}
