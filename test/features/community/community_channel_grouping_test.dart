import 'package:flutter_test/flutter_test.dart';
import 'package:komnivo/features/community/community_channel_grouping.dart';

void main() {
  test('event text and voice channels stay together under their own tournament categories', () {
    final groups = buildCommunityChannelGroups(
      categories: const [
        {'id': 'event-a', 'name': 'Free Fire Cup', 'position': 1},
        {'id': 'event-b', 'name': 'BGMI Open', 'position': 2},
      ],
      channels: const [
        {'id': 'a-text', 'name': 'announcements', 'kind': 'announcement', 'category_id': 'event-a'},
        {'id': 'a-voice', 'name': 'help-desk-voice', 'kind': 'voice', 'category_id': 'event-a'},
        {'id': 'a-forum', 'name': 'match-discussion', 'kind': 'forum', 'category_id': 'event-a'},
        {'id': 'b-text', 'name': 'announcements', 'kind': 'announcement', 'category_id': 'event-b'},
        {'id': 'b-voice', 'name': 'help-desk-voice', 'kind': 'voice', 'category_id': 'event-b'},
      ],
    );

    expect(groups.map((group) => group.title).toList(), ['Free Fire Cup', 'BGMI Open']);
    expect(groups[0].channels.map((row) => row['id']).toList(), ['a-text', 'a-voice', 'a-forum']);
    expect(groups[1].channels.map((row) => row['id']).toList(), ['b-text', 'b-voice']);
    expect(groups[0].channels.every((row) => row['category_id'] == 'event-a'), isTrue);
    expect(groups[1].channels.every((row) => row['category_id'] == 'event-b'), isTrue);
  });

  test('keeps unassigned channels separate and respects category/channel search', () {
    final categories = const [
      {'id': 'event-a', 'name': 'Free Fire Cup', 'position': 1},
      {'id': 'event-b', 'name': 'BGMI Open', 'position': 2},
    ];
    final channels = const [
      {'id': 'a-text', 'name': 'registration', 'description': 'Sign up', 'kind': 'text', 'category_id': 'event-a'},
      {'id': 'a-voice', 'name': 'support-voice', 'description': 'Talk to support', 'kind': 'voice', 'category_id': 'event-a'},
      {'id': 'b-text', 'name': 'announcements', 'description': 'Tournament updates', 'kind': 'announcement', 'category_id': 'event-b'},
      {'id': 'b-voice', 'name': 'match-voice', 'description': 'Tournament voice room', 'kind': 'voice', 'category_id': 'event-b'},
      {'id': 'general', 'name': 'general', 'description': 'Community chat', 'kind': 'text', 'category_id': null},
      {'id': 'unknown', 'name': 'misc', 'description': '', 'kind': 'text', 'category_id': 'missing-category'},
      {'id': 'archived', 'name': 'old-room', 'description': '', 'kind': 'text', 'category_id': 'archived-category'},
    ];

    final categorySearch = buildCommunityChannelGroups(
      categories: categories,
      channels: channels,
      query: 'Free Fire',
    );
    expect(categorySearch, hasLength(1));
    expect(categorySearch.single.title, 'Free Fire Cup');
    expect(categorySearch.single.channels.map((row) => row['id']).toList(), ['a-text', 'a-voice']);

    final voiceSearch = buildCommunityChannelGroups(
      categories: categories,
      channels: channels,
      query: 'support',
    );
    expect(voiceSearch, hasLength(1));
    expect(voiceSearch.single.title, 'Free Fire Cup');
    expect(voiceSearch.single.channels.single['id'], 'a-voice');

    final allGroups = buildCommunityChannelGroups(
      categories: [
        ...categories,
        {'id': 'archived-category', 'name': 'Old Tournament', 'position': 3, 'archived_at': '2026-11-22T00:00:00Z'},
      ],
      channels: channels,
    );
    expect(allGroups.map((group) => group.title).toList(), ['Free Fire Cup', 'BGMI Open', 'Uncategorized']);
    expect(allGroups.last.channels.map((row) => row['id']).toList(), ['general', 'unknown']);
  });

  test('uses the tournament channel priority as the initial fallback order', () {
    final groups = buildCommunityChannelGroups(
      categories: const [
        {'id': 'event', 'name': 'Tournament', 'position': 1},
      ],
      channels: const [
        {'id': 'staff', 'name': 'staff', 'category_id': 'event'},
        {'id': 'help-voice', 'name': 'help-desk-voice', 'category_id': 'event'},
        {'id': 'register-confirm', 'name': 'registration-confirmation', 'category_id': 'event'},
        {'id': 'results', 'name': 'results', 'category_id': 'event'},
        {'id': 'info', 'name': 'info', 'category_id': 'event'},
        {'id': 'updates', 'name': 'updates', 'category_id': 'event'},
        {'id': 'roadmap', 'name': 'roadmap', 'category_id': 'event'},
        {'id': 'schedule', 'name': 'schedule', 'category_id': 'event'},
        {'id': 'registration', 'name': 'registration', 'category_id': 'event'},
        {'id': 'test-registration', 'name': 'test-registration', 'category_id': 'event'},
        {'id': 'help-chat', 'name': 'help-desk', 'category_id': 'event'},
      ],
    );

    expect(
      groups.single.channels.map((row) => row['name']).toList(),
      [
        'info',
        'updates',
        'roadmap',
        'schedule',
        'results',
        'registration',
        'test-registration',
        'registration-confirmation',
        'help-desk',
        'help-desk-voice',
        'staff',
      ],
    );
  });

  test('respects saved organizer position before the default name order', () {
    final sorted = sortCommunityChannels(const [
      {'id': 'info', 'name': 'info', 'position': 2},
      {'id': 'updates', 'name': 'updates', 'position': 0},
      {'id': 'help', 'name': 'help-desk', 'position': 1},
    ]);
    expect(sorted.map((row) => row['name']).toList(), [
      'updates',
      'help-desk',
      'info',
    ]);
  });

}
