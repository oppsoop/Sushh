import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import '../state/chat_store.dart';
import 'call_screen.dart';
import 'media_viewer_screen.dart';
import 'profile_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.titleHint});

  final String conversationId;
  final String? titleHint;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  FriendUser? _peer;
  bool _sending = false;
  double? _uploadProgress;
  String? _uploadLabel;
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final app = context.read<AppState>();
    app.setActiveConversation(widget.conversationId);
    final store = app.chat;
    await store.ensureLoaded(widget.conversationId);
    await _resolvePeer();
    _markRead();
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  Future<void> _resolvePeer() async {
    final app = context.read<AppState>();
    var conversation = app.chat.conversationById(widget.conversationId);
    if (conversation?.peer != null) {
      setState(() => _peer = conversation!.peer);
      return;
    }
    try {
      final data = await app.api.get('/conversations/${widget.conversationId}');
      final members = (data['conversation']?['members'] as List<dynamic>? ?? []);
      if (members.isNotEmpty && members.first is Map<String, dynamic>) {
        setState(() => _peer = FriendUser.fromJson(members.first as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  void _markRead() {
    final app = context.read<AppState>();
    final messages = app.chat.messagesFor(widget.conversationId);
    app.chat.markRead(widget.conversationId, messages.isEmpty ? null : messages.last.id);
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200 && !_loadingOlder) {
      final app = context.read<AppState>();
      if (app.chat.hasMore(widget.conversationId) && !app.chat.isLoading(widget.conversationId)) {
        _loadingOlder = true;
        app.chat.loadMore(widget.conversationId).whenComplete(() => _loadingOlder = false);
      }
    }
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    _text.clear();
    final app = context.read<AppState>();
    try {
      await app.chat.sendText(widget.conversationId, text);
      app.chat.sendTyping(widget.conversationId, false);
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  /* ------------------------------ attachments ------------------------------ */

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: WfColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Video'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('Voice note'),
              onTap: () => Navigator.pop(context, 'voice'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'photo':
        await _pickImage();
        break;
      case 'video':
        await _pickVideo();
        break;
      case 'voice':
        await _recordVoice();
        break;
      case 'file':
        await _pickFile();
        break;
    }
  }

  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 2000);
      if (picked == null) return;
      await _uploadAndSend(File(picked.path), kind: 'image', label: 'Uploading photo…');
    } catch (error) {
      if (mounted) showSnack(context, 'Could not open the gallery', error: true);
    }
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 2));
      if (picked == null) return;
      await _uploadAndSend(File(picked.path), kind: 'video', label: 'Uploading video…');
    } catch (error) {
      if (mounted) showSnack(context, 'Could not open the gallery', error: true);
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      final path = result?.files.single.path;
      if (path == null) return;
      await _uploadAndSend(File(path), kind: 'file', label: 'Uploading file…');
    } catch (error) {
      if (mounted) showSnack(context, 'Could not open the file picker', error: true);
    }
  }

  String _mimeFor(String kind, String path) {
    final ext = p.extension(path).toLowerCase();
    switch (kind) {
      case 'image':
        return ext == '.png' ? 'image/png' : 'image/jpeg';
      case 'video':
        return ext == '.mov' ? 'video/quicktime' : 'video/mp4';
      case 'audio':
        return ext == '.m4a' ? 'audio/mp4' : 'audio/mp4';
      default:
        const map = {
          '.pdf': 'application/pdf',
          '.zip': 'application/zip',
          '.doc': 'application/msword',
          '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          '.txt': 'text/plain',
        };
        return map[ext] ?? 'application/octet-stream';
    }
  }

  Future<void> _uploadAndSend(File file, {required String kind, String label = 'Uploading…', int? durationMs}) async {
    final app = context.read<AppState>();
    setState(() {
      _uploadProgress = 0;
      _uploadLabel = label;
    });
    try {
      final uploaded = await app.api.uploadFile(
        file: file,
        mimeType: _mimeFor(kind, file.path),
        fields: {
          'kind': kind,
          if (durationMs != null) 'durationMs': '$durationMs',
        },
        onProgress: (progress) {
          if (mounted) setState(() => _uploadProgress = progress);
        },
      );
      final media = uploaded['media'];
      final mediaId = media is Map<String, dynamic> ? media['id']?.toString() : null;
      if (mediaId == null) throw ApiException(500, 'upload_failed', 'Upload failed');
      await app.chat.sendMedia(
        conversationId: widget.conversationId,
        kind: kind,
        mediaId: mediaId,
        localPath: file.path,
      );
      _scrollToBottom();
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    } catch (error) {
      if (mounted) showSnack(context, 'Upload failed: $error', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _uploadProgress = null;
          _uploadLabel = null;
        });
      }
    }
  }

  Future<void> _recordVoice() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) showSnack(context, 'Microphone permission is needed for voice notes', error: true);
      return;
    }
    if (!mounted) return;
    final recorded = await showModalBottomSheet<_Recording>(
      context: context,
      isDismissible: false,
      backgroundColor: WfColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const _VoiceRecorderSheet(),
    );
    if (recorded == null) return;
    await _uploadAndSend(
      File(recorded.path),
      kind: 'audio',
      label: 'Sending voice note…',
      durationMs: recorded.durationMs,
    );
  }

  /* ------------------------------ actions ------------------------------ */

  Future<void> _startCall(String kind) async {
    final app = context.read<AppState>();
    final peer = _peer;
    if (peer == null) {
      showSnack(context, 'This person is no longer available', error: true);
      return;
    }
    if (!app.isOnline) {
      showSnack(context, 'You need to be online to start a call', error: true);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callId: app.newCallId(),
          peer: peer,
          kind: kind,
          outgoing: true,
        ),
      ),
    );
  }

  Future<void> _showMenu() async {
    final app = context.read<AppState>();
    final peer = _peer;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: WfColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (peer != null)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('View profile'),
                onTap: () => Navigator.pop(context, 'profile'),
              ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report this chat'),
              onTap: () => Navigator.pop(context, 'report'),
            ),
            if (peer != null)
              ListTile(
                leading: const Icon(Icons.block, color: WfColors.danger),
                title: const Text('Block', style: TextStyle(color: WfColors.danger)),
                onTap: () => Navigator.pop(context, 'block'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'profile':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ProfileScreen(username: peer!.username)),
        );
        break;
      case 'report':
        await _report(peer);
        break;
      case 'block':
        await _block(peer);
        break;
    }
  }

  Future<void> _report(FriendUser? peer) async {
    final app = context.read<AppState>();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Report'),
        children: [
          for (final entry in const {
            'spam': 'Spam',
            'harassment': 'Harassment',
            'hate_speech': 'Hate speech',
            'nudity': 'Nudity',
            'violence': 'Violence',
            'impersonation': 'Impersonation',
            'scam': 'Scam',
            'other': 'Something else',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(entry.value),
            ),
        ],
      ),
    );
    if (reason == null || peer == null) return;
    try {
      await app.api.post('/reports', body: {
        'targetType': 'user',
        'targetId': peer.id,
        'reason': reason,
      });
      if (mounted) showSnack(context, 'Thanks - the report was sent.');
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  Future<void> _block(FriendUser? peer) async {
    if (peer == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Block ${peer.label}?'),
        content: const Text('They will not be able to message you or find your profile.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: WfColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await context.read<AppState>().api.post('/blocks/${peer.id}');
      if (!mounted) return;
      showSnack(context, '${peer.label} is blocked');
      Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('It will disappear for everyone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await context.read<AppState>().chat.deleteMessage(widget.conversationId, message.id);
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final store = app.chat;
    final messages = store.messagesFor(widget.conversationId);
    final typing = store.isTyping(widget.conversationId);
    final title = _peer?.label ?? widget.titleHint ?? 'Chat';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Avatar(url: _peer?.avatarUrl, name: title, size: 38, online: _peer?.online ?? false),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(
                    typing
                        ? 'typing…'
                        : (_peer?.online ?? false)
                            ? 'online'
                            : (_peer?.lastSeenAt != null ? 'last seen ${timeAgo(_peer!.lastSeenAt)}' : ''),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: typing ? WfColors.accent : WfColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Voice call',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _startCall('audio'),
          ),
          IconButton(
            tooltip: 'Video call',
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _startCall('video'),
          ),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _showMenu),
        ],
      ),
      body: Column(
        children: [
          if (!app.isOnline)
            Container(
              width: double.infinity,
              color: WfColors.warning.withOpacity(0.12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: const Row(
                children: [
                  Icon(Icons.cloud_off, size: 14, color: WfColors.warning),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You are offline. Messages are queued and will send automatically.',
                      style: TextStyle(fontSize: 11.5, color: WfColors.warning),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: messages.isEmpty && !store.isLoading(widget.conversationId)
                ? const EmptyState(
                    icon: Icons.waving_hand_outlined,
                    title: 'Say hello',
                    subtitle: 'Send the first message to start the conversation.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    itemCount: messages.length + (_loadingOlder ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= messages.length) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                        );
                      }
                      final message = messages[messages.length - 1 - index];
                      return _MessageBubble(
                        message: message,
                        myUserId: app.user?.id,
                        onRetry: () => store.retry(widget.conversationId, message.clientId),
                        onDelete: () => _deleteMessage(message),
                      );
                    },
                  ),
          ),
          if (_uploadProgress != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: WfColors.surface,
              child: Row(
                children: [
                  const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_uploadLabel ?? 'Uploading…', style: const TextStyle(fontSize: 12))),
                  Text('${((_uploadProgress ?? 0) * 100).clamp(0, 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          _Composer(
            controller: _text,
            onSend: _sendText,
            onAttach: _attach,
            onTyping: (typing) => store.sendTyping(widget.conversationId, typing),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttach,
    required this.onTyping,
  });

  final TextEditingController controller;
  final Future<void> Function() onSend;
  final Future<void> Function() onAttach;
  final void Function(bool typing) onTyping;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  Timer? _typingTimer;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _typingTimer?.cancel();
    super.dispose();
  }

  void _onChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    _typingTimer?.cancel();
    widget.onTyping(hasText);
    if (hasText) {
      _typingTimer = Timer(const Duration(seconds: 3), () => widget.onTyping(false));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: const BoxDecoration(
          color: WfColors.background,
          border: Border(top: BorderSide(color: Colors.white10)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              color: WfColors.textMuted,
              onPressed: widget.onAttach,
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onSubmitted: (_) => widget.onSend(),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _hasText ? () => widget.onSend() : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _hasText ? WfColors.primary : WfColors.surfaceLight,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.send_rounded, size: 20, color: _hasText ? Colors.white : WfColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.myUserId,
    required this.onRetry,
    required this.onDelete,
  });

  final ChatMessage message;
  final String? myUserId;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    final bubbleColor = mine ? WfColors.bubbleMine : WfColors.bubbleTheirs;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;

    return Align(
      alignment: align,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: EdgeInsets.all(message.media != null ? 4 : 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: GestureDetector(
          onLongPress: () {
            if (!mine) return;
            showModalBottomSheet<void>(
              context: context,
              backgroundColor: WfColors.surface,
              builder: (context) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.copy),
                      title: const Text('Copy text'),
                      onTap: () {
                        if (message.body != null) Clipboard.setData(ClipboardData(text: message.body!));
                        Navigator.pop(context);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline, color: WfColors.danger),
                      title: const Text('Delete message', style: TextStyle(color: WfColors.danger)),
                      onTap: () {
                        Navigator.pop(context);
                        onDelete();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.deleted)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text('This message was deleted', style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13)),
                )
              else ...[
                if (message.media != null) _MediaContent(media: message.media!, mine: mine),
                if (message.body != null && message.body!.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(message.media != null ? 8 : 0, message.media != null ? 8 : 0, 6, 2),
                    child: Text(message.body!, style: const TextStyle(fontSize: 15, height: 1.3)),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 4, top: 2, bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatClock(message.createdAt),
                      style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.6)),
                    ),
                    if (mine) ...[
                      const SizedBox(width: 4),
                      if (message.status == MessageStatus.failed)
                        GestureDetector(
                          onTap: onRetry,
                          child: const Row(
                            children: [
                              Icon(Icons.error_outline, size: 12, color: WfColors.danger),
                              Text(' Retry', style: TextStyle(fontSize: 10, color: WfColors.danger)),
                            ],
                          ),
                        )
                      else if (message.status == MessageStatus.sending)
                        const Icon(Icons.schedule, size: 12, color: Colors.white70)
                      else
                        Icon(
                          message.status == MessageStatus.read ? Icons.done_all : Icons.done,
                          size: 13,
                          color: message.status == MessageStatus.read ? WfColors.accent : Colors.white70,
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaContent extends StatelessWidget {
  const _MediaContent({required this.media, required this.mine});

  final MediaItem media;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    if (media.isImage) {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => MediaViewerScreen(media: media)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: 260,
              maxWidth: MediaQuery.of(context).size.width * 0.7,
              minWidth: 120,
            ),
            child: Image.network(
              media.playableUrl,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : Container(
                      height: 160,
                      alignment: Alignment.center,
                      color: WfColors.surfaceLight,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
              errorBuilder: (_, __, ___) => Container(
                height: 120,
                alignment: Alignment.center,
                color: WfColors.surfaceLight,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
      );
    }
    if (media.isVideo) {
      return _VideoThumb(media: media);
    }
    if (media.isAudio) {
      return _AudioBubble(media: media);
    }
    return _FileBubble(media: media);
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.media});

  final MediaItem media;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MediaViewerScreen(media: media)),
      ),
      child: Container(
        width: 200,
        height: 130,
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Icon(Icons.play_circle_fill, size: 46, color: Colors.white),
        ),
      ),
    );
  }
}

class _AudioBubble extends StatefulWidget {
  const _AudioBubble({required this.media});

  final MediaItem media;

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final _player = ja.AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state.playing);
      if (state.processingState == ja.ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
    _player.positionStream.listen((position) {
      if (mounted) setState(() => _position = position);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_player.audioSource == null) {
        await _player.setUrl(widget.media.playableUrl);
      }
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (_) {
      if (mounted) showSnack(context, 'Could not play this voice note', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.media.duration.inMilliseconds > 0
        ? widget.media.duration
        : const Duration(seconds: 1);
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return Container(
      width: 210,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
              child: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 20),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  color: Colors.white,
                ),
                const SizedBox(height: 6),
                Text(
                  widget.media.durationMs == null ? 'Voice note' : _fmt(widget.media.duration),
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _FileBubble extends StatefulWidget {
  const _FileBubble({required this.media});

  final MediaItem media;

  @override
  State<_FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<_FileBubble> {
  bool _downloading = false;
  double _progress = 0;

  Future<void> _download() async {
    final app = context.read<AppState>();
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeName = (widget.media.originalName ?? 'file-${widget.media.id}').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final target = File(p.join(dir.path, safeName));
      await app.api.downloadToFile(widget.media.playableUrl, target, onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      });
      await OpenFilex.open(target.path);
    } catch (error) {
      if (mounted) showSnack(context, 'Download failed', error: true);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _downloading ? null : _download,
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.insert_drive_file_outlined, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.media.originalName ?? 'File',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _downloading ? '${(_progress * 100).toStringAsFixed(0)}%' : widget.media.sizeLabel,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
            Icon(_downloading ? Icons.downloading : Icons.download, size: 18),
          ],
        ),
      ),
    );
  }
}

class _Recording {
  _Recording(this.path, this.durationMs);

  final String path;
  final int durationMs;
}

class _VoiceRecorderSheet extends StatefulWidget {
  const _VoiceRecorderSheet();

  @override
  State<_VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

class _VoiceRecorderSheetState extends State<_VoiceRecorderSheet> {
  final _recorder = AudioRecorder();
  Timer? _ticker;
  int _seconds = 0;
  bool _recording = false;
  String? _error;
  String? _path;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a');
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Microphone permission denied');
        return;
      }
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 96000, sampleRate: 44100), path: path);
      setState(() {
        _recording = true;
        _path = path;
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds += 1);
        if (_seconds >= 120) _finish();
      });
    } catch (error) {
      setState(() => _error = 'Could not start recording: $error');
    }
  }

  Future<void> _finish() async {
    _ticker?.cancel();
    try {
      final path = await _recorder.stop();
      if (!mounted) return;
      final finalPath = path ?? _path;
      if (finalPath == null) {
        Navigator.pop(context);
        return;
      }
      Navigator.pop(context, _Recording(finalPath, _seconds * 1000));
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    try {
      await _recorder.stop();
      final path = _path;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Voice note', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(
              '${(_seconds ~/ 60).toString().padLeft(2, '0')}:${(_seconds % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: WfColors.accent),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: WfColors.danger, fontSize: 12)),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(onPressed: _cancel, child: const Text('Cancel')),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: _recording ? _finish : null,
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                  style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap Send when you are done. Max 2 minutes.',
              style: TextStyle(fontSize: 11, color: WfColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
