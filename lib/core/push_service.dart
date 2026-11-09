import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PushService {
  static Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await saveToken(token);
    FirebaseMessaging.instance.onTokenRefresh.listen(saveToken);
  }

  static Future<void> syncCurrentToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await saveToken(token);
  }

  static Future<void> saveToken(String token) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    await Supabase.instance.client.from('device_tokens').upsert({
      'user_id': user.id,
      'token': token,
      'platform': 'flutter',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Notification payloads are displayed by the operating system.
}
