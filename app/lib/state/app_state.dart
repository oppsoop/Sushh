import 'dart:async';
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:uuid/uuid.dart';

import '../core/analytics.dart';
import '../core/api_client.dart';
import '../core/call_service.dart';
import '../core/config.dart';
import '../core/models.dart';
import '../core/outbox.dart';
import '../core/push_service.dart';
import '../core/token_store.dart';
import '../core/ws_client.dart';
import 'chat_store.dart';

enum AuthPhase {
  starting,
  signedOut,
  needsVerification,
  needsUsername,
  ready,
}

class AppState extends ChangeNotifier {
  AppState();

  late final TokenStore tokens;
  late final ApiClient api;
  late final Outbox outbox;
  late final ChatStore chat;
  late final WsClient ws;
  late final PushService push;
  late final AnalyticsService analytics;
  late final CallService calls;

  AuthPhase phase = AuthPhase.starting;
  AppUser? user;
  BetaConfig beta = BetaConfig();
  String? startupError;
  bool busy = false;
  bool firebaseReady = false;
  WsStatus wsStatus = WsStatus.disconnected;
  int pendingRequests = 0;
  int unreadNotifications = 0;
  String? pendingVerificationEmail;
  // Kept in memory only until the mailbox owner enters the verification code.
  String? _verificationPassword;

  /// Bumped whenever a foreground push/banner should be shown.
  final StreamController<Map<String, dynamic>> banners = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> notices = StreamController<String>.broadcast();

  String? activeConversationId;

  bool get isSignedIn => tokens.hasSession && user != null;
  bool get showBetaBadge => beta.showBetaBadge;
  bool get isOnline => wsStatus == WsStatus.connected;
  String get connectionLabel => switch (wsStatus) {
        WsStatus.connected => 'Online',
        WsStatus.connecting => 'Connecting…',
        WsStatus.disconnected => 'Offline - messages will send when you reconnect',
      };

  /* ------------------------------------------------------------------ *
   * Startup
   * ------------------------------------------------------------------ */

  Future<void> init() async {
    tokens = TokenStore();
    await tokens.load();
    // A saved server URL always wins over the build-time default.
    AppConfig.setOverride(await tokens.loadServerUrl());
    api = ApiClient(tokens: tokens);
    analytics = AnalyticsService(api, tokens);
    outbox = await Outbox.load();
    chat = ChatStore(api: api, tokens: tokens, outbox: outbox);
    calls = CallService(sendSignal: (payload) => ws.send(payload));
    push = PushService(api);

    ws = WsClient(
      tokenProvider: ensureAccessToken,
      onEvent: _handleWsEvent,
      onStatusChanged: (status) {
        wsStatus = status;
        notifyListeners();
      },
      onReconnected: _onReconnected,
      onAuthFailed: () async {
        await api.refreshSession();
      },
    );

    chat.onSendSignal = (payload) => ws.send(payload);
    chat.onIncomingMessage = _onIncomingMessage;
    api.onSessionExpired.listen((_) => _forceSignOut('Your session expired. Please sign in again.'));

    await _initFirebase();

    if (tokens.hasSession) {
      await bootstrap(silent: true);
    } else {
      phase = AuthPhase.signedOut;
      notifyListeners();
    }
    analytics.log('app_open', {'cold_start': true, 'signed_in': tokens.hasSession});
    unawaited(_loadPublicConfig());
  }

  Future<void> _initFirebase() async {
    try {
      await Firebase.initializeApp();
      firebaseReady = true;
      analytics.attachFirebase(FirebaseAnalytics.instance);
      FlutterError.onError = (details) {
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
        FlutterError.presentError(details);
      };
      await push.init();
      unawaited(push.onMessage.forEach((message) => banners.add(message)));
      unawaited(push.onOpened.forEach((data) {
        final conversationId = data['conversationId']?.toString();
        if (conversationId != null && conversationId.isNotEmpty) {
          openedConversationId = conversationId;
          notifyListeners();
        }
      }));
    } catch (error) {
      firebaseReady = false;
      debugPrint('[firebase] not configured: $error');
    }
  }

  String? openedConversationId;

  /// Points the app at [url] (e.g. the owner's deployment), verifies that it
  /// answers `/health`, and signs the user out because existing tokens belong
  /// to the previous server.
  Future<Map<String, dynamic>> setServerUrl(String url) async {
    final normalized = AppConfig.normalizeBaseUrl(url);
    if (normalized.isEmpty) {
      throw ApiException(400, 'invalid_url', 'Enter a server URL');
    }
    final previous = AppConfig.baseUrl;
    AppConfig.setOverride(normalized);
    try {
      final probe = ApiClient(tokens: tokens);
      final health = await probe.get('/health');
      await tokens.saveServerUrl(normalized);
      await _forceSignOut('Server updated. Please sign in again.');
      return health;
    } catch (error) {
      AppConfig.setOverride(previous);
      rethrow;
    }
  }

  /// Forgets the custom server URL and goes back to the built-in one.
  Future<void> resetServerUrl() async {
    await tokens.saveServerUrl(null);
    AppConfig.setOverride(null);
    await _forceSignOut('Back to the default server. Please sign in again.');
  }

  Future<void> _loadPublicConfig() async {
    try {
      final data = await api.get('/beta/config');
      beta = BetaConfig.fromJson(data);
      notifyListeners();
    } catch (_) {}
  }

  Future<String?> ensureAccessToken() async {
    if (tokens.accessToken != null && tokens.accessToken!.isNotEmpty) return tokens.accessToken;
    final refreshed = await api.refreshSession();
    return refreshed ? tokens.accessToken : null;
  }

  /* ------------------------------------------------------------------ *
   * Session bootstrap
   * ------------------------------------------------------------------ */

  Future<void> bootstrap({bool silent = false}) async {
    if (!silent) {
      busy = true;
      notifyListeners();
    }
    try {
      final data = await api.get('/auth/me');
      user = AppUser.fromJson(data['user'] as Map<String, dynamic>? ?? const {});
      await tokens.saveUser(user);
      beta = BetaConfig.fromJson(data['beta'] as Map<String, dynamic>? ?? const {});
      pendingRequests = (data['pending'] as Map<String, dynamic>?)?['incoming'] as int? ?? 0;
      unreadNotifications = (data['pending'] as Map<String, dynamic>?)?['notifications'] as int? ?? 0;
      startupError = null;
      _applyPhaseFromUser();
      await _afterSignIn();
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _forceSignOut(null);
      } else {
        startupError = error.friendly;
        // Offline start with a cached user: let them in, the socket will catch up.
        if (tokens.user != null) {
          user = tokens.user;
          _applyPhaseFromUser();
        } else {
          phase = AuthPhase.signedOut;
        }
      }
    } catch (error) {
      startupError = 'Could not reach the server. Check your connection.';
      if (tokens.user != null) {
        user = tokens.user;
        _applyPhaseFromUser();
      } else {
        phase = AuthPhase.signedOut;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _applyPhaseFromUser() {
    final current = user;
    if (current == null) {
      phase = AuthPhase.signedOut;
    } else if (!current.emailVerified) {
      phase = AuthPhase.needsVerification;
    } else if (current.needsUsername || !current.hasUsername) {
      phase = AuthPhase.needsUsername;
    } else {
      phase = AuthPhase.ready;
    }
  }

  Future<void> _afterSignIn() async {
    if (phase != AuthPhase.ready) return;
    await chat.loadConversations();
    await chat.flushOutbox();
    ws.connect();
    if (chat.conversations.isNotEmpty) {
      ws.subscribe(chat.conversations.map((c) => c.id).toList());
    }
    await push.registerDevice();
  }

  void _onReconnected() {
    chat.flushOutbox();
    chat.loadConversations();
    if (chat.conversations.isNotEmpty) {
      ws.subscribe(chat.conversations.map((c) => c.id).toList());
    }
    bootstrap(silent: true);
  }

  Future<void> onAppResumed() async {
    if (phase != AuthPhase.ready) return;
    ws.resume();
    await ensureAccessToken();
    await chat.flushOutbox();
    await chat.loadConversations();
  }

  void onAppPaused() {
    ws.pause();
    analytics.flush();
  }

  /* ------------------------------------------------------------------ *
   * Auth flows
   * ------------------------------------------------------------------ */

  Future<void> login({required String email, required String password}) async {
    _verificationPassword = password;
    busy = true;
    notifyListeners();
    try {
      final data = await api.post('/auth/login', body: {'email': email.trim(), 'password': password});
      await _applySession(data);
      analytics.log('login', {'method': 'password'});
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String displayName,
    String? inviteCode,
  }) async {
    busy = true;
    notifyListeners();
    try {
      final data = await api.post('/auth/register', body: {
        'email': email.trim(),
        'password': password,
        'displayName': displayName.trim(),
        if (inviteCode != null && inviteCode.trim().isNotEmpty) 'inviteCode': inviteCode.trim(),
      });
      pendingVerificationEmail = email.trim();
      _verificationPassword = password;
      analytics.log('sign_up', {'method': 'password'});
      return data;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> verifyEmail({required String email, required String code}) async {
    busy = true;
    notifyListeners();
    try {
      final password = _verificationPassword;
      if (password == null) {
        throw ApiException(400, 'password_required', 'Please sign in or sign up again before verifying.');
      }
      final data = await api.post('/auth/verify-email', body: {'email': email.trim(), 'code': code.trim(), 'password': password});
      _verificationPassword = null;
      await _applySession(data);
      analytics.log('email_verified');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> resendVerification(String email) async {
    await api.post('/auth/resend-verification', body: {'email': email.trim()});
  }

  Future<Map<String, dynamic>> forgotPassword(String email) async {
    return api.post('/auth/password/forgot', body: {'email': email.trim()});
  }

  Future<void> resetPassword({required String email, required String code, required String newPassword}) async {
    final data = await api.post('/auth/password/reset', body: {
      'email': email.trim(),
      'code': code.trim(),
      'newPassword': newPassword,
    });
    await _applySession(data);
  }

  Future<void> signInWithGoogle() async {
    busy = true;
    notifyListeners();
    try {
      final google = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: AppConfig.googleServerClientId.isEmpty ? null : AppConfig.googleServerClientId,
      );
      final account = await google.signIn();
      if (account == null) return;
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) {
        throw ApiException(400, 'google_token_missing', 'Google did not return an ID token.');
      }
      final data = await api.post('/auth/google', body: {'idToken': idToken});
      await _applySession(data);
      analytics.log('login', {'method': 'google'});
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _applySession(Map<String, dynamic> data) async {
    await tokens.saveTokens(
      access: data['accessToken'] as String?,
      refresh: data['refreshToken'] as String?,
    );
    if (data['user'] is Map<String, dynamic>) {
      user = AppUser.fromJson(data['user'] as Map<String, dynamic>);
      await tokens.saveUser(user);
    }
    _applyPhaseFromUser();
    notifyListeners();
    if (phase == AuthPhase.ready) {
      await bootstrap(silent: true);
      await _afterSignIn();
    }
  }

  /* ------------------------------------------------------------------ *
   * Username
   * ------------------------------------------------------------------ */

  Future<UsernameAvailability> checkUsername(String username) async {
    try {
      final data = await api.get('/username/available', query: {'username': username});
      return UsernameAvailability.fromJson(data);
    } on ApiException catch (error) {
      if (error.statusCode == 429) {
        return UsernameAvailability(username: username, available: false, reason: 'rate_limited', message: 'Slow down a moment.');
      }
      rethrow;
    }
  }

  Future<List<String>> usernameIdeas() async {
    return const [];
  }

  Future<void> claimUsername(String username) async {
    busy = true;
    notifyListeners();
    try {
      final data = await api.post('/username/claim', body: {'username': username});
      if (data['user'] is Map<String, dynamic>) {
        user = AppUser.fromJson(data['user'] as Map<String, dynamic>);
        await tokens.saveUser(user);
      }
      _applyPhaseFromUser();
      analytics.log('username_claimed');
      notifyListeners();
      await bootstrap(silent: true);
      await _afterSignIn();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> changeUsername(String username) async {
    final data = await api.post('/username/change', body: {'username': username, 'confirm': true});
    if (data['user'] is Map<String, dynamic>) {
      user = AppUser.fromJson(data['user'] as Map<String, dynamic>);
      await tokens.saveUser(user);
      notifyListeners();
    }
    return data;
  }

  /* ------------------------------------------------------------------ *
   * Profile
   * ------------------------------------------------------------------ */

  Future<void> updateProfile({String? displayName, String? bio, File? avatar}) async {
    String? avatarMediaId;
    if (avatar != null) {
      final uploaded = await api.uploadFile(
        file: avatar,
        mimeType: 'image/jpeg',
        fields: {'kind': 'image'},
      );
      avatarMediaId = (uploaded['media'] as Map<String, dynamic>?)?['id']?.toString();
    }
    final data = await api.patch('/users/me', body: {
      if (displayName != null) 'displayName': displayName,
      if (bio != null) 'bio': bio,
      if (avatarMediaId != null) 'avatarMediaId': avatarMediaId,
    });
    if (data['user'] is Map<String, dynamic>) {
      user = AppUser.fromJson(data['user'] as Map<String, dynamic>);
      await tokens.saveUser(user);
      notifyListeners();
    }
  }

  /* ------------------------------------------------------------------ *
   * Feedback / analytics
   * ------------------------------------------------------------------ */

  Future<void> sendFeedback({
    required String message,
    required Map<String, dynamic> deviceInfo,
    File? screenshot,
  }) async {
    await api.sendFeedback(
      message: message,
      appVersion: '${AppConfig.appVersion} (${AppConfig.buildNumber})',
      deviceInfo: deviceInfo,
      screenshot: screenshot,
    );
    analytics.log('feedback_sent');
  }

  /* ------------------------------------------------------------------ *
   * Logout / delete
   * ------------------------------------------------------------------ */

  Future<void> logout() async {
    final refresh = tokens.refreshToken;
    try {
      await push.unregister();
      if (refresh != null) await api.post('/auth/logout', body: {'refreshToken': refresh});
    } catch (_) {}
    await _clearLocal();
    phase = AuthPhase.signedOut;
    notifyListeners();
  }

  Future<void> deleteAccount(String password) async {
    await api.delete('/users/me', body: {'password': password, 'confirm': 'DELETE'});
    await _clearLocal();
    phase = AuthPhase.signedOut;
    notifyListeners();
  }

  Future<void> _clearLocal() async {
    await ws.dispose();
    chat.clear();
    await outbox.clear();
    await tokens.clear();
    user = null;
    _verificationPassword = null;
  }

  Future<void> _forceSignOut(String? notice) async {
    await _clearLocal();
    phase = AuthPhase.signedOut;
    startupError = notice;
    if (notice != null) notices.add(notice);
    notifyListeners();
  }

  /* ------------------------------------------------------------------ *
   * Realtime fan-out
   * ------------------------------------------------------------------ */

  void _handleWsEvent(Map<String, dynamic> event) {
    chat.handleEvent(event);
    switch (event['type']) {
      case 'message:new':
        break;
      case 'call:incoming':
        calls.handleIncoming(event);
        notifyListeners();
        break;
      case 'call:answer':
        calls.handleAnswer(event);
        break;
      case 'call:ice':
        calls.handleRemoteIce(event);
        break;
      case 'call:end':
        calls.handleRemoteEnd();
        break;
      case 'call:reject':
        calls.handleRemoteEnd(remoteRejected: true);
        break;
      case 'friend:request':
        pendingRequests += 1;
        final from = event['from'];
        final name = from is Map<String, dynamic> ? (from['displayName'] ?? from['username'] ?? 'Someone') : 'Someone';
        banners.add({'title': 'New friend request', 'body': '$name wants to connect', 'data': const {}});
        notifyListeners();
        break;
      case 'friend:accepted':
        pendingRequests = pendingRequests > 0 ? pendingRequests - 1 : 0;
        notifyListeners();
        break;
      case 'post:liked':
      case 'post:commented':
        unreadNotifications += 1;
        notifyListeners();
        break;
      case 'story:new':
        break;
      case 'account:deleted':
        _forceSignOut('Your account was deleted.');
        break;
    }
  }

  void _onIncomingMessage(String conversationId, ChatMessage message) {
    if (activeConversationId == conversationId) {
      chat.markRead(conversationId, message.id);
    } else {
      banners.add({
        'title': chat.conversationById(conversationId)?.title ?? 'New message',
        'body': message.body ?? 'Sent you an attachment',
        'data': {'conversationId': conversationId},
      });
    }
  }

  void setActiveConversation(String? conversationId) {
    activeConversationId = conversationId;
    if (conversationId != null) {
      final convo = chat.conversationById(conversationId);
      final messages = chat.messagesFor(conversationId);
      chat.markRead(conversationId, messages.isEmpty ? null : messages.last.id);
      if (convo != null) convo.unreadCount = 0;
    }
    notifyListeners();
  }

  String newCallId() => const Uuid().v4();

  @override
  void dispose() {
    ws.dispose();
    api.dispose();
    push.dispose();
    banners.close();
    notices.close();
    super.dispose();
  }
}
