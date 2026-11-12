import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'pwa_environment.dart';

class PushService {
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static bool _initialized = false;
  static StreamSubscription<String>? _tokenRefreshSubscription;

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Android handles background messages through the registered Dart handler.
    // Browser background delivery is handled by firebase-messaging-sw.js.
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }

    FirebaseMessaging.onMessage.listen(_showForegroundMessage);

    // Browser permission must be requested from an explicit user action.
    // Do not trigger the browser permission prompt during page startup.
    if (!kIsWeb) {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      await syncCurrentToken();
    }

    // FCM rotates registration tokens periodically. Keep the latest token
    // associated with the current signed-in KOMNIVO account.
    // ignore: deprecated_member_use
    _tokenRefreshSubscription ??=
        FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(saveToken(token, platform: _currentPlatform));
    });
  }

  static String get _currentPlatform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'other',
    };
  }

  static void _showForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    final title = notification?.title?.trim();
    final body = notification?.body?.trim();
    final text = [
      if (title != null && title.isNotEmpty) title,
      if (body != null && body.isNotEmpty) body,
    ].join(' — ');

    if (text.isEmpty) return;
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  static Future<void> syncCurrentToken() async {
    if (Supabase.instance.client.auth.currentUser == null) return;

    final messaging = FirebaseMessaging.instance;
    String? token;

    if (kIsWeb) {
      if (AppConfig.firebaseVapidKey.isEmpty) return;
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        return;
      }
      // ignore: deprecated_member_use
      token = await messaging.getToken(
        vapidKey: AppConfig.firebaseVapidKey,
        serviceWorkerScriptPath: AppConfig.firebaseMessagingServiceWorkerPath,
      );
    } else {
      // ignore: deprecated_member_use
      token = await messaging.getToken();
    }

    if (token != null && token.isNotEmpty) {
      await saveToken(token, platform: _currentPlatform);
    }
  }

  /// Call this only from an explicit button press in the browser.
  static Future<void> enableBrowserNotifications() async {
    if (!kIsWeb) {
      throw StateError('Browser notifications are only available on the Web app.');
    }
    if (PwaEnvironment.isIosDevice && !PwaEnvironment.isStandalone) {
      throw StateError(
        'On iPhone or iPad, first add KOMNIVO to the Home Screen and open it from its Home Screen icon before enabling notifications.',
      );
    }
    if (!AppConfig.firebaseReady || AppConfig.firebaseVapidKey.isEmpty) {
      throw StateError(
        'Firebase Web configuration is missing. Add the Firebase Web app values and VAPID public key to the Cloudflare Pages build variables.',
      );
    }
    if (Supabase.instance.client.auth.currentUser == null) {
      throw StateError('Sign in to KOMNIVO before enabling browser notifications.');
    }

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('Browser notification permission was not granted.');
    }

    // firebase_messaging 17.x supports an isolated service-worker path so
    // FCM does not take over Flutter's own root-scope PWA service worker.
    // ignore: deprecated_member_use
    final token = await messaging.getToken(
      vapidKey: AppConfig.firebaseVapidKey,
      serviceWorkerScriptPath: AppConfig.firebaseMessagingServiceWorkerPath,
    );
    if (token == null || token.isEmpty) {
      throw StateError('Firebase did not return a browser registration token.');
    }

    await saveToken(token, platform: 'web');
  }

  static Future<void> saveToken(String token, {String? platform}) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    await Supabase.instance.client.from('device_tokens').upsert({
      'user_id': user.id,
      'token': token,
      'platform': platform ?? _currentPlatform,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Android notification payloads are displayed by the operating system.
}
