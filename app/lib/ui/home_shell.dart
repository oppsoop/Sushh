import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../core/call_service.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
import 'chats_screen.dart';
import 'feed_screen.dart';
import 'friends_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  StreamSubscription<Map<String, dynamic>>? _bannerSub;
  String? _lastBannerKey;
  DateTime? _lastBannerAt;
  bool _incomingOpen = false;
  CallService? _calls;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _bannerSub = app.banners.stream.listen(_showBanner);
    _calls = app.calls..addListener(_onCallState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final deepLink = app.openedConversationId;
      if (deepLink != null) {
        app.openedConversationId = null;
        openChat(context, deepLink);
      }
    });
  }

  @override
  void dispose() {
    _bannerSub?.cancel();
    _calls?.removeListener(_onCallState);
    super.dispose();
  }

  void _onCallState() {
    final calls = _calls;
    if (calls == null || !mounted) return;
    if (calls.state == CallState.ringing) {
      if (_incomingOpen) return;
      final peer = calls.peer;
      if (peer == null) return;
      _incomingOpen = true;
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => CallScreen(
                callId: calls.callId ?? '',
                peer: peer,
                kind: calls.kind,
                outgoing: false,
              ),
            ),
          )
          .whenComplete(() => _incomingOpen = false);
    } else {
      setState(() {});
    }
  }

  void _showBanner(Map<String, dynamic> banner) {
    if (!mounted) return;
    final title = banner['title']?.toString() ?? 'WorldFriends';
    final body = banner['body']?.toString() ?? '';
    final key = '$title|$body';
    // Collapse duplicate pushes for the same message.
    if (_lastBannerKey == key && _lastBannerAt != null && DateTime.now().difference(_lastBannerAt!).inSeconds < 8) {
      return;
    }
    _lastBannerKey = key;
    _lastBannerAt = DateTime.now();

    final data = banner['data'];
    final conversationId = data is Map ? data['conversationId']?.toString() : null;
    if (context.read<AppState>().activeConversationId == conversationId && conversationId != null) {
      return; // already looking at this chat
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.showSnackBar(
      SnackBar(
        backgroundColor: WfColors.surfaceLight,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 78),
        duration: const Duration(seconds: 4),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (body.isNotEmpty)
              Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
        action: conversationId == null
            ? null
            : SnackBarAction(
                label: 'Open',
                onPressed: () {
                  if (mounted) openChat(context, conversationId);
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final unread = app.chat.totalUnread;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          ChatsScreen(),
          FeedScreen(),
          FriendsScreen(),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        backgroundColor: WfColors.surface,
        indicatorColor: WfColors.primary.withValues(alpha: 0.22),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            selectedIcon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.chat_bubble),
            ),
            label: 'Chats',
          ),
          const NavigationDestination(icon: Icon(Icons.dynamic_feed_outlined), selectedIcon: Icon(Icons.dynamic_feed), label: 'Feed'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: app.pendingRequests > 0,
              label: Text('${app.pendingRequests}'),
              child: const Icon(Icons.people_outline),
            ),
            selectedIcon: const Icon(Icons.people),
            label: 'Friends',
          ),
          const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Me'),
        ],
      ),
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FriendsScreen(selectMode: true)),
              ),
              backgroundColor: WfColors.primary,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
    );
  }
}

/// Opens (or pushes) a chat screen for [conversationId].
Future<void> openChat(BuildContext context, String conversationId, {bool push = true}) async {
  final app = context.read<AppState>();
  final conversation = app.chat.conversationById(conversationId);
  app.setActiveConversation(conversationId);
  if (push) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversationId: conversationId, titleHint: conversation?.title),
      ),
    );
    app.setActiveConversation(null);
  }
}

/// Small top-bar shown inside tabs.
class WfTopBar extends StatelessWidget implements PreferredSizeWidget {
  const WfTopBar({
    super.key,
    required this.title,
    this.actions,
    this.showBeta = true,
    this.subtitle,
  });

  final String title;
  final List<Widget>? actions;
  final bool showBeta;
  final Widget? subtitle;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          Text(title),
          if (showBeta && app.showBetaBadge) ...[
            const SizedBox(width: 8),
            const BetaBadge(compact: true),
          ],
        ],
      ),
      actions: [
        ConnectionPill(label: app.connectionLabel, online: app.isOnline),
        const SizedBox(width: 4),
        ...?actions,
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        const SizedBox(width: 4),
      ],
      bottom: subtitle == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(0),
              child: subtitle!,
            ),
    );
  }
}
