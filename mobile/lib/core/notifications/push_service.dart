import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';

/// Tells the shop's phones when something needs a person.
///
/// A purchase waiting on a Cashier, an order waiting on payment, a loan
/// coming due — the counter should not have to keep checking the Dashboard.
/// The server decides who is told; this registers the phone to be told, and
/// carries the tap back to the record it is about.
class PushService extends ChangeNotifier {
  final ApiClient api;

  /// Whether Firebase started at all. False on a build with no
  /// `google-services.json`, and on the web preview, where none of this runs.
  final bool available;

  String? _token;
  bool _permissionGranted = false;
  String? _error;
  StreamSubscription<String>? _refreshes;
  StreamSubscription<RemoteMessage>? _foreground;
  StreamSubscription<RemoteMessage>? _opened;

  /// Shown in the app while it is open and in front — Android keeps a push
  /// out of the tray in that case, and the person still needs to see it.
  void Function(PushAlert alert)? onForeground;

  /// A notification the person tapped, with the app open or from cold.
  void Function(PushAlert alert)? onOpened;

  PushService({required this.api, this.available = true});

  String? get token => _token;
  bool get isRegistered => _token != null;
  bool get permissionGranted => _permissionGranted;
  String? get error => _error;

  /// Asks for permission, takes this phone's token, and tells the server
  /// about it. Safe to call again — the server treats one token as one row.
  Future<void> start() async {
    if (!available) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      _permissionGranted = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!_permissionGranted) {
        _error = 'Notifications are turned off for this phone.';
        notifyListeners();
        return;
      }

      _foreground ??= FirebaseMessaging.onMessage.listen((message) {
        onForeground?.call(PushAlert.from(message));
      });
      _opened ??= FirebaseMessaging.onMessageOpenedApp.listen((message) {
        onOpened?.call(PushAlert.from(message));
      });
      // A notification tapped while the app was closed is waiting here.
      final initial = await messaging.getInitialMessage();
      if (initial != null) onOpened?.call(PushAlert.from(initial));

      // The registration token, not the newer installation id: what the
      // server sends to is FCM's HTTP v1 `message.token`, and that is this.
      // ignore: deprecated_member_use
      _refreshes ??= messaging.onTokenRefresh.listen(_register);
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token != null) await _register(token);
    } catch (error) {
      // No notifications is a nuisance, never a reason the counter stops.
      _error = '$error';
      debugPrint('Push notifications are not set up: $error');
      notifyListeners();
    }
  }

  Future<void> _register(String token) async {
    _token = token;
    _error = null;
    notifyListeners();
    try {
      await api.post('devices', body: {
        'token': token,
        'platform': defaultTargetPlatform.name,
      });
    } on ApiUnavailable {
      // Offline: the next sign-in registers it.
    } on ApiRefusal catch (refusal) {
      _error = refusal.message;
      notifyListeners();
    } on ApiUnauthorized {
      // Signed out between taking the token and sending it.
    }
  }

  /// Signing out stops this phone being told about that person's work.
  Future<void> stop() async {
    final token = _token;
    _token = null;
    notifyListeners();
    if (token == null || !available) return;
    try {
      await api.delete('devices/$token');
    } catch (_) {
      // The server drops a token the moment Firebase rejects it anyway.
    }
    try {
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  @override
  void dispose() {
    _refreshes?.cancel();
    _foreground?.cancel();
    _opened?.cancel();
    super.dispose();
  }

  /// Starts Firebase, and says whether it is there to be started.
  static Future<bool> init() async {
    try {
      await Firebase.initializeApp();
      return true;
    } catch (error) {
      debugPrint('Firebase did not start, so there are no notifications: $error');
      return false;
    }
  }
}

/// One notification, in the app's own terms.
class PushAlert {
  final String title;
  final String body;

  /// What it is about: `purchase`, `sale`, `commitment`, `item`, or empty.
  final String kind;

  /// The record to open — a purchase batch id, a sale id, and so on.
  final String? recordId;

  const PushAlert({
    required this.title,
    required this.body,
    required this.kind,
    required this.recordId,
  });

  factory PushAlert.from(RemoteMessage message) {
    final data = message.data;
    return PushAlert(
      title: message.notification?.title ?? (data['title'] as String?) ?? 'AJ Jeweler',
      body: message.notification?.body ?? (data['body'] as String?) ?? '',
      kind: (data['kind'] as String?) ?? '',
      recordId: data['record_id'] as String?,
    );
  }

  bool get hasRecord => recordId != null && recordId!.isNotEmpty;
}
