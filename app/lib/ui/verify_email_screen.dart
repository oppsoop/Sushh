import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});

  final String email;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;
  int _resendIn = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final devCode = context.read<AppState>().pendingDevCode;
    if (devCode != null && devCode.isNotEmpty) _code.text = devCode;
    _code.addListener(() {
      if (_code.text.length == 6) _submit();
      setState(() {});
    });
    if (devCode != null && devCode.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    setState(() => _resendIn = 30);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _resendIn -= 1);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  Future<void> _submit() async {
    if (_busy || _code.text.length < 6) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().verifyEmail(email: widget.email, code: _code.text);
      if (!mounted) return;
      // The root router switches to the username step automatically.
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not verify that code. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await context.read<AppState>().resendVerification(widget.email);
      _startCooldown();
      if (!mounted) return;
      showSnack(context, 'A new code is on its way.');
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your email')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.mark_email_read_outlined, size: 64, color: WfColors.primary),
              const SizedBox(height: 20),
              Text(
                'We sent a 6-digit code to\n${widget.email}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.4),
              ),
              const SizedBox(height: 24),
              ErrorText(message: _error),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 6,
                style: const TextStyle(fontSize: 30, letterSpacing: 10, fontWeight: FontWeight.w700),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(counterText: '', hintText: '______'),
              ),
              const SizedBox(height: 16),
              LoadingButton(label: 'Verify', loading: _busy, onPressed: _submit),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _resendIn > 0 ? null : _resend,
                child: Text(_resendIn > 0 ? 'Resend code in ${_resendIn}s' : 'Resend code'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await context.read<AppState>().logout();
                },
                child: const Text('Use a different email', style: TextStyle(color: WfColors.textMuted)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
