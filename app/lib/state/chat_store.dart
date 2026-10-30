import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/models.dart';
import '../core/outbox.dart';
import '../core/token_store.dart';

/// All chat state: conversation list, per-conversation message pages, optimistic
/// sending with a persistent outbox, and realtime merges from the websocket.
class ChatStore extends ChangeNotifier {
  ChatStore({required this.api, required this.tokens, required this.outbox}) {
    _uuid = const Uuid();
    _retryTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (currentUserId != null && !outbox.isEmpty) unawaited(flushOutbox());
    });
  }

  final ApiClient api;
  final TokenStore tokens;
  final Outbox outbox;
  late final Uuid _uuid;
  late final Timer _retryTimer;
  Future<int>? _flushInFlight;

  String? get currentUserId => tokens.user?.id;

  final List<Conversation> conversations = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, String?> _cursors = {};
  final Map<String, bool> _hasMore = {};
  final Map<String, bool> _loading = {};
  final Map<String, bool> _typing = {};
  final Map<String, Timer> _typingTimers = {};
  String? _conversationsCursor;
  bool loadingConversations = false;

  List<ChatMessage> messagesFor(String conversationId) => _messages[conversationId] ?? const [];
  bool hasMore(String conversationId) => _hasMore[conversationId] ?? false;
  bool isLoading(String conversationId) => _loading[conversationId] ?? false;
  bool isTyping(String conversationId) => _typing[conversationId] ?? false;

  int get totalUnread => conversations.fold(0, (sum, c) => sum + c.unreadCount);

  Conversation? conversationById(String id) {
    for (final conversation in conversations) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }

  List<ChatMessage> pendingFor(String conversationId) {
    final pending = <ChatMessage>[];
    for (final entry in outbox.forConversation(conversationId)) {
      pending.add(
        ChatMessage(
          id: 'local-${entry.clientId}',
          clientId: entry.clientId,
          conversationId: conversationId,
          senderId: currentUserId ?? '',
          kind: entry.kind,
          body: entry.body ?? (entry.kind == 'text' ? null : _kindLabel(entry.kind)),
          createdAt: entry.createdAt ?? DateTime.now(),
          status: entry.lastError == null ? MessageStatus.sending : MessageStatus.failed,
          failureReason: entry.lastError,
          isMine: true,
        ),
      );
    }
    return pending;
  }

  /* --------------------------- conversations --------------------------- */

  Future<void> loadConversations({bool refresh = true}) async {
    if (loadingConversations) return;
    loadingConversations = true;
    notifyListeners();
    try {
      final data = await api.get('/conversations', query: {'limit': '40'});
      final list = (data['conversations'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Conversation.fromJson)
          .toList();
      conversations
        ..clear()
        ..addAll(list);
      _conversationsCursor = data['nextCursor'] as String?;
      await flushOutbox();
    } catch (_) {
      // Offline: keep whatever we already had cached in memory.
    } finally {
      loadingConversations = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreConversations() async {
    final cursor = _conversationsCursor;
    if (cursor == null || loadingConversations) return;
    loadingConversations = true;
    notifyListeners();
    try {
      final data = await api.get('/conversations', query: {'limit': '40', 'cursor': cursor});
      final list = (data['conversations'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Conversation.fromJson)
          .toList();
      final known = conversations.map((c) => c.id).toSet();
      conversations.addAll(list.where((c) => !known.contains(c.id)));
      _conversationsCursor = data['nextCursor'] as String?;
    } catch (_) {} finally {
      loadingConversations = false;
      notifyListeners();
    }
  }

  /// Ensures a direct conversation exists, then returns its id.
  Future<String?> openConversationWith(FriendUser user) async {
    if (user.conversationId != null && user.conversationId!.isNotEmpty) {
      await ensureLoaded(user.conversationId!);
      return user.conversationId;
    }
    try {
      final data = await api.post('/conversations', body: {'userId': user.id});
      final id = (data['conversationId'] ?? '').toString();
      if (id.isEmpty) return null;
      if (conversationById(id) == null) {
        conversations.insert(0, Conversation(id: id, peer: user));
        notifyListeners();
      }
      await ensureLoaded(id);
      return id;
    } on ApiException {
      rethrow;
    }
  }

  /* ----------------------------- messages ----------------------------- */

  Future<void> ensureLoaded(String conversationId) async {
    if ((_messages[conversationId] ?? const []).isEmpty) {
      await loadMessages(conversationId);
    }
  }

  Future<void> loadMessages(String conversationId) async {
    _loading[conversationId] = true;
    notifyListeners();
    try {
      final data = await api.get(
        '/conversations/$conversationId/messages',
        query: {'limit': '${AppConfig.pageSize}'},
      );
      final list = (data['messages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((json) => ChatMessage.fromJson(json, currentUserId: currentUserId))
          .toList();
      _messages[conversationId] = list;
      _cursors[conversationId] = data['nextCursor'] as String?;
      _hasMore[conversationId] = data['hasMore'] == true;
      await flushOutbox();
    } catch (_) {} finally {
      final list = _messages.putIfAbsent(conversationId, () => <ChatMessage>[]);
      final known = list.map((m) => m.clientId).toSet();
      list.addAll(pendingFor(conversationId).where((m) => !known.contains(m.clientId)));
      _loading[conversationId] = false;
      notifyListeners();
    }
  }

  Future<void> loadMore(String conversationId) async {
    final cursor = _cursors[conversationId];
    if (cursor == null || isLoading(conversationId)) return;
    _loading[conversationId] = true;
    notifyListeners();
    try {
      final data = await api.get(
        '/conversations/$conversationId/messages',
        query: {'limit': '${AppConfig.pageSize}', 'cursor': cursor},
      );
      final older = (data['messages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((json) => ChatMessage.fromJson(json, currentUserId: currentUserId))
          .toList();
      final existing = _messages[conversationId] ?? <ChatMessage>[];
      final knownIds = existing.map((m) => m.id).toSet();
      _messages[conversationId] = [
        ...older.where((m) => !knownIds.contains(m.id)),
        ...existing,
      ];
      _cursors[conversationId] = data['nextCursor'] as String?;
      _hasMore[conversationId] = data['hasMore'] == true;
    } catch (_) {} finally {
      _loading[conversationId] = false;
      notifyListeners();
    }
  }

  Future<ChatMessage> sendText(String conversationId, String text) {
    return _send(
      conversationId: conversationId,
      kind: 'text',
      body: text.trim(),
    );
  }

  Future<ChatMessage> sendMedia({
    required String conversationId,
    required String kind,
    String? mediaId,
    String? body,
    String? localPath,
    String? mimeType,
    int? durationMs,
  }) => _send(conversationId: conversationId, kind: kind, body: body,
      mediaId: mediaId, localPath: localPath, mimeType: mimeType, durationMs: durationMs);

  Future<ChatMessage> _send({
    required String conversationId,
    required String kind,
    String? body,
    String? mediaId,
    String? localPath,
    String? mimeType,
    int? durationMs,
  }) async {
    final clientId = _uuid.v4();
    String? queuedPath;
    if (localPath != null && mediaId == null) {
      try {
        final support = await getApplicationSupportDirectory();
        final dir = Directory(p.join(support.path, 'worldfriends_outbox'));
        await dir.create(recursive: true);
        final suffix = p.extension(localPath).replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '');
        queuedPath = p.join(dir.path, '$clientId$suffix');
        await File(localPath).copy(queuedPath);
      } on FileSystemException {
        throw ApiException(400, 'file_unavailable', 'Could not save the attachment for sending.');
      }
    }
    final now = DateTime.now();
    final entry = OutboxEntry(
      clientId: clientId, conversationId: conversationId, kind: kind, body: body,
      mediaId: mediaId, localMediaPath: queuedPath, mimeType: mimeType,
      durationMs: durationMs, createdAt: now,
    );
    // Persist before attempting to send, so a process kill cannot lose it.
    await outbox.add(entry);
    final optimistic = ChatMessage(
      id: 'local-$clientId', clientId: clientId, conversationId: conversationId,
      senderId: currentUserId ?? '', kind: kind,
      body: body ?? (kind == 'text' ? null : _kindLabel(kind)),
      createdAt: now, status: MessageStatus.sending, isMine: true,
    );
    _messages.putIfAbsent(conversationId, () => <ChatMessage>[]).add(optimistic);
    _promoteConversation(conversationId, body ?? _kindLabel(kind));
    notifyListeners();
    await flushOutbox();
    // An already-running flush may have taken its snapshot before this entry.
    final remaining = outbox.byClientId(clientId);
    if (remaining != null && remaining.attempts == 0 && remaining.lastError == null) {
      await flushOutbox();
    }
    return _findByClientId(conversationId, clientId) ?? optimistic;
  }

  String _kindLabel(String kind) => switch (kind) {
        'image' => 'Photo',
        'video' => 'Video',
        'audio' => 'Voice message',
        'file' => 'File',
        _ => 'Message',
      };

  ChatMessage? _findByClientId(String conversationId, String clientId) {
    for (final message in _messages[conversationId] ?? const <ChatMessage>[]) {
      if (message.clientId == clientId) return message;
    }
    return null;
  }

  void _replaceLocal(String conversationId, String clientId, ChatMessage server) {
    final list = _messages[conversationId];
    if (list == null) return;
    final index = list.indexWhere((m) => m.clientId == clientId);
    if (index >= 0) {
      list[index] = server;
    } else if (!list.any((m) => m.id == server.id)) {
      list.add(server);
    }
  }

  void _promoteConversation(String conversationId, String preview) {
    final index = conversations.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      final convo = conversations.removeAt(index);
      conversations.insert(
        0,
        Conversation(
          id: convo.id,
          kind: convo.kind,
          peer: convo.peer,
          lastMessageBody: preview,
          lastMessageKind: 'text',
          lastMessageSenderId: currentUserId,
          lastMessageAt: DateTime.now(),
          unreadCount: convo.unreadCount,
          muted: convo.muted,
        ),
      );
    }
  }

  /// Only one replay can run at a time; the server additionally deduplicates
  /// every write using the stable client id.
  Future<int> flushOutbox() async {
    final running = _flushInFlight;
    if (running != null) return running;
    final future = _flushPending();
    _flushInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_flushInFlight, future)) _flushInFlight = null;
    }
  }

  Future<int> _flushPending() async {
    if (currentUserId == null) return 0;
    var sent = 0;
    var changed = false;
    for (final entry in List<OutboxEntry>.from(outbox.entries)) {
      if (entry.lastError != null) continue; // explicit retry for permanent failures
      try {
        if (entry.mediaId == null && entry.localMediaPath != null) {
          final uploaded = await api.uploadFile(
            file: File(entry.localMediaPath!), mimeType: entry.mimeType ?? 'application/octet-stream',
            fields: {'kind': entry.kind, if (entry.durationMs != null) 'durationMs': '${entry.durationMs}'},
          );
          final media = uploaded['media'];
          final id = media is Map<String, dynamic> ? media['id']?.toString() : null;
          if (id == null || id.isEmpty) throw ApiException(500, 'upload_failed', 'Upload failed');
          await outbox.saveMediaId(entry.clientId, id);
        }
        final data = await api.post('/conversations/${entry.conversationId}/messages', body: {
          'clientId': entry.clientId, 'kind': entry.kind,
          if (entry.body != null && entry.body!.isNotEmpty) 'body': entry.body,
          if (entry.mediaId != null) 'mediaId': entry.mediaId,
        });
        final server = ChatMessage.fromJson(data['message'] as Map<String, dynamic>? ?? const {},
            currentUserId: currentUserId);
        _replaceLocal(entry.conversationId, entry.clientId, server);
        await outbox.remove(entry.clientId);
        if (entry.localMediaPath != null) {
          try { await File(entry.localMediaPath!).delete(); } catch (_) {}
        }
        sent += 1;
        changed = true;
      } on ApiException catch (error) {
        final temporary = error.isNetwork || error.statusCode == 429 || error.statusCode >= 500;
        await outbox.markAttempt(entry.clientId, temporary ? null : error.friendly);
        final item = _findByClientId(entry.conversationId, entry.clientId);
        if (item != null) {
          item.status = temporary ? MessageStatus.sending : MessageStatus.failed;
          item.failureReason = temporary ? null : error.friendly;
        }
        changed = true;
        if (temporary) break;
      }
    }
    if (changed) notifyListeners();
    return sent;
  }

  Future<void> retry(String conversationId, String clientId) async {
    final entry = outbox.byClientId(clientId);
    if (entry == null) return;
    await outbox.resetError(clientId);
    final message = _findByClientId(conversationId, clientId);
    if (message != null) {
      message.status = MessageStatus.sending;
      message.failureReason = null;
      notifyListeners();
    }
    await flushOutbox();
  }

  Future<void> deleteMessage(String conversationId, String messageId) async {
    if (messageId.startsWith('local-')) {
      final clientId = messageId.substring(6);
      final entry = outbox.byClientId(clientId);
      await outbox.remove(clientId);
      if (entry?.localMediaPath != null) { try { await File(entry!.localMediaPath!).delete(); } catch (_) {} }
      _messages[conversationId]?.removeWhere((m) => m.clientId == clientId);
      notifyListeners();
      return;
    }
    await api.delete('/messages/$messageId');
    final list = _messages[conversationId];
    if (list == null) return;
    final index = list.indexWhere((m) => m.id == messageId);
    if (index >= 0) {
      final existing = list[index];
      list[index] = ChatMessage(
        id: existing.id,
        clientId: existing.clientId,
        conversationId: existing.conversationId,
        senderId: existing.senderId,
        kind: existing.kind,
        body: null,
        media: existing.media,
        createdAt: existing.createdAt,
        status: existing.status,
        isMine: existing.isMine,
        deleted: true,
      );
    }
    notifyListeners();
  }

  /* ----------------------------- receipts ----------------------------- */

  void markRead(String conversationId, String? messageId) {
    final index = conversations.indexWhere((c) => c.id == conversationId);
    if (index >= 0 && conversations[index].unreadCount != 0) {
      conversations[index].unreadCount = 0;
      notifyListeners();
    }
    onSendSignal?.call({
      'type': 'read',
      'conversationId': conversationId,
      if (messageId != null && !messageId.startsWith('local-')) 'messageId': messageId,
    });
  }

  void sendTyping(String conversationId, bool isTyping) {
    onSendSignal?.call({'type': 'typing', 'conversationId': conversationId, 'isTyping': isTyping});
  }

  /// Wired up by AppState; lets the store push frames without knowing about WS.
  void Function(Map<String, dynamic> payload)? onSendSignal;

  /* ----------------------------- realtime ----------------------------- */

  void handleEvent(Map<String, dynamic> event) {
    final type = event['type'];
    switch (type) {
      case 'message:new':
        _onIncoming(event);
        break;
      case 'message:status':
        _onStatus(event);
        break;
      case 'message:deleted':
        final conversationId = (event['conversationId'] ?? '').toString();
        final messageId = (event['messageId'] ?? '').toString();
        final list = _messages[conversationId];
        if (list != null) {
          final index = list.indexWhere((m) => m.id == messageId);
          if (index >= 0) {
            final existing = list[index];
            list[index] = ChatMessage(
              id: existing.id,
              clientId: existing.clientId,
              conversationId: existing.conversationId,
              senderId: existing.senderId,
              kind: existing.kind,
              createdAt: existing.createdAt,
              status: existing.status,
              isMine: existing.isMine,
              deleted: true,
            );
          }
        }
        notifyListeners();
        break;
      case 'typing':
        final conversationId = (event['conversationId'] ?? '').toString();
        final isTyping = event['isTyping'] == true;
        _typing[conversationId] = isTyping;
        _typingTimers[conversationId]?.cancel();
        if (isTyping) {
          _typingTimers[conversationId] = Timer(const Duration(seconds: 6), () {
            _typing[conversationId] = false;
            notifyListeners();
          });
        }
        notifyListeners();
        break;
      case 'friend:accepted':
        loadConversations();
        break;
      case 'read:ack':
        break;
    }
  }

  void _onIncoming(Map<String, dynamic> event) {
    final conversationId = (event['conversationId'] ?? '').toString();
    final raw = event['message'];
    if (raw is! Map<String, dynamic>) return;
    final message = ChatMessage.fromJson(raw, currentUserId: currentUserId);
    if (message.senderId == currentUserId) return; // echo of our own send
    final list = _messages.putIfAbsent(conversationId, () => <ChatMessage>[]);
    if (list.any((m) => m.id == message.id)) return;
    list.add(message);
    _bumpConversation(conversationId, message);
    notifyListeners();
    onIncomingMessage?.call(conversationId, message);
  }

  /// AppState hooks this to mark-read + in-app notification banners.
  void Function(String conversationId, ChatMessage message)? onIncomingMessage;

  void _bumpConversation(String conversationId, ChatMessage message) {
    final index = conversations.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      final convo = conversations.removeAt(index);
      conversations.insert(
        0,
        Conversation(
          id: convo.id,
          kind: convo.kind,
          peer: convo.peer,
          lastMessageBody: message.body,
          lastMessageKind: message.kind,
          lastMessageSenderId: message.senderId,
          lastMessageAt: message.createdAt ?? DateTime.now(),
          unreadCount: convo.unreadCount + 1,
          muted: convo.muted,
        ),
      );
    } else {
      // A brand new conversation: pull the list so the header is correct.
      loadConversations();
    }
  }

  void _onStatus(Map<String, dynamic> event) {
    final statusRaw = (event['status'] ?? '').toString();
    final conversationId = (event['conversationId'] ?? '').toString();
    final single = event['messageId']?.toString();
    final many = (event['messageIds'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList();
    final ids = <String>{if (single != null) single, ...many};
    if (ids.isEmpty) return;
    final list = _messages[conversationId];
    if (list == null) return;
    final next = switch (statusRaw) {
      'read' => MessageStatus.read,
      'delivered' => MessageStatus.delivered,
      _ => MessageStatus.sent,
    };
    var changed = false;
    for (var i = 0; i < list.length; i += 1) {
      final message = list[i];
      if (!message.isMine || !ids.contains(message.id)) continue;
      if (_rank(next) > _rank(message.status)) {
        list[i] = message.copyWith(status: next);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  int _rank(MessageStatus status) => switch (status) {
        MessageStatus.failed => 0,
        MessageStatus.sending => 0,
        MessageStatus.sent => 1,
        MessageStatus.delivered => 2,
        MessageStatus.read => 3,
      };

  void clear() {
    conversations.clear();
    _messages.clear();
    _cursors.clear();
    _hasMore.clear();
    _typing.clear();
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
    _conversationsCursor = null;
    notifyListeners();
  }  Future<void> deleteQueuedFiles() async {
    for (final entry in outbox.entries) {
      if (entry.localMediaPath != null) {
        try { await File(entry.localMediaPath!).delete(); } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _retryTimer.cancel();
    super.dispose();
  }

}
