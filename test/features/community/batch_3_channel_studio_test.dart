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

  Future<void> scrollStudioListUntilVisible(
    WidgetTester tester,
    String listKey,
    Finder target, {
    double delta = 320,
  }) async {
    final scrollable = find.descendant(
      of: find.byKey(ValueKey(listKey)),
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: scrollable,
    );
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
          initialPosts: const [
            {'title': 'Looking for two players for tonight', 'body': 'Need two reliable players for a squad. Share your role and availability.', 'tag': 'Recruitment', 'status': 'Open', 'author': 'RDX_Ace', 'replies': 8, 'time': '12 min ago', 'pinned': true, 'locked': false},
            {'title': 'Scrim schedule discussion', 'body': 'Can we agree on a practice window for this weekend?', 'tag': 'Scrims', 'status': 'In discussion', 'author': 'Nova', 'replies': 14, 'time': '38 min ago', 'pinned': false, 'locked': false},
            {'title': 'Support with voice setup', 'body': 'Microphone permissions are not appearing on my device.', 'tag': 'Support', 'status': 'Filled', 'author': 'Kairo', 'replies': 3, 'time': 'Yesterday', 'pinned': false, 'locked': false},
            {'title': 'Team recruitment closed', 'body': 'The roster is complete. Thanks to everyone who responded.', 'tag': 'Recruitment', 'status': 'Closed', 'author': 'IGL_Lead', 'replies': 6, 'time': 'Yesterday', 'pinned': false, 'locked': true},
          ],
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
    expect(find.text('Text & Announcement behaviour'), findsOneWidget);

    await openStudioTab(tester, 'Forum');
    expect(find.text('Forum channels'), findsOneWidget);
    expect(find.text('In discussion'), findsWidgets);
    expect(find.text('New post'), findsOneWidget);

    await openStudioTab(tester, 'Engage');
    expect(find.text('Threads & replies'), findsOneWidget);
    await scrollStudioListUntilVisible(
      tester, 'batch3-engagement-list', find.text('Polls'),
    );
    expect(find.text('Polls'), findsOneWidget);
    // The engagement surface is intentionally a vertical feed. Scroll the
    // actual Scrollable to build the lower scheduled-announcement section.
    await scrollStudioListUntilVisible(
      tester, 'batch3-engagement-list', find.text('Scheduled announcements'),
    );
    expect(find.text('Scheduled announcements'), findsOneWidget);

    await openStudioTab(tester, 'Voice / Stage');
    expect(find.text('Voice and Stage are different surfaces'), findsOneWidget);
    expect(find.text('Stage broadcast'), findsOneWidget);
    expect(find.text('Speaker access'), findsOneWidget);

    await openStudioTab(tester, 'Event flow');
    expect(find.text('Approved event channel templates'), findsOneWidget);
    expect(find.text('Event context'), findsOneWidget);
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

  testWidgets('Channel categories support collapse, rename, reorder, archive and restore',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);

    final announcementCard = find.byKey(const ValueKey('cat-announcements'));
    expect(announcementCard, findsOneWidget);
    expect(find.text('announcements'), findsOneWidget);

    await tester.tap(find.text('ANNOUNCEMENTS'));
    await tester.pumpAndSettle();
    expect(find.text('announcements'), findsNothing);
    await tester.tap(find.text('ANNOUNCEMENTS'));
    await tester.pumpAndSettle();
    expect(find.text('announcements'), findsOneWidget);

    await tester.tap(find.descendant(
      of: announcementCard,
      matching: find.byTooltip('Move down'),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('ANNOUNCEMENTS'));
    await tester.ensureVisible(find.text('COMMUNITY'));
    expect(
      tester.getTopLeft(find.text('COMMUNITY')).dy,
      lessThan(tester.getTopLeft(find.text('ANNOUNCEMENTS')).dy),
    );

    await tester.tap(find.descendant(
      of: announcementCard,
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename category'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Official Updates');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('OFFICIAL UPDATES'), findsOneWidget);

    await tester.tap(find.descendant(
      of: announcementCard,
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('OFFICIAL UPDATES'), findsNothing);

    await scrollStudioListUntilVisible(
      tester, 'batch3-structure-list', find.text('Show archived'), delta: -320,
    );
    await tester.tap(find.text('Show archived'));
    await tester.pumpAndSettle();
    expect(find.text('OFFICIAL UPDATES'), findsOneWidget);

    await tester.tap(find.descendant(
      of: announcementCard,
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('OFFICIAL UPDATES'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Text channel controls update the visible behaviour preview',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);
    await openStudioTab(tester, 'Text');

    final readOnly = find.widgetWithText(SwitchListTile, 'Read-only channel');
    expect(tester.widget<SwitchListTile>(readOnly).value, isFalse);
    await tester.tap(readOnly);
    await tester.pumpAndSettle();

    // Toggle both controls while they are in the same visible settings panel;
    // then scroll to the preview, which is intentionally lower in the feed.
    final slowMode = find.widgetWithText(SwitchListTile, 'Slow mode');
    await tester.tap(slowMode);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);

    await scrollStudioListUntilVisible(
      tester, 'batch3-text-list', find.text('READ ONLY'),
    );
    expect(find.text('READ ONLY'), findsOneWidget);
    expect(find.textContaining('Slow mode:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stage configuration exposes speaker, audience and room lifecycle controls',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);
    await openStudioTab(tester, 'Voice / Stage');
    await tester.tap(find.text('Stage broadcast'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Speaker promotion'));
    expect(find.text('Speaker promotion'), findsOneWidget);
    expect(find.text('Allow listeners to request the speaker role'), findsOneWidget);
    expect(find.text('Enable audience text chat'), findsOneWidget);
    expect(find.text('Audience'), findsOneWidget);
    expect(find.text('Room visibility'), findsOneWidget);
    await tester.ensureVisible(find.text('Temporary room lifetime'));
    expect(find.text('Temporary room lifetime'), findsOneWidget);
    await scrollStudioListUntilVisible(
      tester, 'batch3-voice-stage-list', find.text('Access preview'),
    );
    expect(find.text('Access preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Event templates generate a preview without publishing channels',
      (tester) async {
    addTearDown(() => resetView(tester));
    await pumpStudio(tester);
    await openStudioTab(tester, 'Event flow');

    expect(find.text('Approved event channel templates'), findsOneWidget);
    await scrollStudioListUntilVisible(
      tester, 'batch3-event-flow-list', find.text('Results & disputes'),
    );
    await tester.tap(find.text('Results & disputes'));
    await tester.pumpAndSettle();
    await scrollStudioListUntilVisible(
      tester, 'batch3-event-flow-list', find.text('Generate local preview'),
    );
    await tester.tap(find.text('Generate local preview'));
    await tester.pumpAndSettle();
    await scrollStudioListUntilVisible(
      tester, 'batch3-event-flow-list',
      find.text('Preview ready · nothing has been published or created.'),
    );
    expect(find.text('Preview ready · nothing has been published or created.'), findsOneWidget);
    expect(find.textContaining('NO PARTICIPANT OR CREDENTIAL AUTHORITY'), findsOneWidget);
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
    expect(find.text('Event context'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
