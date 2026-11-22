/// Conservative parser for the supported Free Fire MAX custom-room OCR layout.
/// The parser only groups text that follows visible TEAM n headings; it does not
/// infer players from arbitrary screen text.
class LiveOpsRosterOcrParser {
  const LiveOpsRosterOcrParser._();

  static final RegExp _slotMarker =
      RegExp(r'\bTEAM\s*#?\s*(\d{1,2})\b', caseSensitive: false);

  static const Set<String> _boundaries = <String>{
    'startmatch',
    'invitefriends',
    'invite',
    'spectate',
    'observe',
    'back',
    'exit',
    'cancel',
    'customroom',
    'freefire',
    'players',
    'friends',
    'roomid',
    'password',
  };

  static Map<int, List<String>> readSlots(String rawText) {
    final result = <int, List<String>>{};
    int? activeSlot;

    for (final rawLine in rawText.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final marker = _slotMarker.firstMatch(line);
      if (marker != null) {
        activeSlot = int.tryParse(marker.group(1) ?? '');
        if (activeSlot != null) {
          result.putIfAbsent(activeSlot, () => <String>[]);
        }
        final remainder = withoutVisibleUid(line.substring(marker.end)).trim();
        if (activeSlot != null && looksLikePlayerName(remainder)) {
          result[activeSlot]!.add(remainder);
        }
        continue;
      }

      if (_boundaries.contains(normalise(line))) {
        activeSlot = null;
        continue;
      }

      if (activeSlot != null) {
        final playerLine = withoutVisibleUid(line).trim();
        if (looksLikePlayerName(playerLine)) {
          final rows = result.putIfAbsent(activeSlot, () => <String>[]);
          final canonical = normalise(playerLine);
          if (!rows.any((value) => normalise(value) == canonical)) {
            rows.add(playerLine);
          }
        }
      }
    }

    return result;
  }

  static Map<int, List<String>> readSlotUids(String rawText) {
    final result = <int, List<String>>{};
    int? activeSlot;
    final uidPattern = RegExp(r'\b\d{5,15}\b');

    for (final rawLine in rawText.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final marker = _slotMarker.firstMatch(line);
      if (marker != null) {
        activeSlot = int.tryParse(marker.group(1) ?? '');
        if (activeSlot != null) result.putIfAbsent(activeSlot, () => <String>[]);
        final remainder = line.substring(marker.end);
        if (activeSlot != null) {
          final rows = result[activeSlot]!;
          for (final match in uidPattern.allMatches(remainder)) {
            final value = match.group(0)!;
            if (!rows.contains(value)) rows.add(value);
          }
        }
        continue;
      }
      if (_boundaries.contains(normalise(line))) {
        activeSlot = null;
        continue;
      }
      if (activeSlot != null) {
        final rows = result.putIfAbsent(activeSlot, () => <String>[]);
        for (final match in uidPattern.allMatches(line)) {
          final value = match.group(0)!;
          if (!rows.contains(value)) rows.add(value);
        }
      }
    }
    return result;
  }

  static List<int> slotsForExactUid(
    Map<int, List<String>> slots,
    String expectedUid,
  ) {
    final expected = expectedUid.trim();
    if (expected.isEmpty) return const <int>[];
    return slots.entries
        .where((entry) => entry.value.contains(expected))
        .map((entry) => entry.key)
        .toList(growable: false);
  }

  static String withoutVisibleUid(String value) =>
      value.replaceAll(RegExp(r'\b\d{5,15}\b'), ' ');
  static String normalise(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();

  static bool looksLikePlayerName(String line) {
    final value = line.trim();
    if (value.length < 3 ||
        value.length > 28 ||
        _boundaries.contains(normalise(value)) ||
        RegExp(r'^\d+$').hasMatch(value) ||
        RegExp(r'^TEAM\s*#?\s*\d+$', caseSensitive: false).hasMatch(value)) {
      return false;
    }
    return value.runes.any((rune) =>
        (rune >= 48 && rune <= 57) ||
        (rune >= 65 && rune <= 90) ||
        (rune >= 97 && rune <= 122) ||
        rune > 127);
  }

  static List<int> slotsForExactName(
    Map<int, List<String>> slots,
    String expectedName,
  ) {
    final expected = normalise(expectedName);
    if (expected.isEmpty) return const <int>[];
    return slots.entries
        .where((entry) =>
            entry.value.any((name) => normalise(name) == expected))
        .map((entry) => entry.key)
        .toList(growable: false);
  }
}
