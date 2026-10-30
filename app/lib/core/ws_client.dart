import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';

enum WsStatus { disconnected, connecting, connected }

/// Websocket with jittered exponential backoff, heartbeat, silent re-auth and
/// an outbound queue so nothing is lost while the connection is down.
class WsClient {
  WsClient({
    required this.tokenProvider,
    required this.onEvent,
    this.onStatusChanged,
    this.onReconnected,
    this.onAuthFailed,
  });

  final Future<String?> Function() tokenProvider;
  final void Function(Map<String, dynamic> event) onEvent;
  final void Function(WsStatus status)? onStatusChanged;
  final void Function()? onReconnected;
  final Future<void> Function()? onAuthFailed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  final List<Map<String, dynamic>> _outbox = [];
  final Random _random = Random();

  int _attempt = 0;
  bool _disposed = false;
  bool _paused = false;
  bool _wasConnectedOnce = false;
  WsStatus _status = WsStatus.disconnected;

  WsStatus get status => _status;
  bool get isConnected => _status == WsStatus.connected;
  int get pendingCount => _outbox.length;

  void _setStatus(WsStatus next) {
    if (_status == next) return;
    _status = next;
    onStatusChanged?.call(next);
  }

  Future<void> connect() async {
    if (_disposed) return;
    if (_status == WsStatus.connected || _status == WsStatus.connecting) return;
    _reconnectTimer?.cancel();
    _setStatus(WsStatus.connecting);
    try {
      final token = await tokenProvider();
      if (token == null || token.isEmpty) throw StateError('no token');
      final channel = WebSocketChannel.connect(AppConfig.wsUri(token));
      await channel.ready.timeout(const Duration(seconds: 20));
      if (_disposed) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleFrame,
        onDone: _handleClosed,
        onError: (_) => _handleClosed(),
        cancelOnError: false,
      );
      _attempt = 0;
      _setStatus(WsStatus.connected);
      _startHeartbeat();
      _flushOutbox();
      if (_wasConnectedOnce) onReconnected?.call();
      _wasConnectedOnce = true;
    } catch (_) {
      _setStatus(WsStatus.disconnected);
      _scheduleReconnect();
    }
  }

  void _handleFrame(dynamic frame) {
    if (frame is! String) return;
    Map<String, dynamic> event;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic>) return;
      event = decoded;
    } catch (_) {
      return;
    }
    if (event['type'] == 'pong') return;
    if (event['type'] == 'error' && event['code'] == 'unauthorized') {
      // Token died while connected: refresh silently and come back.
      _reauth();
      return;
    }
    onEvent(event);
  }

  Future<void> _reauth() async {
    final handler = onAuthFailed;
    if (handler != null) {
      await handler();
    }
    await _teardown();
    _attempt = 0;
    await connect();
  }

  void _handleClosed() {
    final closeCode = _channel?.closeCode;
    _teardown(sync: true);
    if (_disposed) return;
    _setStatus(WsStatus.disconnected);
    if (closeCode == 4001) {
      // Unauthorized: refresh the session before retrying instead of backing off.
      _reauth();
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _paused) return;
    _reconnectTimer?.cancel();
    final base = min(30, pow(2, min(_attempt, 5)).toInt());
    final jitter = _random.nextInt(1000) / 1000; // 0..1s
    final delayMs = (base * 1000) + (jitter * 1000).round();
    _attempt += 1;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed && !_paused) connect();
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      send({'type': 'ping'}, queueIfOffline: false);
    });
  }

  Future<void> _teardown({bool sync = false}) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final sub = _subscription;
    _subscription = null;
    if (sub != null) {
      if (sync) {
        // Fire and forget: awaiting inside onDone can deadlock the stream.
        sub.cancel();
      } else {
        await sub.cancel();
      }
    }
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }

  void _flushOutbox() {
    if (!isConnected || _outbox.isEmpty) return;
    final pending = List<Map<String, dynamic>>.from(_outbox);
    _outbox.clear();
    for (final item in pending) {
      try {
        _channel?.sink.add(jsonEncode(item));
      } catch (_) {
        _outbox.add(item);
      }
    }
  }

  /// Sends a frame. When offline the frame is queued and replayed on reconnect.
  void send(Map<String, dynamic> payload, {bool queueIfOffline = true}) {
    if (isConnected) {
      try {
        _channel?.sink.add(jsonEncode(payload));
        return;
      } catch (_) {
        // fall through to queue
      }
    }
    if (!queueIfOffline) return;
    if (_outbox.length > 300) _outbox.removeAt(0);
    _outbox.add(payload);
  }

  /// Re-subscribes to the given conversations (after reconnect or app resume).
  void subscribe(List<String> conversationIds) {
    if (conversationIds.isEmpty) return;
    send({'type': 'subscribe', 'conversationIds': conversationIds});
  }

  void pause() {
    _paused = true;
    _reconnectTimer?.cancel();
  }

  void resume() {
    _paused = false;
    if (!isConnected) {
      _attempt = 0;
      connect();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _teardown();
    _setStatus(WsStatus.disconnected);
  }
}
