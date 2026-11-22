import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/features/liveops/liveops_room_setup_classifier.dart';

void main() {
  test('recognises the full English Room Setup signature', () {
    final result = LiveOpsRoomSetupClassifier.classify(
      'ROOM NAME\nPASSWORD\nBATTLE ROYALE\nMAP\nCONFIRM',
    );

    expect(result.isRoomSetup, isTrue);
    expect(result.matchedSignalCount, 3);
    expect(result.hasConflictingSignal, isFalse);
  });

  test('keeps partial OCR Unknown when Confirm is missing', () {
    final result = LiveOpsRoomSetupClassifier.classify(
      'Room Name\nPassword\nBattle Royale',
    );

    expect(result.isRoomSetup, isFalse);
    expect(result.matchedSignalCount, 2);
  });

  test('does not classify a room search or join screen as Room Setup', () {
    final result = LiveOpsRoomSetupClassifier.classify(
      'Click to enter Room ID\nPassword\nJoin Room',
    );

    expect(result.isRoomSetup, isFalse);
    expect(result.hasConflictingSignal, isTrue);
  });

  test('conflicting join cues override a complete marker signature', () {
    final result = LiveOpsRoomSetupClassifier.classify(
      'Room Name\nPassword\nConfirm\nEnter Room ID',
    );

    expect(result.isRoomSetup, isFalse);
    expect(result.matchedSignalCount, 3);
    expect(result.hasConflictingSignal, isTrue);
  });

  test('normalises case and line spacing without broad substring matches', () {
    final positive = LiveOpsRoomSetupClassifier.classify(
      '  room   name  \n password \n confirm ',
    );
    final negative = LiveOpsRoomSetupClassifier.classify(
      'ROOM NAMES PASSWORD CONFIRMATION',
    );

    expect(positive.isRoomSetup, isTrue);
    expect(negative.isRoomSetup, isFalse);
  });
}
