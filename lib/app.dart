import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app_config.dart';
import 'core/komnivo_theme.dart';
import 'core/push_service.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/shell/app_shell.dart';

class KomnivoApp extends StatelessWidget {
  const KomnivoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KOMNIVO',
      debugShowCheckedModeBanner: false,
      theme: KomnivoTheme.dark,
      scaffoldMessengerKey: PushService.scaffoldMessengerKey,
      home: AppConfig.supabaseReady ? const _AuthGate() : const SignInScreen(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  String? _lastSyncedUser;

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      initialData: AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? client.auth.currentSession;
        final userId = session?.user.id;
        if (userId != null && userId != _lastSyncedUser) {
          _lastSyncedUser = userId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            PushService.syncCurrentToken();
          });
        }
        if (session == null) {
          _lastSyncedUser = null;
          return const SignInScreen();
        }
        return const AppShell();
      },
    );
  }
}
