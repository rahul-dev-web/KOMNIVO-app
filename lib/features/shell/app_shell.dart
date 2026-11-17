import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/komnivo_logo.dart';
import '../ai/ai_assistant_screen.dart';
import '../community/community_screen.dart';
import '../compete/compete_screen.dart';
import '../inbox/inbox_screen.dart';
import '../inbox/notifications_screen.dart';
import '../liveops/liveops_screen.dart';
import '../profile/profile_screen.dart';
import '../teams/teams_screen.dart';
import '../store/store_screen.dart';

/// Lets the root navigator send users back to the Community destination after
/// closing any pushed detail page on Android.
class AppShellBackNavigation {
  AppShellBackNavigation._();

  static VoidCallback? _returnToCommunity;

  static void register(VoidCallback callback) {
    _returnToCommunity = callback;
  }

  static void unregister(VoidCallback callback) {
    if (identical(_returnToCommunity, callback)) {
      _returnToCommunity = null;
    }
  }

  static void returnToCommunity() {
    _returnToCommunity?.call();
  }
}

/// A single Android back from a pushed page returns to the app's Community
/// home, even when detail pages have been pushed on top of other detail pages.
class AppShellBackObserver extends NavigatorObserver {
  bool _collapsingDetailRoutes = false;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);

    if (defaultTargetPlatform != TargetPlatform.android ||
        route is! PageRoute<dynamic> ||
        _collapsingDetailRoutes) {
      return;
    }

    final activeNavigator = navigator;
    if (activeNavigator == null) return;

    _collapsingDetailRoutes = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (activeNavigator.mounted) {
        activeNavigator.popUntil((candidate) => candidate.isFirst);
        AppShellBackNavigation.returnToCommunity();
      }
      _collapsingDetailRoutes = false;
    });
  }
}

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
  bool _exitDialogShowing = false;

  late final VoidCallback _routeBackCallback = _returnToCommunity;

  @override
  void initState() {
    super.initState();
    AppShellBackNavigation.register(_routeBackCallback);
  }

  @override
  void dispose() {
    AppShellBackNavigation.unregister(_routeBackCallback);
    super.dispose();
  }

  void _returnToCommunity() {
    if (!mounted) return;
    setState(() {
      _index = 0;
      _showLiveOps = false;
      _showProfile = false;
    });
  }

  Future<void> _handleAndroidBack() async {
    if (!mounted || _exitDialogShowing) return;

    if (_index != 0 || _showLiveOps || _showProfile) {
      _returnToCommunity();
      return;
    }

    _exitDialogShowing = true;
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Exit KOMNIVO?'),
        content: const Text('Are you sure you want to close the app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    _exitDialogShowing = false;

    if (mounted && shouldExit == true) {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final compactToolbar = MediaQuery.sizeOf(context).width < 480;
    final isAndroid = !kIsWeb &&
        Theme.of(context).platform == TargetPlatform.android;
    final pages = <Widget>[
      CommunityScreen(preview: widget.preview),
      CompeteScreen(preview: widget.preview),
      StoreScreen(preview: widget.preview),
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

    return PopScope<Object?>(
      canPop: !isAndroid,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && isAndroid) {
          unawaited(_handleAndroidBack());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: compactToolbar ? 12 : 20,
          title: Row(children: [
            KomnivoLogo(size: compactToolbar ? 28 : 31, borderRadius: 9),
            const SizedBox(width: 10),
            Text(
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
          ],
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
                    icon: Icon(Icons.storefront_outlined),
                    selectedIcon: Icon(Icons.storefront),
                    label: 'Store',
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
      ),
    );
  }
}
