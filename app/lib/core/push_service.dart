import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'config.dart';

/// Handles Firebase Cloud Messaging.
///
/// Everything here is optional: if the owner has not dropped a
/// google-services.json into the build, [available] stays false and the app
/// keeps working without push notifications.
class PushService {
  PushService(this._api);

  final ApiClient _api;
  bool available = false;
  String? token;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _opened = StreamController<Map<String, dynamic>>.broadcast();

  /// Foreground / tap events, consumed by the UI to show banners and navigate.
  Stream<Map<String, dynamic>> get onMessage => _messages.stream;
  Stream<Map<String, dynamic>> get onOpened => _opened.stream;

  FirebaseMessaging? get _messaging => available ? FirebaseMessaging.instance : null;

  Future<void> init() async {
    try {
      final messaging = FirebaseMessaging.instance;
      available = true;

      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // Messages that arrive while the app is in the background are shown by
      // the system. Taps are forwarded to the app.
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        _messages.add({
          'title': message.notification?.title ?? message.data['title'] ?? 'WorldFriends',
          'body': message.notification?.body ?? message.data['body'] ?? '',
          'data': message.data,
        });
      });
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        _opened.add(message.data);
      });
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        _opened.add(initial.data);
      }
      await registerDevice();
      messaging.onTokenRefresh.listen((fresh) async {
        token = fresh;
        await registerDevice();
      });
    } catch (error) {
      available = false;
      debugPrint('[push] unavailable: $error');
    }
  }

  Future<void> registerDevice() async {
    if (!available) return;
    try {
      final settings = await _messaging?.getToken();
      if (settings == null || settings.isEmpty) return;
      token = settings;
      await _api.post('/devices', body: {
        'fcmToken': settings,
        'platform': 'android',
        'appVersion': AppConfig.appVersion,
      });
    } catch (error) {
      debugPrint('[push] register failed: $error');
    }
  }

  Future<void> unregister() async {
    if (!available) return;
    try {
      final current = token ?? await _messaging?.getToken();
      if (current != null) {
        await _api.delete('/devices', query: {'fcmToken': current});
      }
    } catch (_) {}
  }

  void dispose() {
    _messages.close();
    _opened.close();
  }
}

/// Background handler must be a top-level function annotated for the engine.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  // The OS renders the notification; nothing else is required here.
  debugPrint('[push] background message ${message.messageId}');
}
