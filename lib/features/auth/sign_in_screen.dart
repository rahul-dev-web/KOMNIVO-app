import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_config.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../shell/app_shell.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _googleSignIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: AppConfig.oauthRedirect,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 58, height: 58,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: const LinearGradient(colors: [KomnivoTheme.accent, KomnivoTheme.cyan]),
                    ),
                    child: const Icon(Icons.sports_esports, color: Colors.white, size: 30),
                  ),
                  const SizedBox(height: 26),
                  Text('KOMNIVO', style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: 2.2)),
                  const SizedBox(height: 8),
                  const Text('Your community. Your squad. Your competition.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 16)),
                  const SizedBox(height: 30),
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: KomnivoTheme.surface,
                      border: Border.all(color: KomnivoTheme.line),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Enter the arena', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        const Text('Connect with gaming communities, manage your team and compete in organised events.', style: TextStyle(color: KomnivoTheme.muted, height: 1.45)),
                        const SizedBox(height: 22),
                        if (AppConfig.supabaseReady)
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _googleSignIn,
                              icon: _busy
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.account_circle_outlined),
                              label: Text(_busy ? 'Connecting…' : 'Continue with Google'),
                            ),
                          )
                        else ...[
                          const PreviewBanner(),
                          const Text('Backend setup is pending. Preview the complete app interface while Supabase and Google OAuth are connected.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 13)),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12)),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pushReplacement(
                              MaterialPageRoute(builder: (_) => const AppShell(preview: true)),
                            ),
                            child: const Text('Explore KOMNIVO preview'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('Built for communities and competitive gaming — not just tournament brackets.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
