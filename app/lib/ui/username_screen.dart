import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Username claim screen with live availability checking, inline rule feedback
/// and suggestions when the name is taken.
class UsernameScreen extends StatefulWidget {
  const UsernameScreen({super.key, this.ideas = const []});

  final List<String> ideas;

  @override
  State<UsernameScreen> createState() => _UsernameScreenState();
}

class _UsernameScreenState extends State<UsernameScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  UsernameAvailability? _result;
  bool _checking = false;
  bool _submitting = false;
  String? _error;

  static final _pattern = RegExp(r'^[a-z][a-z0-9._]*$');

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String? _localValidation(String value) {
    if (value.isEmpty) return null;
    if (value.length < 3) return 'At least 3 characters';
    if (value.length > 20) return 'At most 20 characters';
    if (!RegExp(r'^[a-z]').hasMatch(value)) return 'Must start with a letter';
    if (!_pattern.hasMatch(value)) return 'Only a-z, 0-9, underscore and period';
    if (value.contains('..')) return 'No two periods in a row';
    if (value.endsWith('.')) return 'Cannot end with a period';
    return null;
  }

  void _onChanged(String raw) {
    final value = raw.toLowerCase();
    if (value != raw) {
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    setState(() => _result = null);
    _debounce?.cancel();
    final localError = _localValidation(value);
    if (localError != null) {
      setState(() => _checking = false);
      return;
    }
    if (value.length < 3) return;
    setState(() => _checking = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final result = await context.read<AppState>().checkUsername(value);
        if (!mounted || _controller.text != value) return;
        setState(() {
          _result = result;
          _checking = false;
        });
      } catch (_) {
        if (mounted) setState(() => _checking = false);
      }
    });
  }

  Future<void> _claim([String? suggestion]) async {
    final username = (suggestion ?? _controller.text).trim();
    if (username.isEmpty) return;
    if (suggestion != null) {
      _controller.text = suggestion;
      _onChanged(suggestion);
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AppState>().claimUsername(username);
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
      if (error.suggestions.isNotEmpty && mounted) {
        setState(() {
          _result = UsernameAvailability(
            username: username,
            available: false,
            reason: error.code,
            message: error.friendly,
            suggestions: error.suggestions,
          );
        });
      }
    } catch (_) {
      setState(() => _error = 'Could not reserve that username. Try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final value = _controller.text;
    final localError = _localValidation(value);
    final canSubmit = value.length >= 3 && localError == null && (_result?.available ?? false) && !_submitting;
    final ideas = widget.ideas.isNotEmpty
        ? widget.ideas
        : const ['jane.doe', 'janedoe1', 'jane_doe', 'jane2026'];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick your username'),
        actions: [
          TextButton(
            onPressed: () async {
              await context.read<AppState>().logout();
            },
            child: const Text('Sign out', style: TextStyle(color: WfColors.textMuted)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'This is how friends find you.',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Your profile will be worldfriends.app/@username',
                style: TextStyle(color: WfColors.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ErrorText(message: _error),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => canSubmit ? _claim() : null,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9._]'))],
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  prefixText: '@',
                  prefixStyle: const TextStyle(fontSize: 20, color: WfColors.textMuted),
                  hintText: 'yourname',
                  suffixIcon: _checking
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : _result == null
                          ? null
                          : Icon(
                              _result!.available ? Icons.check_circle : Icons.cancel,
                              color: _result!.available ? WfColors.accent : WfColors.danger,
                            ),
                ),
              ),
              const SizedBox(height: 10),
              _StatusLine(
                checking: _checking,
                localError: localError,
                value: value,
                result: _result,
              ),
              if (_result != null && _result!.suggestions.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text('Try one of these instead:', style: TextStyle(color: WfColors.textMuted, fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _result!.suggestions
                      .map(
                        (suggestion) => ActionChip(
                          label: Text('@$suggestion'),
                          onPressed: _submitting ? null : () => _claim(suggestion),
                        ),
                      )
                      .toList(),
                ),
              ],
              if (_result == null && localError == null && value.isEmpty) ...[
                const SizedBox(height: 14),
                const Text('Ideas:', style: TextStyle(color: WfColors.textMuted, fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ideas
                      .map((idea) => ActionChip(
                            label: Text('@$idea'),
                            onPressed: () {
                              _controller.text = idea;
                              _onChanged(idea);
                            },
                          ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 24),
              LoadingButton(
                label: 'Claim @${value.isEmpty ? 'username' : value}',
                loading: _submitting || app.busy,
                onPressed: canSubmit ? _claim : null,
              ),
              const SizedBox(height: 20),
              const _RulesCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.checking,
    required this.localError,
    required this.value,
    required this.result,
  });

  final bool checking;
  final String? localError;
  final String value;
  final UsernameAvailability? result;

  @override
  Widget build(BuildContext context) {
    String text;
    Color color;
    if (localError != null) {
      text = localError!;
      color = WfColors.danger;
    } else if (value.isEmpty) {
      text = 'Lowercase letters, numbers, dots and underscores.';
      color = WfColors.textMuted;
    } else if (checking) {
      text = 'Checking availability…';
      color = WfColors.textMuted;
    } else if (result == null) {
      text = 'Keep typing…';
      color = WfColors.textMuted;
    } else if (result!.available) {
      text = result!.reason == 'already_yours' ? 'This is already yours' : '@${result!.username} is available';
      color = WfColors.accent;
    } else {
      text = result!.message.isNotEmpty ? result!.message : 'Not available';
      color = WfColors.danger;
    }
    return Row(
      children: [
        Icon(
          color == WfColors.accent
              ? Icons.check_circle_outline
              : color == WfColors.danger
                  ? Icons.info_outline
                  : Icons.info_outline,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }
}

class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    const rules = [
      '3-20 characters',
      'letters, numbers, underscores and periods',
      'starts with a letter',
      'no double periods, no trailing period',
      'no reserved or offensive words',
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WfColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Username rules', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...rules.map(
            (rule) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  ', style: TextStyle(color: WfColors.textMuted)),
                  Expanded(
                    child: Text(rule, style: const TextStyle(color: WfColors.textMuted, fontSize: 12.5)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'You can change your username once every 30 days. Old usernames stay reserved for 90 days.',
            style: TextStyle(color: WfColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
