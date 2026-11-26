import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';
import 'package:komnivo/features/shell/app_shell.dart';
import 'package:komnivo/features/ai/tournament_form_card.dart';
import 'package:komnivo/features/ai/ai_assistant_screen.dart';

Future<void> _pumpKOMNIVO(WidgetTester tester) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: KomnivoTheme.dark.copyWith(platform: TargetPlatform.android),
      navigatorObservers: [AppShellBackObserver()],
      home: const AppShell(preview: true),
    ),
  );
  await tester.pumpAndSettle();
}

void _resetTestView(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  test('KOMNIVO theme uses a dark visual system', () {
    expect(KomnivoTheme.dark.brightness, Brightness.dark);
    expect(KomnivoTheme.background, isNotNull);
  });

  test('Tournament form serializes the selected time as India Standard Time', () {
    expect(
      formatKOMNIVOIstTimestamp(
        DateTime(2026, 11, 19),
        const TimeOfDay(hour: 9, minute: 0),
      ),
      '2026-11-19T09:00:00+05:30',
    );
    expect(
      formatKOMNIVOIstTimestamp(
        DateTime(2026, 11, 18),
        const TimeOfDay(hour: 11, minute: 0),
      ),
      '2026-11-18T11:00:00+05:30',
    );
  });

  test('Tournament form validates stage count and optional stage names', () {
    expect(validateTournamentStageCount('1'), isNull);
    expect(validateTournamentStageCount('16'), isNull);
    expect(validateTournamentStageCount('0'), isNotNull);
    expect(validateTournamentStageCount('17'), isNotNull);
    expect(validateTournamentStageCount('abc'), isNotNull);

    expect(parseTournamentStageNames('', 3), isEmpty);
    expect(parseTournamentStageNames('Qualifier\nSemi Final\nFinal', 3),
      ['Qualifier', 'Semi Final', 'Final']);
    expect(() => parseTournamentStageNames('Qualifier\nFinal', 3),
      throwsFormatException);
    expect(() => parseTournamentStageNames('Qualifier\nqualifier', 2),
      throwsFormatException);
    expect(() => parseTournamentStageNames('${'x' * 61}', 1),
      throwsFormatException);
  });

  testWidgets('Organizer AI quick actions are visible and open their actions',
      (tester) async {
    var tournamentTapped = false;
    var draftsTapped = false;
    var paidScrimTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: KomnivoTheme.dark,
        home: Scaffold(
          body: OrganizerChatActions(
            tournamentEnabled: true,
            paidScrimEnabled: true,
            draftsEnabled: true,
            onCreateTournament: () => tournamentTapped = true,
            onViewDrafts: () => draftsTapped = true,
            onCreatePaidScrim: () => paidScrimTapped = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('organizer-chat-actions-panel')), findsOneWidget);
    expect(find.text('Create Tournament'), findsOneWidget);
    expect(find.text('View Drafts'), findsOneWidget);
    expect(find.text('Create Paid Scrim'), findsOneWidget);

    await tester.tap(find.byKey(const Key('organizer-create-tournament')));
    await tester.tap(find.byKey(const Key('organizer-view-tournament-drafts')));
    await tester.tap(find.byKey(const Key('organizer-create-paid-scrim')));

    expect(tournamentTapped, isTrue);
    expect(draftsTapped, isTrue);
    expect(paidScrimTapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Five core destinations use the approved order and Community home',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    final navigationBar = find.byType(NavigationBar);
    expect(navigationBar, findsOneWidget);
    final destinations = find.descendant(
      of: navigationBar,
      matching: find.byType(NavigationDestination),
    );
    final labels = tester
        .widgetList<NavigationDestination>(destinations)
        .map((destination) => destination.label)
        .toList();

    expect(labels, ['Community', 'Compete', 'Store', 'Team', 'DM']);
    expect(tester.widget<NavigationBar>(navigationBar).selectedIndex, 0);
  });

  testWidgets('Android Back from a main tab returns to Community', (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.tap(find.text('Store'));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android Back from a detail route returns directly to Community',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();
    final shellContext = tester.element(find.byType(AppShell));
    Navigator.of(shellContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('Player details'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Player details'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Player details'), findsNothing);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android Back on Community asks before closing the app',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Exit KOMNIVO?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Exit KOMNIVO?'), findsNothing);
  });

  testWidgets('Store landing shows New in Store and full category names',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.tap(find.text('Store'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Store landing should fit a 430px mobile viewport.');

    expect(find.text('New in Store'), findsOneWidget);
    for (final category in [
      'Assets',
      'Artists',
      'Players',
      'Coaches',
      'Orgs',
      'Management Team',
    ]) {
      expect(find.text(category), findsOneWidget);
    }
    expect(find.byTooltip('Add to Store'), findsOneWidget);
  });

  testWidgets('Selecting a Store category hides the sidebar and opens listings',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.tap(find.text('Store'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Store landing should render before category navigation.');

    await tester.tap(find.text('Players').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Player listings should fit the full-width Store detail view.');

    expect(find.byTooltip('Back to Store categories'), findsOneWidget);
    expect(find.text('Assets'), findsNothing);
    expect(find.text('Players'), findsOneWidget);
    expect(find.text('RAVEN'), findsOneWidget);
    expect(find.text('KAI'), findsOneWidget);
  });

  testWidgets('Compete is a promotion hub and saves a local promotion draft',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.tap(find.text('Compete'));
    await tester.pumpAndSettle();

    expect(find.text('PROMOTION HUB'), findsOneWidget);
    expect(find.text('No open events'), findsNothing);
    expect(find.text('What do you want to promote?'), findsOneWidget);

    await tester.tap(find.text('Create promotion'));
    await tester.pumpAndSettle();
    expect(find.text('Create a promotion'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('promotion-title-field')),
      'Friday Night Scrims',
    );
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();

    expect(find.text('Friday Night Scrims'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('No open events'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DM destination shows private user conversations without community voice rooms',
      (tester) async {
    addTearDown(() => _resetTestView(tester));
    await _pumpKOMNIVO(tester);

    await tester.tap(find.text('DM'));
    await tester.pumpAndSettle();

    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Nova'), findsOneWidget);
    expect(find.text('Rank Push Trio'), findsOneWidget);
    expect(find.text('Night Owls Gaming'), findsNothing);
    expect(find.text('Voice room'), findsNothing);
    expect(find.text('Join voice room'), findsNothing);
    expect(tester.takeException(), isNull);
  });

}
