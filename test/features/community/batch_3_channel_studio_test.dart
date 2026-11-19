import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';
import 'package:komnivo/features/community/channel_studio_screen.dart';
import 'package:komnivo/features/inbox/forum_channel_screen.dart';

void main() {
  Future<void> pumpStudio(
    WidgetTester tester, {
    Size size = const Size(430, 900),
    bool canManagePermissions = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: KomnivoTheme.dark,
        home: ChannelStudioScreen(
          communityId: 'community-ui-test',
          communityName: 'UI Test Community',
          canManagePermissions: canManagePermissions,
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

  Future<void> pumpForum(
    WidgetTester tester, {
    bool canModerate = true,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: KomnivoTheme.dark,
        home: ForumChannelScreen(
          channel: const {
            'id': 'forum-ui-test',
            'name': 'looking-for-team',
          },
          canModerate: canModerate,
        ),
      ),
    );
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
    await tester.drag(find.byKey(const ValueKey('batch3-text-list')), const Offset(0, -1100));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.text('Controlled mentions'), findsOneWidget);

    await openStudioTab(tester, 'Forum');
    expect(find.text('Forum channels'), findsOneWidget);
    expect(find.text('In discussion'), findsWidgets);
    expect(find.text('New post'), findsOneWidget);

    await openStudioTab(tester, 'Engage');
    expect(find.text('Threads & replies'), findsOneWidget);
    expect(find.text('Scheduled announcements'), findsOneWidget);
    expect(find.text('Polls'), findsOneWidget);

    await openStudioTab(tester, 'Voice / Stage');
    expect(find.text('Voice and Stage are different surfaces'), findsOneWidget);
    expect(find.text('Stage broadcast'), findsOneWidget);
    expect(find.text('Speaker access'), findsOneWidget);

    await openStudioTab(tester, 'Event flow');
    expect(find.text('Approved event channel templates'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Temporary channel lifecycle'),
      320,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('batch3-event-flow-list')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Temporary channel lifecycle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Channel Studio category create action updates its local preview',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);

    final createCategory = find.text('Category').first;
    await tester.ensureVisible(createCategory);
    await tester.tap(createCategory);
    await tester.pumpAndSettle();
    expect(find.text('Create category'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Category name'),
      'Practice Rooms',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final newCategory = find.text('PRACTICE ROOMS');
    await tester.drag(find.byKey(const ValueKey('batch3-structure-list')), const Offset(0, -1600));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(newCategory, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Forum channel filters topics and previews a new post',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpForum(tester);

    expect(find.text('Looking for two players for tonight'), findsOneWidget);
    final search = find.byType(TextField).first;
    await tester.enterText(search, 'Team recruitment closed');
    await tester.pumpAndSettle();

    expect(find.text('Team recruitment closed').last, findsOneWidget);
    expect(find.text('Looking for two players for tonight'), findsNothing);
    await tester.enterText(search, '');
    await tester.pumpAndSettle();

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

  testWidgets('Forum moderator can pin and lock a topic',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpForum(tester);

    final firstMenu = find.byType(PopupMenuButton<String>).first;
    await tester.tap(firstMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin topic'));
    await tester.pumpAndSettle();
    expect(find.text('Pinned'), findsNothing);

    final menuAgain = find.byType(PopupMenuButton<String>).first;
    await tester.tap(menuAgain);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock replies'));
    await tester.pumpAndSettle();

    final firstTopic = find.text('Looking for two players for tonight');
    await tester.tap(firstTopic);
    await tester.pumpAndSettle();
    expect(find.text('Replies are locked for this topic.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Channel Studio permission editor is read-only without delegation authority',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester, canManagePermissions: false);

    await openStudioTab(tester, 'Permissions');
    expect(find.textContaining('Preview only'), findsOneWidget);
    await tester.tap(find.text('Channel override'));
    await tester.pumpAndSettle();
    final sync = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Sync with category'),
    );
    expect(sync.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Channel Studio remains usable at desktop width',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester, size: const Size(1440, 1000));

    expect(find.text('Channel structure'), findsOneWidget);
    await openStudioTab(tester, 'Permissions');
    expect(find.text('Permission inheritance'), findsOneWidget);
    await openStudioTab(tester, 'Forum');
    expect(find.text('Forum channels'), findsOneWidget);
    await openStudioTab(tester, 'Event flow');
    final lifecycle = find.text('Temporary channel lifecycle');
    await tester.scrollUntilVisible(
      lifecycle,
      320,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('batch3-event-flow-list')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.pumpAndSettle();
    expect(lifecycle, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
