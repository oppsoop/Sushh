import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../state/app_state.dart';
import 'verify_email_screen.dart';
import 'widgets.dart';
import 'server_dialog.dart';
import 'theme.dart';

class _Brand extends StatelessWidget {
  const _Brand({this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset('assets/logo.png', width: 46, height: 46),
            ),
            const SizedBox(width: 12),
            const Text(
              'WorldFriends',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
            const SizedBox(width: 8),
            const BetaBadge(),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(subtitle!, style: const TextStyle(color: WfColors.textMuted, fontSize: 14)),
        ],
      ],
    );
  }
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Server settings',
                  icon: const Icon(Icons.dns_outlined, size: 20, color: WfColors.textMuted),
                  onPressed: () => showServerDialog(context),
                ),
              ),
              const _Brand(subtitle: 'A private space for your friends and family.'),
              const Spacer(),
              Center(
                child: Image.asset('assets/logo.png', width: 132, height: 132),
              ),
              const Spacer(),
              if (app.startupError != null) ErrorText(message: app.startupError),
              LoadingButton(
                label: 'Create an account',
                loading: app.busy,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RegisterScreen()),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                ),
                child: const Text('I already have an account'),
              ),
              if (AppConfig.googleServerClientId.isNotEmpty) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: app.busy
                      ? null
                      : () async {
                          try {
                            await context.read<AppState>().signInWithGoogle();
                          } on ApiException catch (error) {
                            if (context.mounted) showSnack(context, error.friendly, error: true);
                          } catch (_) {
                            if (context.mounted) showSnack(context, 'Google sign-in was cancelled', error: true);
                          }
                        },
                  icon: const Icon(Icons.g_mobiledata, size: 26),
                  label: const Text('Continue with Google'),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Private beta: an invite code or an approved email may be required.',
                textAlign: TextAlign.center,
                style: TextStyle(color: WfColors.textMuted.withValues(alpha: 0.9), fontSize: 12),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _needsVerification = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = null;
      _needsVerification = false;
    });
    try {
      await context.read<AppState>().login(email: _email.text, password: _password.text);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (error) {
      setState(() {
        _error = error.friendly;
        _needsVerification = error.code == 'email_not_verified';
      });
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    }
  }

  Future<void> _resend() async {
    try {
      await context.read<AppState>().resendVerification(_email.text);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => VerifyEmailScreen(email: _email.text.trim())),
      );
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.friendly, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Brand(),
                const SizedBox(height: 28),
                ErrorText(message: _error),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email', hintText: 'you@example.com'),
                  validator: (value) => (value ?? '').contains('@') ? null : 'Enter a valid email',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password'),
                  validator: (value) => (value ?? '').length >= 8 ? null : 'At least 8 characters',
                  onFieldSubmitted: (_) => _submit(),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ForgotPasswordScreen(email: _email.text.trim())),
                    ),
                    child: const Text('Forgot password?'),
                  ),
                ),
                const SizedBox(height: 8),
                LoadingButton(label: 'Sign in', loading: app.busy, onPressed: _submit),
                if (_needsVerification) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _resend,
                    child: const Text('Verify my email'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _invite = TextEditingController();
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _invite.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      await context.read<AppState>().register(
            email: _email.text,
            password: _password.text,
            displayName: _name.text,
            inviteCode: _invite.text,
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VerifyEmailScreen(email: _email.text.trim())),
      );
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not create your account. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Brand(subtitle: 'Friends and family only. Your messages stay private.'),
                const SizedBox(height: 28),
                ErrorText(message: _error),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Your name', hintText: 'Jane Doe'),
                  validator: (value) => (value ?? '').trim().length >= 2 ? null : 'Tell us your name',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email', hintText: 'you@example.com'),
                  validator: (value) {
                    final text = (value ?? '').trim();
                    if (!text.contains('@') || !text.contains('.')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    helperText: 'At least 8 characters',
                  ),
                  validator: (value) => (value ?? '').length >= 8 ? null : 'At least 8 characters',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _invite,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Invite code (if you have one)',
                    hintText: 'FRIENDS2026',
                  ),
                ),
                const SizedBox(height: 20),
                LoadingButton(label: 'Create account', loading: _submitting, onPressed: _submit),
                const SizedBox(height: 12),
                Text(
                  'By joining you agree to be a decent human being. Report anything that feels wrong.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: WfColors.textMuted.withValues(alpha: 0.9), fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.email = ''});

  final String email;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final TextEditingController _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await context.read<AppState>().forgotPassword(_email.text);
      setState(() => _codeSent = true);
      if (!mounted) return;
      final devCode = data['devCode'];
      showSnack(
        context,
        devCode != null ? 'Development code: $devCode' : 'If that email has an account, a code is on its way.',
      );
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().resetPassword(
            email: _email.text,
            code: _code.text,
            newPassword: _password.text,
          );
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ErrorText(message: _error),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              if (_codeSent) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '6-digit code'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                const SizedBox(height: 20),
                LoadingButton(label: 'Set new password', loading: _busy, onPressed: _reset),
              ] else ...[
                const SizedBox(height: 20),
                LoadingButton(label: 'Send reset code', loading: _busy, onPressed: _request),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
