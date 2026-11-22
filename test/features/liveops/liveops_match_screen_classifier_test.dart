import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/features/liveops/liveops_match_screen_classifier.dart';

void main() {
  group('LiveOpsMatchScreenClassifier', () {
    test('recognises the strict custom-room waiting Lobby signature', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'TEAM 1\nINVITE FRIENDS\nTEAM 2\nSTART MATCH',
      );

      expect(result.kind, LiveOpsMatchScreenKind.lobby);
      expect(result.matchedSignals, hasLength(4));
    });

    test('does not mistake the main game home START button for the room Lobby', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'BR-RANKED\nSTART\nSTORE\nVAULT\nFRIENDS',
      );

      expect(result.kind, LiveOpsMatchScreenKind.unknown);
    });

    test('recognises the strict BR gameplay HUD signature', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'SAFE ZONE WILL SHRINK IN 01:21\nEP 70/220\nHP 200/200',
      );

      expect(result.kind, LiveOpsMatchScreenKind.matchInProgress);
      expect(result.matchedSignals, hasLength(3));
    });

    test('keeps gameplay Unknown when any HUD marker is missing', () {
      final noSafeZone = LiveOpsMatchScreenClassifier.classify(
        'EP 70/220\nHP 200/200\nALIVE 3\nKILL 1',
      );
      final noHp = LiveOpsMatchScreenClassifier.classify(
        'SAFE ZONE WILL SHRINK IN 01:21\nEP 70/220',
      );

      expect(noSafeZone.kind, LiveOpsMatchScreenKind.unknown);
      expect(noHp.kind, LiveOpsMatchScreenKind.unknown);
    });


    test('recognises a Booyah result summary with a player-stat table', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'BOOYAH\\nNAME\\nK\\nDMG\\nPLAY AGAIN',
      );

      expect(result.kind, LiveOpsMatchScreenKind.resultScreen);
      expect(result.matchedSignals, containsAll(<String>['BOOYAH', 'NAME', 'K', 'DMG']));
    });

    test('recognises a defeat result summary with explicit result metrics', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'DEFEAT\\nRESULTS\\nNAME\\nKILLS\\nDAMAGE',
      );

      expect(result.kind, LiveOpsMatchScreenKind.resultScreen);
    });

    test('keeps outcome animation and partial result OCR Unknown', () {
      final outcomeOnly = LiveOpsMatchScreenClassifier.classify('BOOYAH');
      final oneMetric = LiveOpsMatchScreenClassifier.classify(
        'DEFEAT\\nNAME\\nKILLS',
      );

      expect(outcomeOnly.kind, LiveOpsMatchScreenKind.unknown);
      expect(oneMetric.kind, LiveOpsMatchScreenKind.unknown);
    });

    test('does not classify conflicting active-screen and result markers', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'BOOYAH\\nNAME\\nK\\nDMG\\n'
        'SAFE ZONE WILL SHRINK IN 01:21\\nEP 70/220\\nHP 200/200',
      );

      expect(result.kind, LiveOpsMatchScreenKind.unknown);
      expect(result.reason, contains('Conflicting'));
    });

    test('does not classify conflicting Lobby and Gameplay evidence', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'TEAM 1\nINVITE FRIENDS\nTEAM 2\nSTART MATCH\n'
        'SAFE ZONE WILL SHRINK IN 01:21\nEP 70/220\nHP 200/200',
      );

      expect(result.kind, LiveOpsMatchScreenKind.unknown);
      expect(result.reason, contains('Conflicting'));
    });
  });

  group('LiveOpsStableScreenObserver', () {
    final start = DateTime(2026, 11, 22, 10);

    test('requires three consecutive observations before confirming a state', () {
      final observer = LiveOpsStableScreenObserver();

      expect(
        observer.observe(LiveOpsMatchScreenKind.lobby, start),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(const Duration(seconds: 1)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(const Duration(seconds: 2)),
        ),
        LiveOpsMatchScreenKind.lobby,
      );
      expect(observer.stableKind, LiveOpsMatchScreenKind.lobby);
    });


    test('requires three consecutive result-screen observations', () {
      final observer = LiveOpsStableScreenObserver();

      expect(
        observer.observe(LiveOpsMatchScreenKind.resultScreen, start),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.resultScreen,
          start.add(const Duration(seconds: 1)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.resultScreen,
          start.add(const Duration(seconds: 2)),
        ),
        LiveOpsMatchScreenKind.resultScreen,
      );
    });

    test('holds the prior state through brief Unknown OCR and then falls back', () {
      final observer = LiveOpsStableScreenObserver();
      for (var second = 0; second < 3; second++) {
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(Duration(seconds: second)),
        );
      }

      expect(
        observer.observe(
          LiveOpsMatchScreenKind.unknown,
          start.add(const Duration(seconds: 3)),
        ),
        LiveOpsMatchScreenKind.lobby,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.unknown,
          start.add(const Duration(seconds: 4)),
        ),
        LiveOpsMatchScreenKind.lobby,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.unknown,
          start.add(const Duration(seconds: 5)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(observer.stableKind, LiveOpsMatchScreenKind.unknown);
    });

    test('keeps the prior state until a different state is stable', () {
      final observer = LiveOpsStableScreenObserver();
      for (var second = 0; second < 3; second++) {
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(Duration(seconds: second)),
        );
      }

      expect(
        observer.observe(
          LiveOpsMatchScreenKind.matchInProgress,
          start.add(const Duration(seconds: 3)),
        ),
        LiveOpsMatchScreenKind.lobby,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.matchInProgress,
          start.add(const Duration(seconds: 4)),
        ),
        LiveOpsMatchScreenKind.lobby,
      );
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.matchInProgress,
          start.add(const Duration(seconds: 5)),
        ),
        LiveOpsMatchScreenKind.matchInProgress,
      );
    });

    test('a stale gap expires the previously confirmed screen state', () {
      final observer = LiveOpsStableScreenObserver();
      for (var second = 0; second < 3; second++) {
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(Duration(seconds: second)),
        );
      }
      expect(observer.stableKind, LiveOpsMatchScreenKind.lobby);

      expect(
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(const Duration(seconds: 6)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(observer.pendingCount, 1);
      expect(observer.stableKind, LiveOpsMatchScreenKind.unknown);
    });

    test('a stale observation gap resets the stability streak', () {
      final observer = LiveOpsStableScreenObserver();
      observer.observe(LiveOpsMatchScreenKind.lobby, start);
      observer.observe(
        LiveOpsMatchScreenKind.lobby,
        start.add(const Duration(seconds: 1)),
      );

      expect(
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(const Duration(seconds: 5)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(observer.pendingCount, 1);
    });
  });
}
