import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../state/app_state.dart';
import 'profile_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final user = app.user;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SectionHeader(title: 'Account'),
          ListTile(
            leading: Avatar(url: user?.avatarUrl, name: user?.label ?? 'You', size: 46),
            title: Text(user?.label ?? 'You', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(user?.handle ?? 'No username yet'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EditProfileScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: const Text('Username'),
            subtitle: Text(
              user?.usernameChangeAvailableAt == null
                  ? '@${user?.username ?? ''}'
                  : '@${user?.username ?? ''} · can change ${timeAgo(user!.usernameChangeAvailableAt)}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChangeUsernameScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Email'),
            subtitle: Text(user?.email ?? '—'),
            trailing: app.tokens.user?.emailVerified == true
                ? const Icon(Icons.verified, size: 18, color: WfColors.accent)
                : TextButton(
                    onPressed: () async {
                      try {
                        await app.resendVerification(user?.email ?? '');
                        if (context.mounted) showSnack(context, 'Verification email sent');
                      } on ApiException catch (error) {
                        if (context.mounted) showSnack(context, error.friendly, error: true);
                      }
                    },
                    child: const Text('Verify'),
                  ),
          ),
          if (app.showBetaBadge)
            const ListTile(
              leading: Icon(Icons.science_outlined, color: WfColors.accent),
              title: Text('Beta tester'),
              subtitle: Text('You are using a private beta build. Things may change.'),
            ),
          const Divider(height: 24),
          const SectionHeader(title: 'Privacy & safety'),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked accounts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BlockedScreen()),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.visibility_off_outlined),
            title: Text('Who can message me'),
            subtitle: Text('Friends only'),
          ),
          const ListTile(
            leading: Icon(Icons.notifications_none),
            title: Text('Notifications'),
            subtitle: Text('Push notifications for new messages and friend requests'),
          ),
          const Divider(height: 24),
          const SectionHeader(title: 'Support'),
          ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('Send feedback'),
            subtitle: const Text('Tell us what to fix or build next'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FeedbackScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: Text('WorldFriends beta · ${AppConfig.apiBaseUrl}'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'WorldFriends',
              applicationVersion: '1.0.0 (beta)',
              applicationLegalese: 'Chats, calls and a small feed for real friends.',
            ),
          ),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () async {
              final confirmed = await _confirm(context, 'Log out?', 'You can sign back in any time.');
              if (confirmed == true) await app.logout();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: WfColors.danger),
            title: const Text('Delete account', style: TextStyle(color: WfColors.danger)),
            subtitle: const Text('This removes your profile, messages and media'),
            onTap: () async {
              final confirmed = await _confirm(
                context,
                'Delete your account?',
                'This cannot be undone. All your messages, posts and media will be removed.',
                destructive: true,
              );
              if (confirmed != true) return;
              if (!context.mounted) return;
              final password = await _askPassword(context);
              if (password == null) return;
              try {
                await app.deleteAccount(password);
              } on ApiException catch (error) {
                if (context.mounted) showSnack(context, error.friendly, error: true);
              }
            },
          ),
        ],
      ),
    );
  }

  Future<String?> _askPassword(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm your password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Password'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: WfColors.danger),
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm(BuildContext context, String title, String message, {bool destructive = false}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: destructive ? WfColors.danger : WfColors.primary),
            onPressed: () => Navigator.pop(context, true),
            child: Text(destructive ? 'Delete' : 'Confirm'),
          ),
        ],
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _bio;
  File? _avatar;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final user = context.read<AppState>().user;
    _name = TextEditingController(text: user?.displayName ?? '');
    _bio = TextEditingController(text: user?.bio ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 900);
    if (picked == null) return;
    setState(() => _avatar = File(picked.path));
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await app.updateProfile(
        displayName: _name.text.trim(),
        bio: _bio.text.trim(),
        avatar: _avatar,
      );
      if (mounted) {
        showSnack(context, 'Profile updated');
        Navigator.of(context).pop();
      }
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not save your profile.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AppState>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ErrorText(message: _error),
          Center(
            child: GestureDetector(
              onTap: _pick,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  _avatar == null
                      ? Avatar(url: user?.avatarUrl, name: user?.label ?? 'You', size: 96)
                      : ClipOval(
                          child: Image.file(_avatar!, width: 96, height: 96, fit: BoxFit.cover),
                        ),
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: WfColors.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt, size: 16),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Display name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            maxLength: 160,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Bio', alignLabelWithHint: true),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save changes'),
          ),
        ],
      ),
    );
  }
}

class ChangeUsernameScreen extends StatefulWidget {
  const ChangeUsernameScreen({super.key});

  @override
  State<ChangeUsernameScreen> createState() => _ChangeUsernameScreenState();
}

class _ChangeUsernameScreenState extends State<ChangeUsernameScreen> {
  late final TextEditingController _controller;
  bool _checking = false;
  bool _saving = false;
  String? _error;
  UsernameAvailability? _availability;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: context.read<AppState>().user?.username ?? '');
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _availability = null;
    });
    try {
      final result = await context.read<AppState>().checkUsername(_controller.text.trim());
      if (mounted) setState(() => _availability = result);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.friendly);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<AppState>().changeUsername(_controller.text.trim());
      if (mounted) {
        showSnack(context, 'Username updated');
        Navigator.of(context).pop();
      }
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = _availability?.available ?? false;
    final unchanged = _controller.text.trim() == (context.watch<AppState>().user?.username ?? '');
    return Scaffold(
      appBar: AppBar(title: const Text('Change username')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Usernames can be changed once every 30 days. Your old username becomes available to others.',
            style: TextStyle(fontSize: 12.5, color: WfColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autocorrect: false,
            decoration: InputDecoration(
              prefixText: '@',
              hintText: 'newusername',
              suffixIcon: _checking
                  ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : (available ? const Icon(Icons.check_circle, color: WfColors.accent) : null),
            ),
            onSubmitted: (_) => _check(),
          ),
          if (_availability != null) ...[
            const SizedBox(height: 8),
            Text(
              _availability!.available
                  ? '@${_availability!.username} is available'
                  : (_availability!.message.isNotEmpty
                      ? _availability!.message
                      : 'That username is not available'),
              style: TextStyle(
                fontSize: 12.5,
                color: _availability!.available ? WfColors.accent : WfColors.danger,
              ),
            ),
            if (!_availability!.available && _availability!.suggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: _availability!.suggestions
                      .take(4)
                      .map(
                        (suggestion) => ActionChip(
                          label: Text('@$suggestion'),
                          onPressed: () => setState(() {
                            _controller.text = suggestion;
                            _availability = null;
                          }),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
          ErrorText(message: _error),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _checking ? null : _check,
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  child: const Text('Check availability'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: (available && !unchanged && !_saving) ? _save : null,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  child: _saving
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  List<Map<String, dynamic>> _blocked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppState>().api.get('/blocks');
      final blocked = (data['blocked'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      if (mounted) setState(() => _blocked = blocked);
    } catch (_) {} finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unblock(Map<String, dynamic> user) async {
    final id = user['id']?.toString();
    if (id == null) return;
    try {
      await context.read<AppState>().api.delete('/blocks/$id');
      setState(() => _blocked.removeWhere((entry) => entry['id'] == id));
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked accounts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _blocked.isEmpty
              ? const EmptyState(
                  icon: Icons.block,
                  title: 'No blocked accounts',
                  subtitle: 'People you block cannot message you or find your profile.',
                )
              : ListView.separated(
                  itemCount: _blocked.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final user = _blocked[index];
                    final name = (user['displayName'] ?? user['username'] ?? 'Account').toString();
                    return ListTile(
                      leading: Avatar(url: user['avatarUrl']?.toString(), name: name, size: 44),
                      title: Text(name),
                      subtitle: Text('@${user['username'] ?? ''}'),
                      trailing: TextButton(onPressed: () => _unblock(user), child: const Text('Unblock')),
                    );
                  },
                ),
    );
  }
}

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _text = TextEditingController();
  String _kind = 'general';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_text.text.trim().length < 4) {
      setState(() => _error = 'Add a little more detail so we can act on it');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await context.read<AppState>().sendFeedback(
        message: '[$_kind] ${_text.text.trim()}',
        deviceInfo: const {'source': 'android_app'},
      );
      if (!mounted) return;
      showSnack(context, 'Thanks! Feedback sent.');
      Navigator.of(context).pop();
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not send feedback. Try again later.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send feedback')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ErrorText(message: _error),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in const {
                'general': 'General',
                'bug': 'Bug',
                'idea': 'Idea',
                'safety': 'Safety',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _kind == entry.key,
                  onSelected: (_) => setState(() => _kind = entry.key),
                  selectedColor: WfColors.primary.withOpacity(0.28),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            maxLines: 6,
            maxLength: 1000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'What happened, or what would make WorldFriends better?',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _sending ? null : _send,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _sending
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Send'),
          ),
          const SizedBox(height: 12),
          const Text(
            'We read everything. Include your username if you want a reply.',
            style: TextStyle(fontSize: 11.5, color: WfColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Small helper used by the "Me" tab to open a profile quickly.
Future<void> showProfile(BuildContext context, String? username) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ProfileScreen(username: username)),
  );
}
