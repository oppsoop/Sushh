import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'friends_screen.dart';
import 'home_shell.dart';
import 'notifications_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conversations = app.chat.conversations;
    return Scaffold(
      appBar: WfTopBar(
        title: 'Chats',
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: Badge(
              isLabelVisible: app.unreadNotifications > 0,
              child: const Icon(Icons.notifications_none),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => app.chat.loadConversations(),
        child: conversations.isEmpty
            ? ListView(
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.2),
                  EmptyState(
                    icon: Icons.forum_outlined,
                    title: app.chat.loadingConversations ? 'Loading chats…' : 'No chats yet',
                    subtitle: 'Find a friend by username and start a conversation.',
                    action: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const FriendsScreen(selectMode: true)),
                      ),
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Find friends'),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 90),
                itemCount: conversations.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  return _ConversationTile(conversation: conversation, myUserId: app.user?.id);
                },
              ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, this.myUserId});

  final Conversation conversation;
  final String? myUserId;

  @override
  Widget build(BuildContext context) {
    final unread = conversation.unreadCount;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Stack(
        children: [
          Avatar(
            url: conversation.avatarUrl,
            name: conversation.title,
            size: 48,
            online: conversation.peer?.online ?? false,
          ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conversation.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            timeAgo(conversation.lastMessageAt),
            style: TextStyle(
              fontSize: 11,
              color: unread > 0 ? WfColors.accent : WfColors.textMuted,
              fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                conversation.previewText(myUserId),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: unread > 0 ? Colors.white70 : WfColors.textMuted,
                ),
              ),
            ),
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: WfColors.accent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black),
                ),
              ),
          ],
        ),
      ),
      onTap: () => openChat(context, conversation.id),
    );
  }
}
