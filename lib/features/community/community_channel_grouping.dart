const Map<String, int> _defaultCommunityChannelOrder = <String, int>{
  'info': 0, 'updates': 1, 'roadmap': 2, 'schedule': 3, 'results': 4,
  'registration': 5, 'test-registration': 6,
  'registration-confirmation': 7, 'help-desk': 8,
  'help-desk-voice': 9, 'staff': 10,
};

/// Sort channels by persisted organizer position, using tournament priority as fallback.
List<Map<String, dynamic>> sortCommunityChannels(Iterable<Map<String, dynamic>> channels) {
  final rows = channels.toList();
  final applyDefaultPriority = rows.any(
    (channel) => channel['name']?.toString().toLowerCase() == 'info',
  );
  final indexed = <({Map<String, dynamic> channel, int originalIndex})>[];
  for (var originalIndex = 0; originalIndex < rows.length; originalIndex++) {
    indexed.add((channel: rows[originalIndex], originalIndex: originalIndex));
  }
  indexed.sort((left, right) {
    final lp = int.tryParse(left.channel['position']?.toString() ?? '');
    final rp = int.tryParse(right.channel['position']?.toString() ?? '');
    if (lp != null && rp != null && lp != rp) return lp.compareTo(rp);
    final ln = left.channel['name']?.toString().toLowerCase() ?? '';
    final rn = right.channel['name']?.toString().toLowerCase() ?? '';
    final leftPriority = applyDefaultPriority
        ? (_defaultCommunityChannelOrder[ln] ?? 1000)
        : 1000;
    final rightPriority = applyDefaultPriority
        ? (_defaultCommunityChannelOrder[rn] ?? 1000)
        : 1000;
    final priority = leftPriority.compareTo(rightPriority);
    return priority != 0 ? priority : left.originalIndex.compareTo(right.originalIndex);
  });
  return indexed.map((entry) => entry.channel).toList();
}
class CommunityChannelGroup {
  const CommunityChannelGroup({
    required this.categoryId,
    required this.title,
    required this.channels,
  });

  final String? categoryId;
  final String title;
  final List<Map<String, dynamic>> channels;
}

/// Groups channels by their saved channel_categories.id relationship.
///
/// No channel names or kinds are used as a category heuristic. This keeps
/// event-specific text, announcement, forum and voice channels under their
/// actual event category and prevents simultaneous tournaments from mixing.
List<CommunityChannelGroup> buildCommunityChannelGroups({
  required List<Map<String, dynamic>> categories,
  required List<Map<String, dynamic>> channels,
  String query = '',
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final activeCategories = categories
      .where((category) => category['archived_at'] == null)
      .toList()
    ..sort((a, b) {
      final left = int.tryParse(a['position']?.toString() ?? '') ?? 0;
      final right = int.tryParse(b['position']?.toString() ?? '') ?? 0;
      return left.compareTo(right);
    });

  bool channelMatches(Map<String, dynamic> channel) {
    if (normalizedQuery.isEmpty) return true;
    final name = channel['name']?.toString().toLowerCase() ?? '';
    final description = channel['description']?.toString().toLowerCase() ?? '';
    return name.contains(normalizedQuery) ||
        description.contains(normalizedQuery);
  }

  final allCategoryIds = categories
      .map((category) => category['id']?.toString() ?? '')
      .where((id) => id.isNotEmpty)
      .toSet();
  final groups = <CommunityChannelGroup>[];
  for (final category in activeCategories) {
    final categoryId = category['id']?.toString() ?? '';
    final categoryName = category['name']?.toString().trim() ?? '';
    if (categoryId.isEmpty || categoryName.isEmpty) continue;

    final categoryChannels = sortCommunityChannels(
      channels.where((channel) => channel['category_id']?.toString() == categoryId),
    );
    final categoryMatches = normalizedQuery.isNotEmpty &&
        categoryName.toLowerCase().contains(normalizedQuery);
    final visibleChannels = categoryMatches
        ? categoryChannels
        : categoryChannels.where(channelMatches).toList();

    if (visibleChannels.isNotEmpty) {
      groups.add(CommunityChannelGroup(
        categoryId: categoryId,
        title: categoryName,
        channels: visibleChannels,
      ));
    }
  }

  final uncategorized = sortCommunityChannels(channels.where((channel) {
    final categoryId = channel['category_id']?.toString() ?? '';
    final belongsToKnownCategory =
        categoryId.isNotEmpty && allCategoryIds.contains(categoryId);
    return !belongsToKnownCategory && channelMatches(channel);
  }));

  if (uncategorized.isNotEmpty) {
    groups.add(CommunityChannelGroup(
      categoryId: null,
      title: 'Uncategorized',
      channels: uncategorized,
    ));
  }

  return groups;
}
