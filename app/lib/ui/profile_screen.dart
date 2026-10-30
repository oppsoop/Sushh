import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'home_shell.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.username, this.userId});

  /// Username of the profile to show. When null, shows my own profile.
  final String? username;
  final String? userId;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  FriendUser? _user;
  List<Post> _posts = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isSelf => widget.username == null || _user?.isMe == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final username = widget.username ?? app.user?.username;
      if (username == null) {
        // Fall back to the locally cached profile.
        final me = app.user;
        if (me != null) {
          _user = FriendUser(
            id: me.id,
            username: me.username,
            displayName: me.displayName,
            bio: me.bio,
            avatarUrl: me.avatarUrl,
            isMe: true,
          );
        }
      } else {
        final data = await app.api.get('/users/$username');
        final user = data['user'];
        if (user is Map<String, dynamic>) {
          _user = FriendUser.fromJson(user);
        }
      }
      final target = _user?.username;
      if (target != null) {
        final posts = await app.api.get('/users/$target/posts', query: {'limit': '20'});
        _posts = (posts['posts'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(Post.fromJson)
            .toList();
      }
    } on ApiException catch (error) {
      _error = error.friendly;
    } catch (_) {
      _error = 'Could not load this profile.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFollow() async {
    final user = _user;
    if (user == null || _busy) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      if (user.following) {
        await app.api.delete('/users/${user.username}/follow');
        _user = _copyWith(following: false, followers: (user.followers - 1).clamp(0, 1 << 31));
      } else {
        await app.api.post('/users/${user.username}/follow');
        _user = _copyWith(following: true, followers: user.followers + 1);
      }
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  FriendUser _copyWith({bool? following, int? followers, bool? isFriend, bool? requestPending}) {
    final user = _user!;
    return FriendUser(
      id: user.id,
      username: user.username,
      displayName: user.displayName,
      bio: user.bio,
      avatarUrl: user.avatarUrl,
      online: user.online,
      lastSeenAt: user.lastSeenAt,
      isFriend: isFriend ?? user.isFriend,
      requestPending: requestPending ?? user.requestPending,
      following: following ?? user.following,
      followers: followers ?? user.followers,
      followingCount: user.followingCount,
      posts: user.posts,
      isMe: user.isMe,
    );
  }

  Future<void> _addFriend() async {
    final user = _user;
    if (user == null || _busy) return;
    setState(() => _busy = true);
    try {
      final data = await context.read<AppState>().api.post('/friends/requests', body: {'username': user.username});
      if (!mounted) return;
      if (data['status'] == 'accepted') {
        _user = _copyWith(isFriend: true, requestPending: false);
        showSnack(context, 'You are now friends with ${user.label}');
      } else {
        _user = _copyWith(requestPending: true);
        showSnack(context, 'Friend request sent');
      }
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _message() async {
    final user = _user;
    if (user == null) return;
    try {
      final conversationId = await context.read<AppState>().chat.openConversationWith(user);
      if (!mounted || conversationId == null) return;
      await openChat(context, conversationId);
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  Future<void> _menu() async {
    final user = _user;
    if (user == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: WfColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report profile'),
              onTap: () => Navigator.pop(context, 'report'),
            ),
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
    final app = context.read<AppState>();
    try {
      if (action == 'report') {
        await app.api.post('/reports', body: {'targetType': 'user', 'targetId': user.id, 'reason': 'other'});
        if (mounted) showSnack(context, 'Report sent. Thanks for flagging it.');
      } else {
        await app.api.post('/blocks/${user.id}');
        if (mounted) showSnack(context, '${user.label} is blocked');
      }
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final me = context.watch<AppState>().user;
    final label = user?.label ?? (widget.username == null ? (me?.label ?? 'You') : '@${widget.username}');
    final handle = user?.handle ?? (widget.username == null ? (me?.handle ?? '') : '@${widget.username}');

    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelf ? 'My profile' : 'Profile'),
        actions: [
          if (!_isSelf && user != null)
            IconButton(icon: const Icon(Icons.more_vert), onPressed: _menu),
          if (_isSelf) ...[
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: ErrorText(message: _error, onRetry: _load),
              ),
            const SizedBox(height: 8),
            Center(
              child: Avatar(
                url: user?.avatarUrl ?? (widget.username == null ? me?.avatarUrl : null),
                name: label,
                size: 92,
                online: user?.online ?? false,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                label,
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ),
            ),
            if (handle.isNotEmpty)
              Center(
                child: Text(handle, style: const TextStyle(fontSize: 13, color: WfColors.accent)),
              ),
            if ((user?.bio ?? (widget.username == null ? me?.bio : null) ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                child: Text(
                  user?.bio ?? me?.bio ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, color: Colors.white70, height: 1.35),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Stat(label: 'Posts', value: _loading && user == null ? null : '${user?.posts ?? _posts.length}'),
                _Stat(label: 'Followers', value: _loading && user == null ? null : '${user?.followers ?? 0}'),
                _Stat(label: 'Following', value: _loading && user == null ? null : '${user?.followingCount ?? 0}'),
              ],
            ),
            const SizedBox(height: 16),
            if (!_isSelf && user != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : (user.isFriend ? _message : _addFriend),
                        icon: Icon(user.isFriend ? Icons.chat_bubble_outline : Icons.person_add_alt, size: 18),
                        label: Text(
                          user.isFriend
                              ? 'Message'
                              : user.requestPending
                                  ? 'Request sent'
                                  : 'Add friend',
                        ),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _toggleFollow,
                        icon: Icon(user.following ? Icons.check : Icons.add, size: 18),
                        label: Text(user.following ? 'Following' : 'Follow'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      ),
                    ),
                  ],
                ),
              ),
            if (_isSelf)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit profile'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Posts'),
            if (_loading && _posts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_posts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('No posts yet', style: TextStyle(color: WfColors.textMuted, fontSize: 13)),
                ),
              )
            else
              ..._posts.map(
                (post) => Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: WfColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (post.body.isNotEmpty) Text(post.body, style: const TextStyle(fontSize: 14, height: 1.35)),
                      if (post.media?.isImage == true) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(post.media!.playableUrl, height: 180, fit: BoxFit.cover, width: double.infinity),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.favorite_border, size: 15, color: WfColors.textMuted),
                          const SizedBox(width: 4),
                          Text('${post.likeCount}', style: const TextStyle(fontSize: 12, color: WfColors.textMuted)),
                          const SizedBox(width: 12),
                          const Icon(Icons.chat_bubble_outline, size: 14, color: WfColors.textMuted),
                          const SizedBox(width: 4),
                          Text('${post.commentCount}', style: const TextStyle(fontSize: 12, color: WfColors.textMuted)),
                          const Spacer(),
                          Text(timeAgo(post.createdAt), style: const TextStyle(fontSize: 11, color: WfColors.textMuted)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          Text(
            value ?? '—',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          Text(label, style: const TextStyle(fontSize: 11, color: WfColors.textMuted)),
        ],
      ),
    );
  }
}
