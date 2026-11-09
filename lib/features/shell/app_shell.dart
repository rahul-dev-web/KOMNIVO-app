import 'package:flutter/material.dart';

import '../../core/komnivo_theme.dart';
import '../community/community_screen.dart';
import '../compete/compete_screen.dart';
import '../home/home_screen.dart';
import '../inbox/inbox_screen.dart';
import '../inbox/notifications_screen.dart';
import '../liveops/liveops_screen.dart';
import '../organizer/organizer_screen.dart';
import '../profile/profile_screen.dart';
import '../teams/teams_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.preview = false});
  final bool preview;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _showLiveOps = false;
  bool _showOrganizer = false;
  bool _showProfile = false;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(preview: widget.preview, onLiveOps: () => setState(() { _showLiveOps = true; _showOrganizer = false; _showProfile = false; }), onOrganizer: () => setState(() { _showOrganizer = true; _showLiveOps = false; _showProfile = false; })),
      CommunityScreen(preview: widget.preview),
      CompeteScreen(preview: widget.preview),
      TeamsScreen(preview: widget.preview),
      InboxScreen(preview: widget.preview),
    ];
    final Widget body = _showLiveOps
        ? LiveOpsScreen(preview: widget.preview, onBack: () => setState(() => _showLiveOps = false))
        : _showOrganizer
            ? OrganizerScreen(preview: widget.preview, onBack: () => setState(() => _showOrganizer = false))
            : _showProfile
                ? ProfileScreen(preview: widget.preview, onBack: () => setState(() => _showProfile = false))
                : pages[_index];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(children: [
          Container(
            width: 31, height: 31,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: const LinearGradient(colors: [KomnivoTheme.accent, KomnivoTheme.cyan]),
            ),
            child: const Icon(Icons.sports_esports, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Text('KOMNIVO', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.4)),
        ]),
        actions: [
          IconButton(
            tooltip: 'LiveOps Assistant',
            onPressed: () => setState(() { _showLiveOps = true; _showOrganizer = false; _showProfile = false; }),
            icon: const Icon(Icons.radar_outlined),
          ),
          IconButton(
            tooltip: 'Organiser workspace',
            onPressed: () => setState(() { _showOrganizer = true; _showLiveOps = false; _showProfile = false; }),
            icon: const Icon(Icons.dashboard_customize_outlined),
          ),
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen())),
            icon: const Icon(Icons.notifications_none_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: IconButton(
              tooltip: 'Profile and account',
              onPressed: () => setState(() { _showProfile = true; _showLiveOps = false; _showOrganizer = false; }),
              icon: const CircleAvatar(radius: 16, child: Icon(Icons.person_outline, size: 18)),
            ),
          ),
        ],
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: (_showLiveOps || _showOrganizer || _showProfile)
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Community'),
                NavigationDestination(icon: Icon(Icons.emoji_events_outlined), selectedIcon: Icon(Icons.emoji_events), label: 'Compete'),
                NavigationDestination(icon: Icon(Icons.shield_outlined), selectedIcon: Icon(Icons.shield), label: 'Teams'),
                NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Inbox'),
              ],
            ),
    );
  }
}
