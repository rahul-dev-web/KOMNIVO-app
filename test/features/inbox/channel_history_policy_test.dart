import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/features/inbox/channel_history_policy.dart';

void main() {
  group('applyChannelHistoryPolicy', () {
    final messages = List<int>.generate(100, (index) => index);

    test('keeps the full history when retention is enabled', () {
      expect(
        applyChannelHistoryPolicy(
          messages,
          keepHistory: true,
          canManageMessages: false,
        ),
        messages,
      );
    });

    test('limits non-moderators to the newest 50 messages when disabled', () {
      final visible = applyChannelHistoryPolicy(
        messages,
        keepHistory: false,
        canManageMessages: false,
      );

      expect(visible, hasLength(50));
      expect(visible.first, 50);
      expect(visible.last, 99);
    });

    test('moderators retain full history when member history is limited', () {
      expect(
        applyChannelHistoryPolicy(
          messages,
          keepHistory: false,
          canManageMessages: true,
        ),
        messages,
      );
    });

    test('does not pad or truncate a short history', () {
      expect(
        applyChannelHistoryPolicy(
          [1, 2, 3],
          keepHistory: false,
          canManageMessages: false,
        ),
        [1, 2, 3],
      );
    });
  });
}
