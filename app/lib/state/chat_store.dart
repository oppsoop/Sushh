import 'dart:async';

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
  }

  final ApiClient api;
  final TokenStore tokens;
  final Outbox outbox;
  late final Uuid _uuid;

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
          body: entry.body,
          createdAt: entry.createdAt ?? DateTime.now(),
          status: MessageStatus.sending,
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
    } on ApiException catch (error) {
      throw error;
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
  }) {
    return _send(
      conversationId: conversationId,
      kind: kind,
      body: body,
      mediaId: mediaId,
      localPath: localPath,
    );
  }

  Future<ChatMessage> _send({
    required String conversationId,
    required String kind,
    String? body,
    String? mediaId,
    String? localPath,
  }) async {
    final clientId = _uuid.v4();
    final optimistic = ChatMessage(
      id: 'local-$clientId',
      clientId: clientId,
      conversationId: conversationId,
      senderId: currentUserId ?? '',
      kind: kind,
      body: body,
      media: null,
      createdAt: DateTime.now(),
      status: MessageStatus.sending,
      isMine: true,
    );
    final list = _messages.putIfAbsent(conversationId, () => <ChatMessage>[]);
    list.add(optimistic);
    _promoteConversation(conversationId, body ?? _kindLabel(kind));
    notifyListeners();

    final entry = OutboxEntry(
      clientId: clientId,
      conversationId: conversationId,
      kind: kind,
      body: body,
      mediaId: mediaId,
      localMediaPath: localPath,
      createdAt: optimistic.createdAt,
    );
    await outbox.add(entry);

    try {
      final data = await api.post(
        '/conversations/$conversationId/messages',
        body: {
          'clientId': clientId,
          'kind': kind,
          if (body != null && body.isNotEmpty) 'body': body,
          if (mediaId != null) 'mediaId': mediaId,
        },
      );
      final server = ChatMessage.fromJson(
        data['message'] as Map<String, dynamic>? ?? const {},
        currentUserId: currentUserId,
      );
      _replaceLocal(conversationId, clientId, server);
      await outbox.remove(clientId);
      notifyListeners();
      return server;
    } on ApiException catch (error) {
      final failed = _findByClientId(conversationId, clientId);
      if (error.isNetwork) {
        // Still queued: the outbox will retry when connectivity returns.
        await outbox.markAttempt(clientId, error.message);
        if (failed != null) failed.status = MessageStatus.sending;
      } else {
        await outbox.remove(clientId);
        if (failed != null) {
          failed.status = MessageStatus.failed;
          failed.failureReason = error.friendly;
        }
      }
      notifyListeners();
      if (!error.isNetwork) rethrow;
      return optimistic;
    }
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

  /// Replays everything in the outbox (after reconnect, resume or a manual retry).
  Future<int> flushOutbox() async {
    var sent = 0;
    for (final entry in List<OutboxEntry>.from(outbox.entries)) {
      try {
        final data = await api.post(
          '/conversations/${entry.conversationId}/messages',
          body: {
            'clientId': entry.clientId,
            'kind': entry.kind,
            if (entry.body != null && entry.body!.isNotEmpty) 'body': entry.body,
            if (entry.mediaId != null) 'mediaId': entry.mediaId,
          },
        );
        final server = ChatMessage.fromJson(
          data['message'] as Map<String, dynamic>? ?? const {},
          currentUserId: currentUserId,
        );
        _replaceLocal(entry.conversationId, entry.clientId, server);
        await outbox.remove(entry.clientId);
        sent += 1;
      } on ApiException catch (error) {
        if (error.isNetwork) break; // still offline: stop hammering
        await outbox.remove(entry.clientId);
        final failed = _findByClientId(entry.conversationId, entry.clientId);
        if (failed != null) {
          failed.status = MessageStatus.failed;
          failed.failureReason = error.friendly;
        }
      }
    }
    if (sent > 0) notifyListeners();
    return sent;
  }

  Future<void> retry(String conversationId, String clientId) async {
    final message = _findByClientId(conversationId, clientId);
    if (message != null) {
      message.status = MessageStatus.sending;
      message.failureReason = null;
      notifyListeners();
    }
    final entry = outbox.byClientId(clientId);
    if (entry == null) {
      await outbox.add(
        OutboxEntry(
          clientId: clientId,
          conversationId: conversationId,
          kind: message?.kind ?? 'text',
          body: message?.body,
          createdAt: message?.createdAt,
        ),
      );
    }
    await flushOutbox();
  }

  Future<void> deleteMessage(String conversationId, String messageId) async {
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
      if (messageId != null) 'messageId': messageId,
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
  }
}
