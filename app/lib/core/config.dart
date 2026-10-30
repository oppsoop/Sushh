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

  static String get _root => apiBaseUrl.endsWith('/')
      ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
      : apiBaseUrl;

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
