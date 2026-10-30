import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persists the session so the user stays logged in across restarts.
///
/// Tokens live in the Android keystore (EncryptedSharedPreferences) when
/// available. Tokens are never written to unencrypted preferences.
class TokenStore {
  static const _kAccess = 'wf.access_token';
  static const _kRefresh = 'wf.refresh_token';
  static const _kUser = 'wf.user';
  static const _kRefreshExpiry = 'wf.refresh_expiry';
  static const _kAnonId = 'wf.anon_id';
  static const _kServerUrl = 'wf.server_url';

  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  SharedPreferences? _prefs;
  bool _secureUsable = true;

  String? accessToken;
  String? refreshToken;
  DateTime? refreshExpiresAt;
  AppUser? user;
  String anonId = '';

  Future<SharedPreferences> get prefs async => _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final store = await prefs;
    if (_secureUsable) {
      try {
        accessToken = await _secure.read(key: _kAccess);
        refreshToken = await _secure.read(key: _kRefresh);
      } catch (_) {
        _secureUsable = false;
      }
    }
    // Migrate the earlier beta's plaintext tokens once, then remove them.
    final oldAccess = store.getString(_kAccess);
    final oldRefresh = store.getString(_kRefresh);
    if (_secureUsable && (oldAccess != null || oldRefresh != null)) {
      accessToken ??= oldAccess;
      refreshToken ??= oldRefresh;
      try {
        if (accessToken != null) await _secure.write(key: _kAccess, value: accessToken);
        if (refreshToken != null) await _secure.write(key: _kRefresh, value: refreshToken);
      } catch (_) {
        _secureUsable = false;
      }
    }
    await store.remove(_kAccess);
    await store.remove(_kRefresh);

    final userJson = store.getString(_kUser);
    if (userJson != null) {
      try {
        user = AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      } catch (_) {
        user = null;
      }
    }
    final expiry = store.getString(_kRefreshExpiry);
    refreshExpiresAt = expiry == null ? null : DateTime.tryParse(expiry);

    anonId = store.getString(_kAnonId) ?? '';
    if (anonId.isEmpty) {
      anonId = 'anon-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      await store.setString(_kAnonId, anonId);
    }
  }

  /// Owner-configurable backend URL (lets a beta tester point the APK at
  /// their own deployment without rebuilding).
  Future<String?> loadServerUrl() async {
    final store = await prefs;
    final value = store.getString(_kServerUrl);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> saveServerUrl(String? url) async {
    final store = await prefs;
    if (url == null || url.isEmpty) {
      await store.remove(_kServerUrl);
    } else {
      await store.setString(_kServerUrl, url);
    }
  }

  Future<void> saveTokens({String? access, String? refresh, DateTime? refreshExpiry}) async {
    if (access != null) accessToken = access;
    if (refresh != null) refreshToken = refresh;
    if (refreshExpiry != null) refreshExpiresAt = refreshExpiry;

    final store = await prefs;
    if (_secureUsable) {
      try {
        if (accessToken != null) await _secure.write(key: _kAccess, value: accessToken);
        if (refreshToken != null) await _secure.write(key: _kRefresh, value: refreshToken);
      } catch (_) {
        _secureUsable = false;
      }
    }
    // Do not persist session secrets unencrypted if the Android keystore fails.
    await store.remove(_kAccess);
    await store.remove(_kRefresh);
    if (refreshExpiresAt != null) await store.setString(_kRefreshExpiry, refreshExpiresAt!.toIso8601String());
  }

  Future<void> saveUser(AppUser? value) async {
    user = value;
    final store = await prefs;
    if (value == null) {
      await store.remove(_kUser);
    } else {
      await store.setString(_kUser, jsonEncode(value.toJson()));
    }
  }

  bool get hasSession => (refreshToken ?? '').isNotEmpty;

  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    refreshExpiresAt = null;
    user = null;
    final store = await prefs;
    await store.remove(_kAccess);
    await store.remove(_kRefresh);
    await store.remove(_kUser);
    await store.remove(_kRefreshExpiry);
    if (_secureUsable) {
      try {
        await _secure.delete(key: _kAccess);
        await _secure.delete(key: _kRefresh);
      } catch (_) {}
    }
  }
}
