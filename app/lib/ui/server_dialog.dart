import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Lets the owner point the installed beta APK at their own backend without
/// rebuilding it. The URL is verified against `/health` before it is saved.
Future<void> showServerDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ServerDialog(),
  );
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog();

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: AppConfig.baseUrl);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final health = await app.setServerUrl(_controller.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      final version = health['version']?.toString();
      showSnack(
        context,
        'Connected to the server${version == null ? '' : ' (v$version)'}. Please sign in again.',
      );
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not reach that server. Check the URL and your connection.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'The beta build talks to the backend URL below. Point it at your deployment if it changed.',
            style: TextStyle(fontSize: 12.5, color: WfColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: 'https://your-api.onrender.com'),
          ),
          const SizedBox(height: 10),
          ErrorText(message: _error),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  await context.read<AppState>().resetServerUrl();
                  if (context.mounted) Navigator.of(context).pop();
                },
          child: const Text('Use default'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Test & save'),
        ),
      ],
    );
  }
}
