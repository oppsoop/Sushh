import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'home_shell.dart';
import 'profile_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, this.selectMode = false, this.initialTab = 0});

  /// When true, tapping a friend opens (or starts) a chat instead of a profile.
  final bool selectMode;

  /// 0 = friends, 1 = requests, 2 = search.
  final int initialTab;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.selectMode ? 2 : widget.initialTab.clamp(0, 2),
  );
  final _searchController = TextEditingController();
  Timer? _debounce;

  final List<FriendUser> _friends = [];
  final List<FriendRequest> _incoming = [];
  final List<FriendUser> _results = [];

  bool _loadingFriends = false;
  bool _loadingRequests = false;
  bool _searching = false;
  String? _searchError;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadFriends();
      _loadRequests();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    if (!mounted) return;
    setState(() => _loadingFriends = true);
    try {
      final data = await context.read<AppState>().api.get('/friends');
      final friends = (data['friends'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(FriendUser.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _friends
          ..clear()
          ..addAll(friends);
        _error = null;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.friendly);
    } finally {
      if (mounted) setState(() => _loadingFriends = false);
    }
  }

  Future<void> _loadRequests() async {
    if (!mounted) return;
    setState(() => _loadingRequests = true);
    try {
      final data = await context.read<AppState>().api.get('/friends/requests', query: {'direction': 'incoming'});
      final requests = (data['requests'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(FriendRequest.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _incoming
          ..clear()
          ..addAll(requests);
      });
      context.read<AppState>().pendingRequests = requests.length;
    } catch (_) {} finally {
      if (mounted) setState(() => _loadingRequests = false);
    }
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results.clear();
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(trimmed));
  }

  Future<void> _search(String query) async {
    if (!mounted) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final data = await context.read<AppState>().api.get('/users/search', query: {'q': query, 'limit': '30'});
      final results = (data['results'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(FriendUser.fromJson)
          .toList();
      if (!mounted || _searchController.text.trim() != query) return;
      setState(() {
        _results
          ..clear()
          ..addAll(results);
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _searchError = error.friendly);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _sendRequest(FriendUser user) async {
    try {
      final data = await context.read<AppState>().api.post('/friends/requests', body: {'username': user.username});
      if (!mounted) return;
      if (data['status'] == 'accepted' || data['status'] == 'already_friends') {
        showSnack(context, 'You are now friends with ${user.label}');
        await _loadFriends();
      } else {
        showSnack(context, 'Friend request sent to ${user.label}');
      }
      await _search(user.username ?? '');
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  Future<void> _respond(FriendRequest request, bool accept) async {
    try {
      await context.read<AppState>().api.post(
            '/friends/requests/${request.id}/${accept ? 'accept' : 'decline'}',
          );
      await _loadRequests();
      if (accept) await _loadFriends();
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  Future<void> _openChatWith(FriendUser user) async {
    final app = context.read<AppState>();
    try {
      final conversationId = await app.chat.openConversationWith(user);
      if (!mounted || conversationId == null) return;
      if (widget.selectMode) {
        Navigator.of(context).pop();
      }
      await openChat(context, conversationId);
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.selectMode
          ? AppBar(title: const Text('New chat'))
          : WfTopBar(title: 'Friends'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search @username or name',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
            ),
          ),
          TabBar(
            controller: _tabs,
            labelColor: Colors.white,
            unselectedLabelColor: WfColors.textMuted,
            indicatorColor: WfColors.primary,
            tabs: [
              Tab(text: 'Friends (${_friends.length})'),
              Tab(text: 'Requests${_incoming.isEmpty ? '' : ' (${_incoming.length})'}'),
              const Tab(text: 'Search'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _friendsTab(),
                _requestsTab(),
                _searchTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _friendsTab() {
    if (_loadingFriends && _friends.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_friends.isEmpty) {
      return EmptyState(
        icon: Icons.people_outline,
        title: 'No friends yet',
        subtitle: 'Search for someone by their @username.',
        action: FilledButton(
          onPressed: () => _tabs.animateTo(2),
          child: const Text('Find people'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFriends,
      child: ListView.separated(
        itemCount: _friends.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final friend = _friends[index];
          return UserTile(
            user: friend,
            onTap: () {
              if (widget.selectMode) {
                _openChatWith(friend);
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ProfileScreen(username: friend.username)),
                );
              }
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Message',
                  icon: const Icon(Icons.chat_bubble_outline, size: 20),
                  onPressed: () => _openChatWith(friend),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _requestsTab() {
    if (_loadingRequests && _incoming.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_incoming.isEmpty) {
      return const EmptyState(
        icon: Icons.mark_email_read_outlined,
        title: 'No pending requests',
        subtitle: 'When someone adds you, it shows up here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRequests,
      child: ListView.separated(
        itemCount: _incoming.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final request = _incoming[index];
          final user = request.user;
          if (user == null) return const SizedBox.shrink();
          return ListTile(
            leading: Avatar(url: user.avatarUrl, name: user.label, size: 44),
            title: Text(user.label, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(request.message ?? user.handle),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: WfColors.textMuted),
                  onPressed: () => _respond(request, false),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(84, 36), backgroundColor: WfColors.primary),
                  onPressed: () => _respond(request, true),
                  child: const Text('Accept'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _searchTab() {
    if (_searchController.text.trim().isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        title: 'Find your people',
        subtitle: 'Type a full @username for an exact match, or part of a name.',
      );
    }
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.person_search,
        title: 'No one found',
        subtitle: _searchError ?? 'Try the exact @username.',
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final user = _results[index];
        return UserTile(
          user: user,
          subtitle: user.isFriend ? 'Friend · ${user.handle}' : user.handle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ProfileScreen(username: user.username)),
          ),
          trailing: user.isFriend
              ? IconButton(
                  icon: const Icon(Icons.chat_bubble_outline, size: 20),
                  onPressed: () => _openChatWith(user),
                )
              : FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(96, 36),
                    backgroundColor: user.requestPending ? WfColors.surfaceLight : WfColors.primary,
                  ),
                  onPressed: user.requestPending ? null : () => _sendRequest(user),
                  child: Text(user.requestPending ? 'Requested' : 'Add'),
                ),
        );
      },
    );
  }
}
