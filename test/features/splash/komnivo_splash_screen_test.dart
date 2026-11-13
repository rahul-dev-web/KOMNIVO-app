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
          firstFrameReadyForTest: () async {},
        ),
      ),
    );

    expect(StartupCoordinator.ready.value, isFalse);

    // Prime the ticker's first timestamp after the post-frame animation start.
    await tester.pump();

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

    // Allow the full intro plus the first scheduled ticker frame. The exact
    // ticker epoch is established on the next frame after forward() is called.
    await tester.pump(const Duration(milliseconds: 3000));
    expect(StartupCoordinator.ready.value, isTrue);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Destination'), findsOneWidget);
  });
}
