import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';
import 'package:komnivo/features/shell/app_shell.dart';

void main() {
  test('KOMNIVO theme uses a dark visual system', () {
    expect(KomnivoTheme.dark.brightness, Brightness.dark);
    expect(KomnivoTheme.background, isNotNull);
  });

  testWidgets('Four core destinations use the approved order and Community home',
      (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: KomnivoTheme.dark,
        home: const AppShell(preview: true),
      ),
    );
    await tester.pumpAndSettle();

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

    expect(labels, ['Community', 'Compete', 'Team', 'DM']);
    expect(tester.widget<NavigationBar>(navigationBar).selectedIndex, 0);
  });
}
