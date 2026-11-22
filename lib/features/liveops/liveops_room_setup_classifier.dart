/// Conservative, local-only recogniser for the English Free Fire custom-room
/// creation form. It deliberately recognises only the full three-marker signature;
/// partial OCR, translated UI, join-room screens and conflicting cues stay Unknown.
class LiveOpsRoomSetupClassification {
  const LiveOpsRoomSetupClassification({
    required this.matchedSignals,
    required this.conflictingSignals,
  });

  final List<String> matchedSignals;
  final List<String> conflictingSignals;

  static const int requiredSignalCount = 3;

  int get matchedSignalCount => matchedSignals.length;

  bool get hasConflictingSignal => conflictingSignals.isNotEmpty;

  bool get isRoomSetup =>
      matchedSignalCount == requiredSignalCount && !hasConflictingSignal;
}

class LiveOpsRoomSetupClassifier {
  const LiveOpsRoomSetupClassifier._();

  // These are structural labels from the English custom-room creation form:
  // Room Name + Password fields and the final Confirm action.
  // Do not weaken this to generic words such as "room", "password" or "start".
  static const List<String> _requiredSignals = <String>[
    'ROOM NAME',
    'PASSWORD',
    'CONFIRM',
  ];

  // A join/search flow is not the room-creation form. Treat these cues as
  // conflicts even if OCR happens to capture other matching words nearby.
  static const List<String> _conflictingSignals = <String>[
    'ENTER ROOM ID',
    'CLICK TO ENTER ROOM ID',
    'JOIN ROOM',
  ];

  static LiveOpsRoomSetupClassification classify(String rawOcrText) {
    final normalized = rawOcrText
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    bool containsPhrase(String phrase) {
      return ' $normalized '.contains(' $phrase ');
    }

    final matched = _requiredSignals
        .where(containsPhrase)
        .toList(growable: false);
    final conflicting = _conflictingSignals
        .where(containsPhrase)
        .toList(growable: false);

    return LiveOpsRoomSetupClassification(
      matchedSignals: matched,
      conflictingSignals: conflicting,
    );
  }
}
