import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'push_service.dart';

class StartupCoordinator {
  StartupCoordinator._();

  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);
  static final ValueNotifier<String?> error = ValueNotifier<String?>(null);
  static bool _isStarting = false;

  static Future<void> initialize() async {
    if (ready.value || _isStarting) return;

    _isStarting = true;
    error.value = null;

    try {
      if (AppConfig.supabaseReady) {
        await Supabase.initialize(
          url: AppConfig.supabaseUrl,
          publishableKey: AppConfig.supabasePublishableKey,
          authOptions: const FlutterAuthClientOptions(
            authFlowType: AuthFlowType.pkce,
          ),
        );
      }

      if (AppConfig.firebaseReady) {
        try {
          if (Firebase.apps.isEmpty) {
            await Firebase.initializeApp(
              options: FirebaseOptions(
                apiKey: AppConfig.firebaseApiKey,
                appId: AppConfig.firebaseAppId,
                messagingSenderId: AppConfig.firebaseSenderId,
                projectId: AppConfig.firebaseProjectId,
                storageBucket: AppConfig.firebaseStorageBucket.isEmpty
                    ? null
                    : AppConfig.firebaseStorageBucket,
                authDomain: AppConfig.firebaseAuthDomain.isEmpty
                    ? null
                    : AppConfig.firebaseAuthDomain,
              ),
            );
          }
          // Register listeners only. Permission prompts and token synchronization
          // are deferred until an authenticated session is available.
          PushService.initialize();
        } catch (exception, stackTrace) {
          debugPrint('KOMNIVO Firebase startup warning: $exception');
          debugPrintStack(stackTrace: stackTrace);
        }
      }

      ready.value = true;
    } catch (exception, stackTrace) {
      debugPrint('KOMNIVO startup failed: $exception');
      debugPrintStack(stackTrace: stackTrace);
      error.value =
          'KOMNIVO could not finish connecting. Check your connection and retry.';
    } finally {
      _isStarting = false;
    }
  }
}
