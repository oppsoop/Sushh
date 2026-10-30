/// Build-time configuration.
///
/// The backend URL is baked in at build time so the beta APK points at the
/// owner's server without any in-app setup:
///   flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://worldfriends-api.example.com',
  );

  static const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
  static const String buildNumber = String.fromEnvironment('BUILD_NUMBER', defaultValue: '1');

  /// Google OAuth *web* client id used by google_sign_in on Android.
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );

  static String? _override;

  /// The backend currently in use: a runtime override (set in-app) when present,
  /// otherwise the URL baked in at build time.
  static String get baseUrl => _override ?? apiBaseUrl;

  /// Accepts "api.example.com", "192.168.1.20:8080", "http://host:8080/" or a
  /// full URL. Local/private hosts default to plain http because nobody has a
  /// trusted certificate on their home network.
  static String normalizeBaseUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      final host = value.split('/').first.split(':').first.toLowerCase();
      final isLocal = host == 'localhost' ||
          host == '10.0.2.2' ||
          host.endsWith('.local') ||
          RegExp(r'^10\.').hasMatch(host) ||
          RegExp(r'^192\.168\.').hasMatch(host) ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host);
      value = '${isLocal ? 'http' : 'https'}://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static void setOverride(String? url) {
    final normalized = url == null ? '' : normalizeBaseUrl(url);
    _override = normalized.isEmpty ? null : normalized;
  }

  static String get _root => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  /// REST root, e.g. https://api.example.com/v1
  static String get apiRoot => '$_root/v1';

  /// Websocket endpoint, e.g. wss://api.example.com/ws
  static Uri wsUri(String accessToken) {
    final base = Uri.parse(_root);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/ws',
      queryParameters: {'token': accessToken},
    );
  }

  /// Turns an API-relative media path ("/v1/media/x/content?sig=...") into an
  /// absolute URL the Android media players can load.
  static String absolute(String? pathOrUrl) {
    if (pathOrUrl == null || pathOrUrl.isEmpty) return '';
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) return pathOrUrl;
    if (pathOrUrl.startsWith('/')) return '$_root$pathOrUrl';
    return '$_root/$pathOrUrl';
  }

  static const Duration requestTimeout = Duration(seconds: 30);
  static const Duration uploadTimeout = Duration(minutes: 10);
  static const int pageSize = 30;
  static const String betaBadgeLabel = 'BETA';
  static const String supportEmail = 'beta@worldfriends.app';
}
