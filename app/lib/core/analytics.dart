import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'config.dart';
import 'token_store.dart';

/// Anonymous product analytics.
///
/// Hard rule: private message contents are never collected. Any property whose
/// key looks like user content is dropped here *and* on the server.
class AnalyticsService {
  AnalyticsService(this._api, this._tokens);

  final ApiClient _api;
  final TokenStore _tokens;
  final List<Map<String, dynamic>> _queue = [];
  Timer? _timer;
  bool firebaseAvailable = false;
  FirebaseAnalytics? _firebase;

  static const Set<String> _allowedKeys = {
    'screen', 'method', 'feature', 'cold_start', 'signed_in', 'length',
  };

  void attachFirebase(FirebaseAnalytics analytics) {
    _firebase = analytics;
    firebaseAvailable = true;
  }

  Map<String, dynamic> _sanitize(Map<String, dynamic> props) {
    final clean = <String, dynamic>{};
    props.forEach((key, value) {
      if (!_allowedKeys.contains(key)) return;
      if (value is String && RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(value)) clean[key] = value;
      if (value is num || value is bool) clean[key] = value;
    });
    return clean;
  }

  void log(String name, [Map<String, dynamic> props = const {}]) {
    final sanitized = _sanitize(props);
    _queue.add({'name': name, 'props': sanitized, 'at': DateTime.now().toUtc().toIso8601String()});
    if (_queue.length > 60) _queue.removeAt(0);
    _firebase?.logEvent(name: name, parameters: sanitized.map((k, v) => MapEntry(k, v)));
    _schedule();
  }

  void screen(String name) => log('screen_view', {'screen': name});

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 12), () {
      flush();
    });
  }

  Future<void> flush() async {
    if (_queue.isEmpty) return;
    if (_tokens.accessToken == null) return;
    final batch = List<Map<String, dynamic>>.from(_queue);
    _queue.removeRange(0, batch.length);
    try {
      await _api.post('/analytics/events', body: {
        'anonId': _tokens.anonId,
        'appVersion': AppConfig.appVersion,
        'platform': 'android',
        'events': batch,
      });
    } catch (_) {
      // Analytics must never break the app or bother the user.
    }
  }

  void recordError(Object error, StackTrace? stack, {String? reason, bool fatal = false}) {
    debugPrint('[crash] ${reason ?? ''} $error');
    if (!firebaseAvailable) return;
    FirebaseCrashlytics.instance.recordError(error, stack, reason: reason, fatal: fatal);
  }
}
