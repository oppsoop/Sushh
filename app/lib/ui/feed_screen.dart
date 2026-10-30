import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'home_shell.dart';
import 'profile_screen.dart';
import 'stories_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final List<Post> _posts = [];
  final List<StoryGroup> _stories = [];
  final _scroll = ScrollController();
  String? _cursor;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scroll.hasClients &&
        _scroll.position.pixels > _scroll.position.maxScrollExtent - 300 &&
        !_loadingMore &&
        _cursor != null) {
      _loadMore();
    }
  }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final app = context.read<AppState>();
    try {
      final feed = await app.api.get('/feed', query: {'limit': '15'});
      final posts = (feed['posts'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Post.fromJson)
          .toList();
      final storyData = await app.api.get('/stories');
      final groups = (storyData['groups'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(StoryGroup.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(posts);
        _stories
          ..clear()
          ..addAll(groups);
        _cursor = feed['nextCursor'] as String?;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.friendly);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your feed.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final cursor = _cursor;
    if (cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final feed = await context.read<AppState>().api.get('/feed', query: {'limit': '15', 'cursor': cursor});
      final posts = (feed['posts'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Post.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        final known = _posts.map((p) => p.id).toSet();
        _posts.addAll(posts.where((p) => !known.contains(p.id)));
        _cursor = feed['nextCursor'] as String?;
      });
    } catch (_) {} finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _toggleLike(Post post) async {
    final app = context.read<AppState>();
    final wasLiked = post.likedByMe;
    setState(() {
      post.likedByMe = !wasLiked;
      post.likeCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await app.api.delete('/posts/${post.id}/like');
      } else {
        await app.api.post('/posts/${post.id}/like');
      }
    } on ApiException {
      if (!mounted) return;
      setState(() {
        post.likedByMe = wasLiked;
        post.likeCount += wasLiked ? 1 : -1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: WfTopBar(title: 'Feed'),
      floatingActionButton: FloatingActionButton(
        backgroundColor: WfColors.primary,
        onPressed: () async {
          final created = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const PostComposerScreen()),
          );
          if (created == true) refresh();
        },
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            if (_error != null) Padding(padding: const EdgeInsets.all(16), child: ErrorText(message: _error)),
            _StoriesBar(groups: _stories, onChanged: refresh),
            if (_loading && _posts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_posts.isEmpty)
              EmptyState(
                icon: Icons.dynamic_feed_outlined,
                title: 'Your feed is quiet',
                subtitle: 'Add friends or share your first post.',
                action: FilledButton(
                  onPressed: () async {
                    final created = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(builder: (_) => const PostComposerScreen()),
                    );
                    if (created == true) refresh();
                  },
                  child: const Text('Create a post'),
                ),
              )
            else
              ..._posts.map(
                (post) => _PostCard(
                  post: post,
                  myUserId: app.user?.id,
                  onLike: () => _toggleLike(post),
                  onComment: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CommentsScreen(post: post)),
                    );
                    if (mounted) setState(() {});
                  },
                  onDeleted: () {
                    setState(() => _posts.removeWhere((p) => p.id == post.id));
                  },
                ),
              ),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
          ],
        ),
      ),
    );
  }
}

class _StoriesBar extends StatelessWidget {
  const _StoriesBar({required this.groups, required this.onChanged});

  final List<StoryGroup> groups;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final mine = groups.where((g) => g.isMe).toList();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: SizedBox(
        height: 92,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            _StoryAvatar(
              label: 'Your story',
              name: app.user?.label ?? 'You',
              avatarUrl: app.user?.avatarUrl,
              hasStories: mine.isNotEmpty,
              addButton: true,
              onTap: () async {
                if (mine.isNotEmpty) {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => StoryViewerScreen(groups: groups, initialGroupIndex: groups.indexOf(mine.first))),
                  );
                  await onChanged();
                } else {
                  final created = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const StoryComposerScreen()),
                  );
                  if (created == true) await onChanged();
                }
              },
              onAdd: () async {
                final created = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const StoryComposerScreen()),
                );
                if (created == true) await onChanged();
              },
            ),
            ...groups.asMap().entries.map(
                  (entry) => _StoryAvatar(
                    label: entry.value.user.label,
                    name: entry.value.user.label,
                    avatarUrl: entry.value.user.avatarUrl,
                    hasStories: true,
                    viewed: entry.value.allViewed,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => StoryViewerScreen(groups: groups, initialGroupIndex: entry.key),
                        ),
                      );
                      await onChanged();
                    },
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _StoryAvatar extends StatelessWidget {
  const _StoryAvatar({
    required this.label,
    required this.name,
    this.avatarUrl,
    this.hasStories = false,
    this.viewed = false,
    this.addButton = false,
    this.onTap,
    this.onAdd,
  });

  final String label;
  final String name;
  final String? avatarUrl;
  final bool hasStories;
  final bool viewed;
  final bool addButton;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onAdd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: hasStories
                        ? LinearGradient(
                            colors: viewed
                                ? [Colors.white24, Colors.white24]
                                : [WfColors.primary, WfColors.accent],
                          )
                        : null,
                    color: hasStories ? null : Colors.transparent,
                  ),
                  child: Avatar(url: avatarUrl, name: name, size: 58),
                ),
                if (addButton)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: WfColors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: WfColors.background, width: 2),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: const Icon(Icons.add, size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 70,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: WfColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.myUserId,
    required this.onLike,
    required this.onComment,
    required this.onDeleted,
  });

  final Post post;
  final String? myUserId;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onDeleted;

  String _timeLabel() {
    final created = post.createdAt;
    if (created == null) return '';
    final diff = DateTime.now().difference(created);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _menu(BuildContext context) async {
    final app = context.read<AppState>();
    final isMine = post.author?.id == myUserId;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: WfColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: WfColors.danger),
                title: const Text('Delete post', style: TextStyle(color: WfColors.danger)),
                onTap: () => Navigator.pop(context, 'delete'),
              )
            else
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report post'),
                onTap: () => Navigator.pop(context, 'report'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'delete') {
      try {
        await app.api.delete('/posts/${post.id}');
        onDeleted();
      } on ApiException catch (error) {
        if (context.mounted) showSnack(context, error.friendly, error: true);
      }
    } else if (action == 'report') {
      try {
        await app.api.post('/reports', body: {
          'targetType': 'post',
          'targetId': post.id,
          'reason': 'spam',
        });
        if (context.mounted) showSnack(context, 'Report sent. Thanks!');
      } on ApiException catch (error) {
        if (context.mounted) showSnack(context, error.friendly, error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final author = post.author;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WfColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: author?.username == null
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ProfileScreen(username: author!.username)),
                        ),
                child: Avatar(url: author?.avatarUrl, name: author?.label ?? '?', size: 40),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(author?.label ?? 'Someone', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      '${author?.handle ?? ''} · ${_timeLabel()}',
                      style: const TextStyle(fontSize: 11, color: WfColors.textMuted),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_horiz, size: 20),
                onPressed: () => _menu(context),
              ),
            ],
          ),
          if (post.body.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(post.body, style: const TextStyle(fontSize: 14.5, height: 1.35)),
          ],
          if (post.media != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: post.media!.isImage
                  ? Image.network(
                      post.media!.playableUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 160,
                        color: WfColors.surfaceLight,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    )
                  : Container(
                      height: 160,
                      color: Colors.black45,
                      child: const Center(child: Icon(Icons.play_circle_fill, size: 42)),
                    ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              InkWell(
                onTap: onLike,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        post.likedByMe ? Icons.favorite : Icons.favorite_border,
                        size: 18,
                        color: post.likedByMe ? WfColors.danger : WfColors.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Text('${post.likeCount}', style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: onComment,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.chat_bubble_outline, size: 17, color: WfColors.textMuted),
                      const SizedBox(width: 6),
                      Text('${post.commentCount}', style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PostComposerScreen extends StatefulWidget {
  const PostComposerScreen({super.key});

  @override
  State<PostComposerScreen> createState() => _PostComposerScreenState();
}

class _PostComposerScreenState extends State<PostComposerScreen> {
  final _text = TextEditingController();
  File? _image;
  String _visibility = 'friends';
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 2000);
    if (picked == null) return;
    setState(() => _image = File(picked.path));
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    if (_text.text.trim().isEmpty && _image == null) {
      setState(() => _error = 'Write something or add a photo');
      return;
    }
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      String? mediaId;
      if (_image != null) {
        final uploaded = await app.api.uploadFile(
          file: _image!,
          mimeType: 'image/jpeg',
          fields: {'kind': 'image'},
        );
        mediaId = (uploaded['media'] as Map<String, dynamic>?)?['id']?.toString();
      }
      await app.api.post('/posts', body: {
        'body': _text.text.trim(),
        'visibility': _visibility,
        if (mediaId != null) 'mediaId': mediaId,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not publish your post.');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New post'),
        actions: [
          TextButton(
            onPressed: _posting ? null : _submit,
            child: _posting ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Share'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ErrorText(message: _error),
              TextField(
                controller: _text,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'What is happening?'),
              ),
              const SizedBox(height: 12),
              if (_image != null)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.file(_image!, height: 200, fit: BoxFit.cover, width: double.infinity),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton(
                        onPressed: () => setState(() => _image = null),
                        icon: const Icon(Icons.close, color: Colors.white),
                        style: IconButton.styleFrom(backgroundColor: Colors.black54),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Photo'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(120, 44)),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _visibility,
                    dropdownColor: WfColors.surface,
                    items: const [
                      DropdownMenuItem(value: 'friends', child: Text('Friends')),
                      DropdownMenuItem(value: 'public', child: Text('Anyone following me')),
                      DropdownMenuItem(value: 'private', child: Text('Only me')),
                    ],
                    onChanged: (value) => setState(() => _visibility = value ?? 'friends'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CommentsScreen extends StatefulWidget {
  const CommentsScreen({super.key, required this.post});

  final Post post;

  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  final _text = TextEditingController();
  final List<PostComment> _comments = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppState>().api.get('/posts/${widget.post.id}/comments');
      final comments = (data['comments'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(PostComment.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(comments);
      });
    } catch (_) {} finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final data = await context.read<AppState>().api.post(
        '/posts/${widget.post.id}/comments',
        body: {'body': text},
      );
      final comment = data['comment'];
      if (comment is Map<String, dynamic>) {
        setState(() => _comments.add(PostComment.fromJson(comment)));
      }
      _text.clear();
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Comments')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _comments.isEmpty
                    ? const EmptyState(icon: Icons.chat_bubble_outline, title: 'No comments yet', subtitle: 'Be the first to reply.')
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _comments.length,
                        itemBuilder: (context, index) {
                          final comment = _comments[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Avatar(url: comment.author?.avatarUrl, name: comment.author?.label ?? '?', size: 34),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(comment.author?.label ?? 'Someone', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                          const SizedBox(width: 6),
                                          Text(timeAgo(comment.createdAt), style: const TextStyle(fontSize: 11, color: WfColors.textMuted)),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(comment.body, style: const TextStyle(fontSize: 14)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      decoration: const InputDecoration(hintText: 'Add a comment…'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
