import 'package:flutter_test/flutter_test.dart';
import 'package:komnivo/features/liveops/liveops_roster_matcher.dart';

void main() {
  group('LiveOpsRosterOcrParser', () {
    test('groups player names under their visible TEAM slot headings', () {
      final slots = LiveOpsRosterOcrParser.readSlots(
        'TEAM 1\nIGL RAHUL\nMVP LEO\nTEAM 2\nPLAYER THREE\nSTART MATCH',
      );

      expect(slots[1], <String>['IGL RAHUL', 'MVP LEO']);
      expect(slots[2], <String>['PLAYER THREE']);
      expect(slots.containsKey(3), isFalse);
    });

    test('supports a player name on the same OCR line as the slot marker', () {
      final slots = LiveOpsRosterOcrParser.readSlots(
        'TEAM 3 WOLF\nTEAM 4\nNOVA',
      );

      expect(slots[3], <String>['WOLF']);
      expect(slots[4], <String>['NOVA']);
    });

    test('does not treat lobby controls or bare numbers as players', () {
      final slots = LiveOpsRosterOcrParser.readSlots(
        'TEAM 1\nSTART MATCH\n123456\nINVITE FRIENDS\nTEAM 2\nNOVA',
      );

      expect(slots[1], isEmpty);
      expect(slots[2], <String>['NOVA']);
    });

    test('keeps Unicode and punctuation in player identity comparisons', () {
      final slots = <int, List<String>>{
        1: <String>['IGL☆RÄHUL'],
        2: <String>['MVP LEO'],
      };

      expect(
        LiveOpsRosterOcrParser.slotsForExactName(slots, 'igl☆rähul'),
        <int>[1],
      );
      expect(
        LiveOpsRosterOcrParser.slotsForExactName(slots, 'IGL RAH'),
        isEmpty,
      );
    });

    test('keeps nickname text separate when OCR reads a UID on the same row', () {
      const ocr = 'TEAM 1\nNOVA 123456789\nTEAM 2\nWOLF 987654321';
      final names = LiveOpsRosterOcrParser.readSlots(ocr);
      final uids = LiveOpsRosterOcrParser.readSlotUids(ocr);

      expect(names[1], <String>['NOVA']);
      expect(names[2], <String>['WOLF']);
      expect(uids[1], <String>['123456789']);
      expect(uids[2], <String>['987654321']);
    });

    test('pairs a visible nickname with its exact UID within the same slot', () {
      const ocr = 'TEAM 1\nNOVA 123456789\nTEAM 2\nWOLF 987654321';
      final pairs = LiveOpsRosterOcrParser.readNamesPairedWithUids(ocr);

      expect(pairs[1]?['nova'], '123456789');
      expect(pairs[2]?['wolf'], '987654321');
      expect(pairs[1]?.containsKey('wolf'), isFalse);
    });

    test('extracts visible numeric UIDs and matches them exactly by slot', () {
      final ocr = 'TEAM 1\nIGL RAHUL 123456789\nTEAM 2\nNOVA 987654321';
      final slots = LiveOpsRosterOcrParser.readSlotUids(ocr);

      expect(slots[1], <String>['123456789']);
      expect(slots[2], <String>['987654321']);
      expect(
        LiveOpsRosterOcrParser.slotsForExactUid(slots, '123456789'),
        <int>[1],
      );
      expect(
        LiveOpsRosterOcrParser.slotsForExactUid(slots, '12345678'),
        isEmpty,
      );
    });

    test('deduplicates repeated identical OCR lines within one slot only', () {
      final slots = LiveOpsRosterOcrParser.readSlots(
        'TEAM 1\nNOVA\nNOVA\nTEAM 2\nNOVA',
      );

      expect(slots[1], <String>['NOVA']);
      expect(slots[2], <String>['NOVA']);
      expect(
        LiveOpsRosterOcrParser.slotsForExactName(slots, 'NOVA'),
        <int>[1, 2],
      );
    });
  });
}
