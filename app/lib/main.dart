import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';
import 'ui/username_screen.dart';
import 'ui/verify_email_screen.dart';
import 'ui/auth_screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light),
  );
  final state = AppState();
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const WorldFriendsApp(),
    ),
  );
  unawaited(state.init());
}

class WorldFriendsApp extends StatefulWidget {
  const WorldFriendsApp({super.key});

  @override
  State<WorldFriendsApp> createState() => _WorldFriendsAppState();
}

class _WorldFriendsAppState extends State<WorldFriendsApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = context.read<AppState>();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _app.onAppResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _app.onAppPaused();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WorldFriends',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: WfTheme.dark(),
      home: const _RootRouter(),
    );
  }
}

class _RootRouter extends StatelessWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    switch (app.phase) {
      case AuthPhase.starting:
        return const _SplashScreen();
      case AuthPhase.signedOut:
        return const WelcomeScreen();
      case AuthPhase.needsVerification:
        return VerifyEmailScreen(email: app.tokens.user?.email ?? '');
      case AuthPhase.needsUsername:
        return const UsernameScreen();
      case AuthPhase.ready:
        return const HomeShell();
    }
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/logo.png', width: 96, height: 96),
            const SizedBox(height: 20),
            const Text(
              'WorldFriends',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
            const SizedBox(height: 8),
            const Text('private beta', style: TextStyle(color: WfColors.textMuted, fontSize: 12)),
            const SizedBox(height: 32),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            if (app.startupError != null) ...[
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  app.startupError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: WfColors.warning, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
