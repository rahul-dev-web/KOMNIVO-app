import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/features/liveops/liveops_match_screen_classifier.dart';

void main() {
  group('LiveOpsMatchScreenClassifier', () {
    test('recognises the strict custom-room waiting Lobby signature', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'TEAM 1\\nINVITE FRIENDS\\nTEAM 2\\nSTART MATCH',
      );

      expect(result.kind, LiveOpsMatchScreenKind.lobby);
      expect(result.matchedSignals, hasLength(4));
    });

    test('does not mistake the main game home START button for the room Lobby', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'BR-RANKED\\nSTART\\nSTORE\\nVAULT\\nFRIENDS',
      );

      expect(result.kind, LiveOpsMatchScreenKind.unknown);
    });

    test('recognises the strict BR gameplay HUD signature', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'SAFE ZONE WILL SHRINK IN 01:21\\nEP 70/220\\nHP 200/200',
      );

      expect(result.kind, LiveOpsMatchScreenKind.matchInProgress);
      expect(result.matchedSignals, hasLength(3));
    });

    test('keeps gameplay Unknown when any HUD marker is missing', () {
      final noSafeZone = LiveOpsMatchScreenClassifier.classify(
        'EP 70/220\\nHP 200/200\\nALIVE 3\\nKILL 1',
      );
      final noHp = LiveOpsMatchScreenClassifier.classify(
        'SAFE ZONE WILL SHRINK IN 01:21\\nEP 70/220',
      );

      expect(noSafeZone.kind, LiveOpsMatchScreenKind.unknown);
      expect(noHp.kind, LiveOpsMatchScreenKind.unknown);
    });

    test('does not classify conflicting Lobby and Gameplay evidence', () {
      final result = LiveOpsMatchScreenClassifier.classify(
        'TEAM 1\\nINVITE FRIENDS\\nTEAM 2\\nSTART MATCH\\n'
        'SAFE ZONE WILL SHRINK IN 01:21\\nEP 70/220\\nHP 200/200',
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
    });

    test('Unknown OCR resets a pending streak', () {
      final observer = LiveOpsStableScreenObserver();
      observer.observe(LiveOpsMatchScreenKind.lobby, start);
      observer.observe(
        LiveOpsMatchScreenKind.lobby,
        start.add(const Duration(seconds: 1)),
      );

      expect(
        observer.observe(
          LiveOpsMatchScreenKind.unknown,
          start.add(const Duration(seconds: 2)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(observer.pendingCount, 0);
      expect(
        observer.observe(
          LiveOpsMatchScreenKind.lobby,
          start.add(const Duration(seconds: 3)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
    });

    test('a different screen candidate starts a fresh streak', () {
      final observer = LiveOpsStableScreenObserver();
      observer.observe(LiveOpsMatchScreenKind.lobby, start);
      observer.observe(
        LiveOpsMatchScreenKind.lobby,
        start.add(const Duration(seconds: 1)),
      );

      expect(
        observer.observe(
          LiveOpsMatchScreenKind.matchInProgress,
          start.add(const Duration(seconds: 2)),
        ),
        LiveOpsMatchScreenKind.unknown,
      );
      expect(observer.pendingKind, LiveOpsMatchScreenKind.matchInProgress);
      expect(observer.pendingCount, 1);
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
