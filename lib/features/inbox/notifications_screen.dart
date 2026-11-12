import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/push_service.dart';
import '../../core/ui.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<List<Map<String, dynamic>>> _notifications;
  late Future<Map<String, dynamic>> _preferences;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _notifications = KomnivoRepository.instance.myNotifications();
    _preferences = KomnivoRepository.instance.notificationPreferences();
  }

  Future<void> _markRead(String id) async {
    try {
      await KomnivoRepository.instance.markNotificationRead(id);
      if (mounted) setState(_reload);
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _setPreference(String key, bool value) async {
    setState(() => _saving = true);
    try {
      await KomnivoRepository.instance.updateNotificationPreferences({key: value});
      if (mounted) setState(_reload);
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _enableBrowserNotifications() async {
    setState(() => _saving = true);
    try {
      await PushService.enableBrowserNotifications();
      if (mounted) {
        showMessage(context, 'Browser notifications enabled on this device.');
      }
    } catch (error) {
      if (mounted) showMessage(context, 'Could not enable browser notifications: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'message': return Icons.chat_bubble_outline;
      case 'event': return Icons.event_available_outlined;
      case 'tournament': return Icons.emoji_events_outlined;
      case 'mention': return Icons.alternate_email;
      default: return Icons.notifications_none;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (kIsWeb) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: KomnivoTheme.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KomnivoTheme.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.notifications_active_outlined, color: KomnivoTheme.cyan),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Browser notifications',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Allow KOMNIVO to notify this device about messages, community activity and tournament updates. On iPhone, open KOMNIVO from its Home Screen icon before enabling push.',
                    style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving ||
                              !AppConfig.firebaseReady ||
                              AppConfig.firebaseVapidKey.isEmpty
                          ? null
                          : _enableBrowserNotifications,
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Enable browser notifications'),
                    ),
                  ),
                  if (!AppConfig.firebaseReady || AppConfig.firebaseVapidKey.isEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Browser push configuration is not present in this build yet.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _notifications,
            builder: (context, snapshot) {
              final rows = snapshot.data ?? [];
              final unread = rows.where((row) => row['read_at'] == null).length;
              return SectionTitle(
                'Activity',
                subtitle: '$unread unread · latest updates from your communities and events',
                trailing: IconButton(onPressed: () => setState(_reload), icon: const Icon(Icons.refresh)),
              );
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _notifications,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator()));
              }
              if (snapshot.hasError) return Text(snapshot.error.toString(), style: const TextStyle(color: Color(0xFFFF8193)));
              final rows = snapshot.data ?? [];
              if (rows.isEmpty) {
                return const EmptyState(
                  title: 'You are all caught up',
                  message: 'Community messages, event updates and match actions will appear here.',
                  icon: Icons.notifications_none,
                );
              }
              return Column(children: rows.map((row) {
                final read = row['read_at'] != null;
                final kind = (row['kind'] ?? 'general').toString();
                final created = DateTime.tryParse(row['created_at']?.toString() ?? '');
                return InkWell(
                  onTap: read ? null : () => _markRead(row['id'] as String),
                  borderRadius: BorderRadius.circular(15),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: read ? KomnivoTheme.surface : const Color(0xFF211B3E),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: read ? KomnivoTheme.line : KomnivoTheme.accent.withValues(alpha: .45)),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      CircleAvatar(
                        backgroundColor: KomnivoTheme.surfaceRaised,
                        child: Icon(_iconFor(kind), color: KomnivoTheme.cyan, size: 19),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(row['title']?.toString() ?? 'KOMNIVO update', style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(row['body']?.toString() ?? '', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.35)),
                        if (created != null) ...[
                          const SizedBox(height: 6),
                          Text(created.toLocal().toString().substring(0, 16), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
                        ],
                      ])),
                      if (!read) const Padding(
                        padding: EdgeInsets.only(top: 5),
                        child: Icon(Icons.circle, size: 8, color: KomnivoTheme.accent),
                      ),
                    ]),
                  ),
                );
              }).toList());
            },
          ),
          const SizedBox(height: 24),
          const SectionTitle('Push preferences', subtitle: 'Choose which updates can interrupt you'),
          const SizedBox(height: 8),
          FutureBuilder<Map<String, dynamic>>(
            future: _preferences,
            builder: (context, snapshot) {
              final prefs = snapshot.data ?? {};
              if (snapshot.connectionState == ConnectionState.waiting) return const LinearProgressIndicator();
              final rows = <(String, String, String)>[
                ('push_enabled', 'Push notifications', 'Master switch for device notifications'),
                ('message_push', 'Messages', 'New messages in your channels and conversations'),
                ('mention_push', 'Mentions', 'When another player mentions you'),
                ('event_push', 'Community events', 'Community event announcements'),
                ('tournament_push', 'Tournament updates', 'Registration, check-in, match and result updates'),
              ];
              return Container(
                decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
                child: Column(children: [
                  for (var index = 0; index < rows.length; index++) ...[
                    SwitchListTile(
                      value: (prefs[rows[index].$1] as bool?) ?? true,
                      onChanged: _saving ? null : (value) => _setPreference(rows[index].$1, value),
                      title: Text(rows[index].$2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      subtitle: Text(rows[index].$3, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                    ),
                    if (index != rows.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
                  ],
                  if (_saving) const LinearProgressIndicator(minHeight: 2),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}
