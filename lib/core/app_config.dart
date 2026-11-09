import 'package:flutter/foundation.dart';

class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const authRedirectUrl = String.fromEnvironment(
    'SUPABASE_REDIRECT_URL',
    defaultValue: 'in.komnivo.app://login-callback',
  );
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseStorageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
  static const firebaseAuthDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const firebaseVapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');

  static bool get supabaseReady =>
      supabaseUrl.startsWith('https://') &&
      supabasePublishableKey.startsWith('sb_publishable_');

  static bool get firebaseReady =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseSenderId.isNotEmpty &&
      firebaseProjectId.isNotEmpty;

  static String get oauthRedirect =>
      kIsWeb ? '${Uri.base.origin}${Uri.base.path}' : authRedirectUrl;
}
