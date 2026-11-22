/// Strict, local-only screen classifier for supported English Free Fire MAX
/// custom-room waiting screens and BR gameplay HUD. Unsupported modes/layouts
/// remain Unknown until verified fixtures are added.
enum LiveOpsMatchScreenKind {
  unknown,
  lobby,
  matchInProgress,
  resultScreen,
}

class LiveOpsMatchScreenClassification {
  const LiveOpsMatchScreenClassification({
    required this.kind,
    required this.matchedSignals,
    required this.reason,
  });

  final LiveOpsMatchScreenKind kind;
  final List<String> matchedSignals;
  final String reason;

  bool get isClassified => kind != LiveOpsMatchScreenKind.unknown;
}

class LiveOpsMatchScreenClassifier {
  const LiveOpsMatchScreenClassifier._();

  static const List<String> _lobbyMarkers = <String>[
    'START MATCH',
    'INVITE FRIENDS',
    'TEAM 1',
    'TEAM 2',
  ];

  static final RegExp _hpValue = RegExp(r'\bHP\s*\d{1,4}\s*/\s*\d{1,4}\b');
  static final RegExp _epValue = RegExp(r'\bEP\s*\d{1,4}\s*/\s*\d{1,4}\b');

  // Supported post-match summaries expose an outcome heading and a player
  // table. Require NAME plus at least two distinct stat headers; outcome text
  // alone (including the Booyah animation) is deliberately insufficient.
  static const List<String> _resultOutcomes = <String>['BOOYAH', 'DEFEAT'];
  static const List<String> _resultStatMarkers = <String>[
    'KILLS',
    'K',
    'DAMAGE',
    'DMG',
    'ASSISTS',
    'KNOCKDOWNS',
    'REVIVES',
    'HEAL',
    'RANK',
    'PLACEMENT',
  ];

  static LiveOpsMatchScreenClassification classify(String rawOcrText) {
    final normalized = rawOcrText
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9/]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    bool containsPhrase(String phrase) =>
        ' $normalized '.contains(' $phrase ');

    final lobbySignals = _lobbyMarkers
        .where(containsPhrase)
        .toList(growable: false);
    final hasLobbySignature = lobbySignals.length == _lobbyMarkers.length;

    final hasSafeZone = containsPhrase('SAFE ZONE WILL SHRINK');
    final hasHp = _hpValue.hasMatch(normalized);
    final hasEp = _epValue.hasMatch(normalized);
    final gameplaySignals = <String>[
      if (hasSafeZone) 'SAFE ZONE WILL SHRINK',
      if (hasHp) 'HP numeric HUD value',
      if (hasEp) 'EP numeric HUD value',
    ];

    final hasGameplaySignature = hasSafeZone && hasHp && hasEp;

    final resultOutcomes = _resultOutcomes.where(containsPhrase).toList(growable: false);
    final resultStatSignals = _resultStatMarkers.where(containsPhrase).toSet();
    final hasResultSignature = resultOutcomes.length == 1 &&
        containsPhrase('NAME') && resultStatSignals.length >= 2;

    if (hasLobbySignature && hasGameplaySignature) {
      return const LiveOpsMatchScreenClassification(
        kind: LiveOpsMatchScreenKind.unknown,
        matchedSignals: <String>[],
        reason: 'Conflicting Lobby and Gameplay markers',
      );
    }

    if (hasResultSignature && (hasLobbySignature || hasGameplaySignature)) {
      return LiveOpsMatchScreenClassification(
        kind: LiveOpsMatchScreenKind.unknown,
        matchedSignals: <String>[...resultOutcomes, 'NAME', ...resultStatSignals],
        reason: 'Conflicting Result and active-screen markers',
      );
    }

    if (hasResultSignature) {
      return LiveOpsMatchScreenClassification(
        kind: LiveOpsMatchScreenKind.resultScreen,
        matchedSignals: <String>[...resultOutcomes, 'NAME', ...resultStatSignals],
        reason: 'Strict post-match outcome and player-stat summary signature',
      );
    }

    if (hasGameplaySignature) {
      return LiveOpsMatchScreenClassification(
        kind: LiveOpsMatchScreenKind.matchInProgress,
        matchedSignals: gameplaySignals,
        reason: 'Strict BR gameplay HUD signature',
      );
    }

    if (hasLobbySignature) {
      return LiveOpsMatchScreenClassification(
        kind: LiveOpsMatchScreenKind.lobby,
        matchedSignals: lobbySignals,
        reason: 'Strict custom-room waiting Lobby signature',
      );
    }

    return LiveOpsMatchScreenClassification(
      kind: LiveOpsMatchScreenKind.unknown,
      matchedSignals: <String>[
        ...lobbySignals,
        ...gameplaySignals,
        ...resultOutcomes,
        if (containsPhrase('NAME')) 'NAME',
        ...resultStatSignals,
      ],
      reason: 'Minimum supported screen markers are absent',
    );
  }
}

/// Requires three consecutive, same-kind classified OCR observations. A gap
/// over 2.5 seconds, a different candidate, or an Unknown observation resets
/// the pending streak. Native capture currently samples about once per second.
class LiveOpsStableScreenObserver {
  LiveOpsStableScreenObserver({
    this.requiredObservations = 3,
    this.maximumGap = const Duration(milliseconds: 2500),
  }) : assert(requiredObservations >= 2);

  final int requiredObservations;
  final Duration maximumGap;

  LiveOpsMatchScreenKind _stableKind = LiveOpsMatchScreenKind.unknown;
  LiveOpsMatchScreenKind _pendingKind = LiveOpsMatchScreenKind.unknown;
  DateTime? _previousAt;
  int _pendingCount = 0;

  LiveOpsMatchScreenKind get stableKind => _stableKind;
  int get pendingCount => _pendingCount;
  LiveOpsMatchScreenKind get pendingKind => _pendingKind;

  void reset() {
    _stableKind = LiveOpsMatchScreenKind.unknown;
    _pendingKind = LiveOpsMatchScreenKind.unknown;
    _previousAt = null;
    _pendingCount = 0;
  }

  LiveOpsMatchScreenKind observe(
    LiveOpsMatchScreenKind candidate,
    DateTime observedAt,
  ) {
    final previousAt = _previousAt;
    final gap = previousAt == null ? null : observedAt.difference(previousAt);
    if (gap != null && (gap.isNegative || gap > maximumGap)) {
      // A stale observation window cannot keep an old state alive.
      _stableKind = LiveOpsMatchScreenKind.unknown;
      _pendingKind = LiveOpsMatchScreenKind.unknown;
      _pendingCount = 0;
    }

    if (candidate == _stableKind) {
      _pendingKind = LiveOpsMatchScreenKind.unknown;
      _pendingCount = 0;
      _previousAt = observedAt;
      return _stableKind;
    }

    final startsNewStreak = _pendingKind != candidate || gap == null;
    if (startsNewStreak) {
      _pendingKind = candidate;
      _pendingCount = 1;
    } else {
      _pendingCount++;
    }
    _previousAt = observedAt;

    if (_pendingCount >= requiredObservations) {
      _stableKind = candidate;
      _pendingKind = LiveOpsMatchScreenKind.unknown;
      _pendingCount = 0;
    }
    // Keep the last confirmed state during a short transition/flicker window.
    // At startup that state is Unknown, so one transient candidate cannot
    // produce a premature Lobby or Gameplay label.
    return _stableKind;
  }
}
