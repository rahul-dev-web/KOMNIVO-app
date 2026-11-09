import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'core/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppConfig.supabaseReady) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabasePublishableKey,
      authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
    );
  }

  if (AppConfig.firebaseReady) {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: AppConfig.firebaseApiKey,
        appId: AppConfig.firebaseAppId,
        messagingSenderId: AppConfig.firebaseSenderId,
        projectId: AppConfig.firebaseProjectId,
        storageBucket: AppConfig.firebaseStorageBucket.isEmpty ? null : AppConfig.firebaseStorageBucket,
        authDomain: AppConfig.firebaseAuthDomain.isEmpty ? null : AppConfig.firebaseAuthDomain,
      ),
    );
    await PushService.initialize();
  }

  runApp(const KomnivoApp());
}
