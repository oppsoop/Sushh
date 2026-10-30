import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A message that has been composed but not yet acknowledged by the server.
///
/// Persisted so a crash, app kill or restart does not lose the user's text: the
/// same `clientId` is replayed and the server deduplicates it.
class OutboxEntry {
  OutboxEntry({
    required this.clientId,
    required this.conversationId,
    required this.kind,
    this.body,
    this.mediaId,
    this.localMediaPath,
    this.mimeType,
    this.durationMs,
    this.createdAt,
    this.attempts = 0,
    this.lastError,
  });

  final String clientId;
  final String conversationId;
  final String kind;
  final String? body;
  String? mediaId;
  final String? localMediaPath;
  final String? mimeType;
  final int? durationMs;
  final DateTime? createdAt;
  int attempts;
  String? lastError;

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'conversationId': conversationId,
        'kind': kind,
        'body': body,
        'mediaId': mediaId,
        'localMediaPath': localMediaPath,
        'mimeType': mimeType,
        'durationMs': durationMs,
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
        'attempts': attempts,
        'lastError': lastError,
      };

  factory OutboxEntry.fromJson(Map<String, dynamic> json) => OutboxEntry(
        clientId: (json['clientId'] ?? '').toString(),
        conversationId: (json['conversationId'] ?? '').toString(),
        kind: (json['kind'] ?? 'text').toString(),
        body: json['body']?.toString(),
        mediaId: json['mediaId']?.toString(),
        localMediaPath: json['localMediaPath']?.toString(),
        mimeType: json['mimeType']?.toString(),
        durationMs: (json['durationMs'] as num?)?.toInt(),
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        lastError: json['lastError']?.toString(),
      );
}

class Outbox {
  Outbox._(this._prefs, this._entries);

  static const String _key = 'wf.outbox.v1';
  static const int _maxEntries = 1000;

  final SharedPreferences _prefs;
  final List<OutboxEntry> _entries;

  static Future<Outbox> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final entries = <OutboxEntry>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is Map<String, dynamic>) entries.add(OutboxEntry.fromJson(item));
          }
        }
      } catch (_) {
        // Corrupt queue: start clean rather than crash on launch.
      }
    }
    return Outbox._(prefs, entries);
  }

  List<OutboxEntry> get entries => List.unmodifiable(_entries);

  List<OutboxEntry> forConversation(String conversationId) =>
      _entries.where((e) => e.conversationId == conversationId).toList();

  OutboxEntry? byClientId(String clientId) {
    for (final entry in _entries) {
      if (entry.clientId == clientId) return entry;
    }
    return null;
  }

  bool get isEmpty => _entries.isEmpty;

  Future<void> add(OutboxEntry entry) async {
    if (_entries.length >= _maxEntries && byClientId(entry.clientId) == null) {
      throw StateError('The offline queue is full. Connect to send queued messages first.');
    }
    _entries.removeWhere((e) => e.clientId == entry.clientId);
    _entries.add(entry);
    await _persist();
  }

  Future<void> remove(String clientId) async {
    _entries.removeWhere((e) => e.clientId == clientId);
    await _persist();
  }

  Future<void> markAttempt(String clientId, String? error) async {
    final entry = byClientId(clientId);
    if (entry == null) return;
    entry.attempts += 1;
    entry.lastError = error;
    await _persist();
  }

  Future<void> saveMediaId(String clientId, String mediaId) async {
    final entry = byClientId(clientId);
    if (entry == null) return;
    entry.mediaId = mediaId;
    await _persist();
  }

  Future<void> resetError(String clientId) async {
    final entry = byClientId(clientId);
    if (entry == null) return;
    entry.lastError = null;
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _prefs.setString(_key, jsonEncode(_entries.map((e) => e.toJson()).toList()));
    } catch (_) {
      // Persisting the queue is best effort; the in-memory copy still retries.
    }
  }
}
