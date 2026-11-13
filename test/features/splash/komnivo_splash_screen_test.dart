import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komnivo/core/startup_coordinator.dart';
import 'package:komnivo/features/splash/komnivo_splash_screen.dart';

void main() {
  setUp(() {
    StartupCoordinator.ready.value = false;
    StartupCoordinator.error.value = null;
  });

  testWidgets('splash paints before animation and delays startup navigation', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: KomnivoSplashScreen(
          destination: Scaffold(body: Text('Destination')),
        ),
      ),
    );

    expect(StartupCoordinator.ready.value, isFalse);

    final logo = find
        .descendant(
          of: find.byType(AnimatedBuilder),
          matching: find.byType(Opacity),
        )
        .first;
    final initialOpacity = tester.widget<Opacity>(logo).opacity;

    // The intro must visibly animate after the first splash frame is painted.
    await tester.pump(const Duration(milliseconds: 250));
    final animatedOpacity = tester.widget<Opacity>(logo).opacity;
    expect(animatedOpacity, isNot(initialOpacity));
    expect(StartupCoordinator.ready.value, isFalse);

    // Startup begins only after the 2.7-second intro has completed.
    await tester.pump(const Duration(milliseconds: 2450));
    expect(StartupCoordinator.ready.value, isTrue);

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Destination'), findsOneWidget);
  });
}
