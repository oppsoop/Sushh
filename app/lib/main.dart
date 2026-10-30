import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('WorldFriends')))));
}

// Touch the plugin surface so a CI build proves the native dependencies link.
final Object _keepAlive = [FirebaseCrashlytics, rtc.RTCVideoRenderer];
