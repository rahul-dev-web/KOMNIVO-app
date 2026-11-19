import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';
import 'package:komnivo/features/community/channel_studio_screen.dart';
import 'package:komnivo/features/inbox/forum_channel_screen.dart';

void main() {
  Future<void> pumpStudio(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: KomnivoTheme.dark,
        home: const ChannelStudioScreen(
          communityId: 'community-ui-test',
          communityName: 'UI Test Community',
          canManagePermissions: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openStudioTab(WidgetTester tester, String label) async {
    final tab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text(label),
    );
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  void resetView(WidgetTester tester) {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('Channel Studio exposes all seven Batch 3 configuration surfaces',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);

    expect(find.text('Channel Studio'), findsOneWidget);
    expect(find.text('Channel structure'), findsOneWidget);

    await openStudioTab(tester, 'Permissions');
    expect(find.text('Permission inheritance'), findsOneWidget);
    expect(find.text('Inherit'), findsWidgets);
    expect(find.text('Allow'), findsWidgets);
    expect(find.text('Deny'), findsWidgets);
    await tester.tap(find.text('Channel override'));
    await tester.pumpAndSettle();
    expect(find.text('Sync with category'), findsOneWidget);

    await openStudioTab(tester, 'Text');
    expect(find.text('Text & Announcement behaviour'), findsOneWidget);
    expect(find.text('Read-only channel'), findsOneWidget);
    expect(find.text('Slow mode'), findsOneWidget);
    expect(find.text('Controlled mentions'), findsOneWidget);

    await openStudioTab(tester, 'Forum');
    expect(find.text('Forum channels'), findsOneWidget);
    expect(find.text('In discussion'), findsWidgets);
    expect(find.text('New post'), findsOneWidget);

    await openStudioTab(tester, 'Engage');
    expect(find.text('Conversation tools'), findsOneWidget);
    expect(find.text('Scheduled announcements'), findsOneWidget);
    expect(find.text('Polls'), findsOneWidget);

    await openStudioTab(tester, 'Voice / Stage');
    expect(find.text('Voice and Stage are different surfaces'), findsOneWidget);
    expect(find.text('Stage broadcast'), findsOneWidget);
    expect(find.text('Speaker access'), findsOneWidget);

    await openStudioTab(tester, 'Event flow');
    expect(find.text('Approved event channel templates'), findsOneWidget);
    expect(find.text('Temporary channel lifecycle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Channel Studio category create action updates its local preview',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);

    await tester.tap(find.text('Category').first);
    await tester.pumpAndSettle();
    expect(find.text('Create category'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Practice Rooms');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('PRACTICE ROOMS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Forum channel filters topics and previews a new post',
      (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => resetView(tester));
    await tester.pumpWidget(
      MaterialApp(
        theme: KomnivoTheme.dark,
        home: const ForumChannelScreen(
          channel: {'id': 'forum-ui-test', 'name': 'looking-for-team'},
          canModerate: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Looking for two players for tonight'), findsOneWidget);
    await tester.tap(find.text('Closed').first);
    await tester.pumpAndSettle();
    expect(find.text('Team recruitment closed'), findsOneWidget);
    expect(find.text('Looking for two players for tonight'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Create Forum post'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Topic title'),
      'Need a substitute for finals',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Details'),
      'Available for the Saturday finals.',
    );
    await tester.tap(find.text('Preview post'));
    await tester.pumpAndSettle();

    expect(find.text('Need a substitute for finals'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
