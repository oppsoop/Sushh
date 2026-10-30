import 'config.dart';

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

DateTime? _date(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString())?.toLocal();
}

int _int(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool _bool(dynamic value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return fallback;
}

double? _double(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

class AppUser {
  AppUser({
    required this.id,
    this.email,
    this.emailVerified = false,
    this.username,
    this.displayName = '',
    this.bio = '',
    this.avatarUrl,
    this.profileUrl,
    this.hasUsername = false,
    this.needsUsername = false,
    this.usernameChangeAvailableAt,
    this.isBeta = false,
  });

  final String id;
  final String? email;
  final bool emailVerified;
  final String? username;
  final String displayName;
  final String bio;
  final String? avatarUrl;
  final String? profileUrl;
  final bool hasUsername;
  final bool needsUsername;
  final DateTime? usernameChangeAvailableAt;
  final bool isBeta;

  String get handle => username == null ? '' : '@$username';
  String get label => displayName.trim().isNotEmpty ? displayName : (username ?? 'You');

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: (json['id'] ?? '').toString(),
        email: json['email']?.toString(),
        emailVerified: _bool(json['emailVerified']),
        username: json['username']?.toString(),
        displayName: (json['displayName'] ?? '').toString(),
        bio: (json['bio'] ?? '').toString(),
        avatarUrl: json['avatarUrl'] == null ? null : AppConfig.absolute(json['avatarUrl'].toString()),
        profileUrl: json['profileUrl']?.toString(),
        hasUsername: _bool(json['hasUsername']) || json['username'] != null,
        needsUsername: _bool(json['needsUsername']),
        usernameChangeAvailableAt: _date(json['usernameChangeAvailableAt']),
        isBeta: _bool(json['isBeta']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'emailVerified': emailVerified,
        'username': username,
        'displayName': displayName,
        'bio': bio,
        'avatarUrl': avatarUrl,
        'profileUrl': profileUrl,
        'hasUsername': hasUsername,
        'needsUsername': needsUsername,
        'usernameChangeAvailableAt': usernameChangeAvailableAt?.toIso8601String(),
        'isBeta': isBeta,
      };
}

class FriendUser {
  FriendUser({
    required this.id,
    this.username,
    this.displayName = '',
    this.bio = '',
    this.avatarUrl,
    this.online = false,
    this.lastSeenAt,
    this.isFriend = false,
    this.requestPending = false,
    this.following = false,
    this.followers = 0,
    this.followingCount = 0,
    this.posts = 0,
    this.isMe = false,
    this.matchType,
    this.conversationId,
    this.outgoingRequestId,
    this.incomingRequestId,
  });

  final String id;
  final String? username;
  final String displayName;
  final String bio;
  final String? avatarUrl;
  final bool online;
  final DateTime? lastSeenAt;
  final bool isFriend;
  final bool requestPending;
  final bool following;
  final int followers;
  final int followingCount;
  final int posts;
  final bool isMe;
  final String? matchType;
  final String? conversationId;
  final String? outgoingRequestId;
  final String? incomingRequestId;

  String get label => displayName.trim().isNotEmpty ? displayName : (username ?? 'Friend');
  String get handle => username == null ? '' : '@$username';

  factory FriendUser.fromJson(Map<String, dynamic> json) => FriendUser(
        id: (json['id'] ?? '').toString(),
        username: json['username']?.toString(),
        displayName: (json['displayName'] ?? '').toString(),
        bio: (json['bio'] ?? '').toString(),
        avatarUrl: json['avatarUrl'] == null ? null : AppConfig.absolute(json['avatarUrl'].toString()),
        online: _bool(json['online']),
        lastSeenAt: _date(json['lastSeenAt']),
        isFriend: _bool(json['isFriend']),
        requestPending: _bool(json['requestPending']),
        following: _bool(json['following']),
        followers: _int(json['followers']),
        followingCount: _int(json['followingCount']),
        posts: _int(json['posts']),
        isMe: _bool(json['isMe']),
        matchType: json['matchType']?.toString(),
        conversationId: json['conversationId']?.toString(),
        outgoingRequestId: json['outgoingRequestId']?.toString(),
        incomingRequestId: json['incomingRequestId']?.toString(),
      );

  FriendUser copyWith({bool? following, bool? isFriend}) => FriendUser(
        id: id,
        username: username,
        displayName: displayName,
        bio: bio,
        avatarUrl: avatarUrl,
        online: online,
        lastSeenAt: lastSeenAt,
        isFriend: isFriend ?? this.isFriend,
        requestPending: requestPending,
        following: following ?? this.following,
        followers: followers,
        followingCount: followingCount,
        posts: posts,
        isMe: isMe,
        matchType: matchType,
        conversationId: conversationId,
        outgoingRequestId: outgoingRequestId,
        incomingRequestId: incomingRequestId,
      );
}

class MediaItem {
  MediaItem({
    required this.id,
    required this.kind,
    this.mime = '',
    this.bytes = 0,
    this.width,
    this.height,
    this.durationMs,
    this.originalName,
    this.url = '',
    this.thumbUrl,
  });

  final String id;
  final String kind; // image | video | audio | file
  final String mime;
  final int bytes;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? originalName;
  final String url;
  final String? thumbUrl;

  String get playableUrl => AppConfig.absolute(url);
  String get thumbnailUrl => AppConfig.absolute(thumbUrl ?? url);
  Duration get duration => Duration(milliseconds: durationMs ?? 0);
  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get isImage => kind == 'image';
  bool get isVideo => kind == 'video';
  bool get isAudio => kind == 'audio';

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? 'file').toString(),
        mime: (json['mime'] ?? '').toString(),
        bytes: _int(json['bytes']),
        width: json['width'] == null ? null : _int(json['width']),
        height: json['height'] == null ? null : _int(json['height']),
        durationMs: json['durationMs'] == null ? null : _int(json['durationMs']),
        originalName: json['originalName']?.toString(),
        url: (json['url'] ?? '').toString(),
        thumbUrl: json['thumbUrl']?.toString(),
      );
}

enum MessageStatus { sending, sent, delivered, read, failed }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.clientId,
    required this.conversationId,
    required this.senderId,
    required this.kind,
    this.body,
    this.media,
    this.createdAt,
    this.status = MessageStatus.sent,
    this.isMine = false,
    this.deleted = false,
    this.failureReason,
    this.pendingMediaPath,
  });

  final String id;
  final String clientId;
  final String conversationId;
  final String senderId;
  final String kind;
  final String? body;
  final MediaItem? media;
  final DateTime? createdAt;
  MessageStatus status;
  final bool isMine;
  final bool deleted;
  String? failureReason;

  /// Local file path shown while an upload is still in flight.
  final String? pendingMediaPath;

  bool get isDeleted => deleted;

  factory ChatMessage.fromJson(Map<String, dynamic> json, {String? currentUserId}) {
    final senderId = (json['senderId'] ?? '').toString();
    final statusRaw = (json['status'] ?? 'sent').toString();
    final mediaJson = json['media'];
    return ChatMessage(
      id: (json['id'] ?? '').toString(),
      clientId: (json['clientId'] ?? json['client_id'] ?? '').toString(),
      conversationId: (json['conversationId'] ?? '').toString(),
      senderId: senderId,
      kind: (json['kind'] ?? 'text').toString(),
      body: json['body']?.toString(),
      media: mediaJson is Map<String, dynamic> && (mediaJson['id'] ?? mediaJson['url']) != null
          ? MediaItem.fromJson(mediaJson)
          : null,
      createdAt: _date(json['createdAt']),
      status: switch (statusRaw) {
        'read' => MessageStatus.read,
        'delivered' => MessageStatus.delivered,
        'failed' => MessageStatus.failed,
        _ => MessageStatus.sent,
      },
      isMine: currentUserId != null && senderId == currentUserId,
      deleted: json['deletedAt'] != null || json['deleted'] == true,
    );
  }

  ChatMessage copyWith({
    MessageStatus? status,
    MediaItem? media,
    String? failureReason,
    bool clearFailure = false,
  }) =>
      ChatMessage(
        id: id,
        clientId: clientId,
        conversationId: conversationId,
        senderId: senderId,
        kind: kind,
        body: body,
        media: media ?? this.media,
        createdAt: createdAt,
        status: status ?? this.status,
        isMine: isMine,
        deleted: deleted,
        failureReason: clearFailure ? null : (failureReason ?? this.failureReason),
        pendingMediaPath: pendingMediaPath,
      );
}

class Conversation {
  Conversation({
    required this.id,
    this.kind = 'direct',
    this.peer,
    this.lastMessageBody,
    this.lastMessageKind,
    this.lastMessageSenderId,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.muted = false,
  });

  final String id;
  final String kind;
  final FriendUser? peer;
  final String? lastMessageBody;
  final String? lastMessageKind;
  final String? lastMessageSenderId;
  final DateTime? lastMessageAt;
  int unreadCount;
  final bool muted;

  String get title => peer?.label ?? 'Chat';
  String? get avatarUrl => peer?.avatarUrl;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final last = json['lastMessage'];
    final peerJson = json['peer'];
    return Conversation(
      id: (json['id'] ?? '').toString(),
      kind: (json['kind'] ?? 'direct').toString(),
      peer: peerJson is Map<String, dynamic> ? FriendUser.fromJson(peerJson) : null,
      lastMessageBody: last is Map<String, dynamic> ? last['body']?.toString() : null,
      lastMessageKind: last is Map<String, dynamic> ? last['kind']?.toString() : null,
      lastMessageSenderId: last is Map<String, dynamic> ? last['senderId']?.toString() : null,
      lastMessageAt: _date(json['lastMessageAt']),
      unreadCount: _int(json['unreadCount']),
      muted: _bool(json['muted']),
    );
  }

  String previewText(String? myUserId) {
    final body = lastMessageBody;
    if (lastMessageAt == null) return 'Say hello';
    final prefix = lastMessageSenderId == myUserId ? 'You: ' : '';
    switch (lastMessageKind) {
      case 'image':
        return '${prefix}Photo';
      case 'video':
        return '${prefix}Video';
      case 'audio':
        return '${prefix}Voice message';
      case 'file':
        return '${prefix}File';
      case 'call':
        return '${prefix}Call';
      default:
        return '$prefix${body ?? ''}';
    }
  }

  Conversation withLastMessage({String? body, String? kind, String? senderId, DateTime? at}) => Conversation(
        id: id,
        kind: kind_,
        peer: peer,
        lastMessageBody: body ?? lastMessageBody,
        lastMessageKind: kind ?? lastMessageKind,
        lastMessageSenderId: senderId ?? lastMessageSenderId,
        lastMessageAt: at ?? lastMessageAt,
        unreadCount: unreadCount,
        muted: muted,
      );

  String get kind_ => kind;
}

class Post {
  Post({
    required this.id,
    this.body = '',
    this.createdAt,
    this.author,
    this.media,
    this.likeCount = 0,
    this.commentCount = 0,
    this.likedByMe = false,
    this.visibility = 'friends',
  });

  final String id;
  final String body;
  final DateTime? createdAt;
  final FriendUser? author;
  final MediaItem? media;
  int likeCount;
  int commentCount;
  bool likedByMe;
  final String visibility;

  factory Post.fromJson(Map<String, dynamic> json) => Post(
        id: (json['id'] ?? '').toString(),
        body: (json['body'] ?? '').toString(),
        createdAt: _date(json['createdAt']),
        author: json['author'] is Map<String, dynamic>
            ? FriendUser.fromJson(json['author'] as Map<String, dynamic>)
            : null,
        media: json['media'] is Map<String, dynamic> ? MediaItem.fromJson(json['media'] as Map<String, dynamic>) : null,
        likeCount: _int(json['likeCount']),
        commentCount: _int(json['commentCount']),
        likedByMe: _bool(json['likedByMe']),
        visibility: (json['visibility'] ?? 'friends').toString(),
      );
}

class PostComment {
  PostComment({required this.id, required this.body, this.createdAt, this.author, this.isMine = false});

  final String id;
  final String body;
  final DateTime? createdAt;
  final FriendUser? author;
  final bool isMine;

  factory PostComment.fromJson(Map<String, dynamic> json) => PostComment(
        id: (json['id'] ?? '').toString(),
        body: (json['body'] ?? '').toString(),
        createdAt: _date(json['createdAt']),
        author: json['author'] is Map<String, dynamic>
            ? FriendUser.fromJson(json['author'] as Map<String, dynamic>)
            : null,
        isMine: _bool(json['isMine']),
      );
}

class Story {
  Story({
    required this.id,
    this.caption = '',
    this.media,
    this.createdAt,
    this.expiresAt,
    this.viewed = false,
    this.backgroundColor,
  });

  final String id;
  final String caption;
  final MediaItem? media;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  bool viewed;
  final String? backgroundColor;

  factory Story.fromJson(Map<String, dynamic> json) => Story(
        id: (json['id'] ?? '').toString(),
        caption: (json['caption'] ?? '').toString(),
        media: json['media'] is Map<String, dynamic> ? MediaItem.fromJson(json['media'] as Map<String, dynamic>) : null,
        createdAt: _date(json['createdAt']),
        expiresAt: _date(json['expiresAt']),
        viewed: _bool(json['viewed']),
        backgroundColor: json['backgroundColor']?.toString(),
      );
}

class StoryGroup {
  StoryGroup({required this.user, required this.stories, this.isMe = false});

  final FriendUser user;
  final List<Story> stories;
  final bool isMe;

  bool get allViewed => stories.every((s) => s.viewed);

  factory StoryGroup.fromJson(Map<String, dynamic> json) => StoryGroup(
        user: FriendUser.fromJson(_asMap(json['user'])),
        isMe: _bool(json['isMe']),
        stories: (json['stories'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(Story.fromJson)
            .toList(),
      );
}

class FriendRequest {
  FriendRequest({required this.id, this.user, this.message, this.createdAt, this.direction = 'incoming'});

  final String id;
  final FriendUser? user;
  final String? message;
  final DateTime? createdAt;
  final String direction;

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
        id: (json['id'] ?? '').toString(),
        user: json['user'] is Map<String, dynamic> ? FriendUser.fromJson(json['user'] as Map<String, dynamic>) : null,
        message: json['message']?.toString(),
        createdAt: _date(json['createdAt']),
        direction: (json['direction'] ?? 'incoming').toString(),
      );
}

class AppNotification {
  AppNotification({required this.id, required this.kind, this.data = const {}, this.read = false, this.createdAt, this.actor});

  final String id;
  final String kind;
  final Map<String, dynamic> data;
  final bool read;
  final DateTime? createdAt;
  final FriendUser? actor;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? '').toString(),
        data: _asMap(json['data']),
        read: _bool(json['read']),
        createdAt: _date(json['createdAt']),
        actor: json['actor'] is Map<String, dynamic> ? FriendUser.fromJson(json['actor'] as Map<String, dynamic>) : null,
      );
}

class BetaConfig {
  BetaConfig({this.betaMode = false, this.showBetaBadge = false, this.message = ''});

  final bool betaMode;
  final bool showBetaBadge;
  final String message;

  factory BetaConfig.fromJson(Map<String, dynamic> json) => BetaConfig(
        betaMode: _bool(json['betaMode']),
        showBetaBadge: _bool(json['showBetaBadge']),
        message: (json['message'] ?? '').toString(),
      );
}

class UsernameAvailability {
  UsernameAvailability({
    required this.username,
    required this.available,
    required this.reason,
    this.message = '',
    this.suggestions = const [],
  });

  final String username;
  final bool available;
  final String reason;
  final String message;
  final List<String> suggestions;

  factory UsernameAvailability.fromJson(Map<String, dynamic> json) => UsernameAvailability(
        username: (json['username'] ?? '').toString(),
        available: _bool(json['available']),
        reason: (json['reason'] ?? '').toString(),
        message: (json['message'] ?? '').toString(),
        suggestions: (json['suggestions'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      );
}

class CallRecord {
  CallRecord({
    required this.id,
    this.kind = 'audio',
    this.status = 'ended',
    this.direction = 'outgoing',
    this.peer,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String status;
  final String direction;
  final FriendUser? peer;
  final DateTime? createdAt;

  factory CallRecord.fromJson(Map<String, dynamic> json) => CallRecord(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? 'audio').toString(),
        status: (json['status'] ?? 'ended').toString(),
        direction: (json['direction'] ?? 'outgoing').toString(),
        peer: json['peer'] is Map<String, dynamic> ? FriendUser.fromJson(json['peer'] as Map<String, dynamic>) : null,
        createdAt: _date(json['createdAt']),
      );
}

double? readDouble(dynamic value) => _double(value);
