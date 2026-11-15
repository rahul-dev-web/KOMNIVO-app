import 'package:flutter/material.dart';

import '../../core/komnivo_logo.dart';
import '../ai/ai_assistant_screen.dart';
import '../community/community_screen.dart';
import '../compete/compete_screen.dart';
import '../inbox/inbox_screen.dart';
import '../inbox/notifications_screen.dart';
import '../liveops/liveops_screen.dart';
import '../profile/profile_screen.dart';
import '../teams/teams_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.preview = false});
  final bool preview;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Community is the first destination shown at app launch; Home is intentionally removed.
  int _index = 0;
  bool _showLiveOps = false;
  bool _showProfile = false;

  @override
  Widget build(BuildContext context) {
    final compactToolbar = MediaQuery.sizeOf(context).width < 480;
    final pages = <Widget>[
      CommunityScreen(preview: widget.preview),
      CompeteScreen(preview: widget.preview),
      TeamsScreen(preview: widget.preview),
      InboxScreen(preview: widget.preview),
    ];

    final Widget body = _showLiveOps
        ? LiveOpsScreen(
            preview: widget.preview,
            onBack: () => setState(() => _showLiveOps = false),
          )
        : _showProfile
            ? ProfileScreen(
                preview: widget.preview,
                onBack: () => setState(() => _showProfile = false),
              )
            : pages[_index];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: compactToolbar ? 12 : 20,
        title: Row(children: [
          KomnivoLogo(size: compactToolbar ? 28 : 31, borderRadius: 9),
          const SizedBox(width: 10),
          const Text(
            'KOMNIVO',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: compactToolbar ? 16 : 18,
              letterSpacing: compactToolbar ? .9 : 1.4,
            ),
          ),
        ]),
        actions: [
          if (compactToolbar)
            PopupMenuButton<String>(
              tooltip: 'More tools',
              onSelected: (value) {
                if (value == 'ai') {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AiAssistantScreen(mode: 'player'),
                    ),
                  );
                } else {
                  setState(() {
                    _showLiveOps = true;
                    _showProfile = false;
                  });
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem<String>(
                  value: 'ai',
                  child: Text('Ask KOMNIVO AI'),
                ),
                PopupMenuItem<String>(
                  value: 'liveops',
                  child: Text('LiveOps Assistant'),
                ),
              ],
            )
          else ...[
            IconButton(
              tooltip: 'Ask KOMNIVO AI',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AiAssistantScreen(mode: 'player'),
                ),
              ),
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              tooltip: 'LiveOps Assistant',
              onPressed: () => setState(() {
                _showLiveOps = true;
                _showProfile = false;
              }),
              icon: const Icon(Icons.radar_outlined),
            ),
          ],
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const NotificationsScreen(),
              ),
            ),
            icon: const Icon(Icons.notifications_none_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: IconButton(
              tooltip: 'Profile and account',
              onPressed: () => setState(() {
                _showProfile = true;
                _showLiveOps = false;
              }),
              icon: const CircleAvatar(
                radius: 16,
                child: Icon(Icons.person_outline, size: 18),
              ),
            ),
          ),
        ],,
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: (_showLiveOps || _showProfile)
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups),
                  label: 'Community',
                ),
                NavigationDestination(
                  icon: Icon(Icons.emoji_events_outlined),
                  selectedIcon: Icon(Icons.emoji_events),
                  label: 'Compete',
                ),
                NavigationDestination(
                  icon: Icon(Icons.shield_outlined),
                  selectedIcon: Icon(Icons.shield),
                  label: 'Team',
                ),
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'DM',
                ),
              ],
            ),
    );
  }
}
