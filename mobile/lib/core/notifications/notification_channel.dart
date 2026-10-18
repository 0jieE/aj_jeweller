import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'push_service.dart';

/// The shop's one notification channel, and the only way anything reaches the
/// tray.
///
/// Two reasons this exists rather than leaving it all to Firebase:
///
/// * A notification that arrives while the app is open is never put in the
///   tray by Firebase — it is handed to the app instead. At a counter the app
///   is open most of the day, so the app posts it itself.
/// * A channel has to exist before Android will treat it as urgent. Without
///   one, a message lands quietly in the shade with no sound and no banner,
///   which in a busy shop is the same as not arriving.
class NotificationChannel {
  /// Matches the `channel_id` the server sends, and the manifest's
  /// `default_notification_channel_id`, so a message shown by Android while
  /// the app is closed lands in the same place as one the app shows itself.
  static const id = 'aj_jeweler';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static var _ready = false;

  /// Notifications are replaced per record, so a purchase that is notified
  /// twice does not stack up two rows in the shade.
  static final _ids = <String, int>{};
  static var _nextId = 1;

  static const _channel = AndroidNotificationChannel(
    id,
    'Counter alerts',
    description: 'Cash to release, orders waiting on payment, loans coming due.',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
  );

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      id,
      'Counter alerts',
      channelDescription: 'Cash to release, orders waiting on payment, loans coming due.',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    ),
  );

  /// Creates the channel and wires up taps. Called once at startup, before
  /// anything can arrive.
  static Future<void> start({required void Function(PushAlert alert) onTap}) async {
    if (_ready || kIsWeb) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload == null || payload.isEmpty) return;
          onTap(_alertFrom(payload));
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
      _ready = true;
    } catch (error) {
      debugPrint('The notification channel could not be set up: $error');
    }
  }

  /// Puts one in the tray, with sound, over whatever is on screen.
  static Future<void> show(PushAlert alert) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _idFor(alert),
        title: alert.title,
        body: alert.body,
        notificationDetails: _details,
        payload: jsonEncode({'kind': alert.kind, 'record_id': alert.recordId}),
      );
    } catch (error) {
      debugPrint('A notification could not be shown: $error');
    }
  }

  static int _idFor(PushAlert alert) {
    final key = alert.hasRecord ? '${alert.kind}:${alert.recordId}' : 'n$_nextId';
    return _ids.putIfAbsent(key, () => _nextId++);
  }

  static PushAlert _alertFrom(String payload) {
    try {
      final data = (jsonDecode(payload) as Map).cast<String, dynamic>();
      return PushAlert(
        title: '',
        body: '',
        kind: (data['kind'] as String?) ?? '',
        recordId: data['record_id'] as String?,
      );
    } catch (_) {
      return const PushAlert(title: '', body: '', kind: '', recordId: null);
    }
  }
}
