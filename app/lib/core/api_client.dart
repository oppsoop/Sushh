import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'config.dart';
import 'models.dart';
import 'token_store.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.code, this.message, [this.details]);

  final int statusCode;
  final String code;
  final String message;
  final Map<String, dynamic>? details;

  bool get isNetwork => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;
  bool get isConflict => statusCode == 409;

  List<String> get suggestions {
    final raw = details?['suggestions'];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return const [];
  }

  String get friendly {
    switch (code) {
      case 'invalid_credentials':
        return 'Email or password is incorrect.';
      case 'email_not_verified':
        return 'Please verify your email first.';
      case 'username_taken':
        return 'That username is taken.';
      case 'username_change_cooldown':
        final next = details?['nextChangeAt'];
        return next == null
            ? 'You can change your username once every 30 days.'
            : 'You can change your username again on ${_prettyDate(next.toString())}.';
      case 'rate_limited':
        return 'Too many attempts. Please wait a minute.';
      case 'translation_not_configured':
        return 'Translation is not configured on the server yet.';
      case 'file_too_large':
        return 'That file is too large.';
      case 'network_error':
        return 'No connection. Check your internet and try again.';
      case 'blocked':
        return 'You cannot message this person.';
      case 'beta_closed':
        return message;
      default:
        return message;
    }
  }

  static String _prettyDate(String iso) {
    final date = DateTime.tryParse(iso)?.toLocal();
    if (date == null) return iso;
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  String toString() => 'ApiException($statusCode $code): $message';
}

/// HTTP client with silent token refresh, retries and multipart uploads.
class ApiClient {
  ApiClient({required this.tokens, http.Client? client}) : _client = client ?? http.Client();

  final TokenStore tokens;
  final http.Client _client;
  final _sessionExpired = StreamController<void>.broadcast();
  Future<bool>? _refreshInFlight;
  bool _refreshWasTransient = false;

  Stream<void> get onSessionExpired => _sessionExpired.stream;

  void dispose() {
    _client.close();
    _sessionExpired.close();
  }

  Map<String, String> get _headers {
    final headers = <String, String>{'accept': 'application/json'};
    final token = tokens.accessToken;
    if (token != null && token.isNotEmpty) headers['authorization'] = 'Bearer $token';
    return headers;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final url = path.startsWith('http') ? path : '${AppConfig.apiRoot}$path';
    final uri = Uri.parse(url);
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  /* ------------------------------ verbs ------------------------------ */

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) =>
      _request('GET', path, query: query);

  Future<Map<String, dynamic>> post(String path, {Object? body, Map<String, String>? query}) =>
      _request('POST', path, body: body, query: query);

  Future<Map<String, dynamic>> patch(String path, {Object? body}) => _request('PATCH', path, body: body);

  Future<Map<String, dynamic>> delete(String path, {Object? body, Map<String, String>? query}) =>
      _request('DELETE', path, body: body, query: query);

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool allowRefresh = true,
    int attempt = 0,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers.addAll(_headers);
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed = await _client.send(request).timeout(AppConfig.requestTimeout);
      final response = await http.Response.fromStream(streamed);
      final decoded = _decode(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return decoded;
      }
      final error = _errorFrom(response.statusCode, decoded);

      // Silent refresh: a stale access token must never log the user out.
      if (error.isUnauthorized &&
          allowRefresh &&
          (error.code == 'token_expired' || error.code == 'invalid_token' || error.code == 'unauthorized')) {
        final refreshed = await _refreshSession();
        if (refreshed) {
          return await _request(method, path, body: body, query: query, allowRefresh: false, attempt: attempt);
        }
        if (_refreshWasTransient) {
          throw ApiException(0, 'network_error', 'Could not refresh the session while offline.');
        }
      }
      throw error;
    } on TimeoutException {
      if (attempt < 1 && method == 'GET') {
        return await _request(method, path, body: body, query: query, allowRefresh: allowRefresh, attempt: attempt + 1);
      }
      throw ApiException(0, 'network_error', 'The request timed out. Check your connection.');
    } on SocketException {
      throw ApiException(0, 'network_error', 'No internet connection.');
    } on http.ClientException {
      throw ApiException(0, 'network_error', 'Network error. Please try again.');
    }
  }

  Map<String, dynamic> _decode(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : {'data': value};
    } catch (_) {
      return {'raw': body};
    }
  }

  ApiException _errorFrom(int status, Map<String, dynamic> body) {
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      return ApiException(
        status,
        (error['code'] ?? 'error').toString(),
        (error['message'] ?? 'Something went wrong').toString(),
        error['details'] is Map<String, dynamic> ? error['details'] as Map<String, dynamic> : null,
      );
    }
    return ApiException(status, 'http_$status', 'Request failed ($status).');
  }

  /* ------------------------------ refresh ------------------------------ */

  /// Rotates the refresh token once, even if several requests hit 401 together.
  Future<bool> _refreshSession() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = future;
    return future;
  }

  Future<bool> _doRefresh() async {
    _refreshWasTransient = false;
    final token = tokens.refreshToken;
    if (token == null || token.isEmpty) {
      await _expireSession();
      return false;
    }
    try {
      final response = await _client
          .post(
            _uri('/auth/refresh'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'refreshToken': token}),
          )
          .timeout(AppConfig.requestTimeout);
      if (tokens.refreshToken != token) return false; // session changed during the request
      if (response.statusCode != 200) {
        if (response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403) {
          await _expireSession();
        } else {
          _refreshWasTransient = true;
        }
        return false;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await tokens.saveTokens(access: data['accessToken'] as String?, refresh: data['refreshToken'] as String?);
      if (data['user'] is Map<String, dynamic>) {
        await tokens.saveUser(parseUser(data));
      }
      return true;
    } catch (_) {
      _refreshWasTransient = true;
      // A transient network failure must not log the user out; only a real
      // rejection does (handled above).
      return false;
    }
  }

  /// Used by the app when it wakes up with an expired access token.
  Future<bool> refreshSession() => _refreshSession();

  Future<void> _expireSession() async {
    if (!_sessionExpired.isClosed) _sessionExpired.add(null);
  }

  /* ------------------------------ upload ------------------------------ */

  /// Stream multipart content from disk, rather than buffering a whole video
  /// in memory. A retry opens a new stream and preserves the session.
  Future<Map<String, dynamic>> uploadFile({
    required File file,
    Map<String, String> fields = const {},
    String fieldName = 'file',
    String? filename,
    String mimeType = 'application/octet-stream',
    void Function(double progress)? onProgress,
    bool allowRefresh = true,
  }) => _multipart(
        path: '/media', file: file, fields: fields, fieldName: fieldName,
        filename: filename, mimeType: mimeType, onProgress: onProgress, allowRefresh: allowRefresh,
      );

  Future<Map<String, dynamic>> sendFeedback({
    required String message,
    required String appVersion,
    required Map<String, dynamic> deviceInfo,
    File? screenshot,
  }) async {
    if (screenshot == null) {
      return post('/feedback', body: {
        'message': message, 'appVersion': appVersion, 'deviceInfo': jsonEncode(deviceInfo),
      });
    }
    return uploadFileTo(
      path: '/feedback', file: screenshot, fieldName: 'screenshot',
      fields: {'message': message, 'appVersion': appVersion, 'deviceInfo': jsonEncode(deviceInfo)},
      mimeType: 'image/jpeg',
    );
  }

  Future<Map<String, dynamic>> uploadFileTo({
    required String path,
    required File file,
    required Map<String, String> fields,
    String fieldName = 'file',
    String mimeType = 'application/octet-stream',
    void Function(double progress)? onProgress,
  }) => _multipart(path: path, file: file, fields: fields, fieldName: fieldName,
      mimeType: mimeType, onProgress: onProgress);

  Future<Map<String, dynamic>> _multipart({
    required String path,
    required File file,
    required Map<String, String> fields,
    required String fieldName,
    String? filename,
    required String mimeType,
    void Function(double progress)? onProgress,
    bool allowRefresh = true,
  }) async {
    try {
      final length = await file.length();
      var sent = 0;
      final stream = http.ByteStream(file.openRead().map((chunk) {
        sent += chunk.length;
        if (length > 0) onProgress?.call(sent / length);
        return chunk;
      }));
      final request = http.MultipartRequest('POST', _uri(path))
        ..headers.addAll(_headers)
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile(fieldName, stream, length,
            filename: filename ?? file.uri.pathSegments.last, contentType: MediaType.parse(mimeType)));
      final streamed = await _client.send(request).timeout(AppConfig.uploadTimeout);
      final response = await http.Response.fromStream(streamed).timeout(AppConfig.uploadTimeout);
      final decoded = _decode(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
      final error = _errorFrom(response.statusCode, decoded);
      if (error.isUnauthorized && allowRefresh && (error.code == 'token_expired' || error.code == 'invalid_token')) {
        if (await _refreshSession()) {
          return _multipart(path: path, file: file, fields: fields, fieldName: fieldName,
              filename: filename, mimeType: mimeType, onProgress: onProgress, allowRefresh: false);
        }
        if (_refreshWasTransient) throw ApiException(0, 'network_error', 'Waiting for a connection.');
      }
      throw error;
    } on TimeoutException {
      throw ApiException(0, 'network_error', 'Upload timed out.');
    } on SocketException {
      throw ApiException(0, 'network_error', 'No internet connection.');
    } on http.ClientException {
      throw ApiException(0, 'network_error', 'Network error during upload.');
    } on FileSystemException {
      throw ApiException(400, 'file_unavailable', 'The selected file is no longer available.');
    }
  }

  /// Downloads a (signed) media URL to [destination].
  Future<File> downloadToFile(String url, File destination, {void Function(double)? onProgress}) async {
    final request = http.Request('GET', Uri.parse(AppConfig.absolute(url)));
    request.headers.addAll(_headers);
    final streamed = await _client.send(request).timeout(AppConfig.uploadTimeout);
    if (streamed.statusCode >= 400) {
      throw ApiException(streamed.statusCode, 'download_failed', 'Download failed');
    }
    final total = streamed.contentLength ?? 0;
    var received = 0;
    final sink = destination.openWrite();
    try {
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return destination;
  }
}

AppUser parseUser(Map<String, dynamic> data) {
  final user = data['user'];
  if (user is Map<String, dynamic>) return AppUser.fromJson(user);
  throw ApiException(500, 'bad_response', 'Server returned an unexpected response');
}
