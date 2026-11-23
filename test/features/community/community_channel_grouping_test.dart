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
}
