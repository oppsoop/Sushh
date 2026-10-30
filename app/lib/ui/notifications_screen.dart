import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'friends_screen.dart';
import 'home_shell.dart';
import 'profile_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final List<AppNotification> _items = [];
  bool _loading = true;
  String? _error;

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
      final data = await app.api.get('/notifications', query: {'limit': '50'});
      final items = (data['notifications'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(AppNotification.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
      });
      app.unreadNotifications = 0;
      await app.api.post('/notifications/read');
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.friendly);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load notifications.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _label(AppNotification item) {
    final actor = item.actor?.label ?? 'Someone';
    switch (item.kind) {
      case 'friend_request':
        return '$actor sent you a friend request';
      case 'friend_accept':
        return '$actor accepted your friend request';
      case 'follow':
        return '$actor started following you';
      case 'like':
        return '$actor liked your post';
      case 'comment':
        return '$actor commented on your post';
      case 'message':
        return '$actor sent you a message';
      case 'call_missed':
        return 'Missed call from $actor';
      case 'story_view':
        return '$actor viewed your story';
      default:
        return item.kind.replaceAll('_', ' ');
    }
  }

  IconData _icon(AppNotification item) {
    switch (item.kind) {
      case 'friend_request':
      case 'friend_accept':
        return Icons.person_add_alt;
      case 'follow':
        return Icons.person_add_alt_1;
      case 'like':
        return Icons.favorite_border;
      case 'comment':
        return Icons.chat_bubble_outline;
      case 'message':
        return Icons.mail_outline;
      case 'call_missed':
        return Icons.phone_missed;
      default:
        return Icons.notifications_none;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.2),
                        EmptyState(
                          icon: Icons.notifications_none,
                          title: 'Nothing new',
                          subtitle: _error ?? 'Friend requests, likes and comments show up here.',
                        ),
                      ],
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 68),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final conversationId = item.data['conversationId']?.toString();
                        return ListTile(
                          leading: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Avatar(url: item.actor?.avatarUrl, name: item.actor?.label ?? '?', size: 42),
                              Positioned(
                                right: -4,
                                bottom: -4,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(color: WfColors.surface, shape: BoxShape.circle),
                                  child: Icon(_icon(item), size: 13, color: WfColors.accent),
                                ),
                              ),
                            ],
                          ),
                          title: Text(_label(item), style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: item.read ? FontWeight.w400 : FontWeight.w700,
                          )),
                          subtitle: Text(timeAgo(item.createdAt), style: const TextStyle(fontSize: 11)),
                          trailing: item.kind == 'friend_request'
                              ? FilledButton(
                                  style: FilledButton.styleFrom(minimumSize: const Size(78, 34)),
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const FriendsScreen(initialTab: 1),
                                    ),
                                  ),
                                  child: const Text('View'),
                                )
                              : null,
                          onTap: () {
                            if (conversationId != null) {
                              openChat(context, conversationId);
                            } else if (item.actor?.username != null) {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ProfileScreen(username: item.actor!.username),
                                ),
                              );
                            }
                          },
                        );
                      },
                    ),
            ),
    );
  }
}
