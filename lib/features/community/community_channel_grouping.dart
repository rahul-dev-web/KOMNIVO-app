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

    final categoryChannels = channels
        .where((channel) => channel['category_id']?.toString() == categoryId)
        .toList();
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

  final uncategorized = channels.where((channel) {
    final categoryId = channel['category_id']?.toString() ?? '';
    final belongsToKnownCategory =
        categoryId.isNotEmpty && allCategoryIds.contains(categoryId);
    return !belongsToKnownCategory && channelMatches(channel);
  }).toList();

  if (uncategorized.isNotEmpty) {
    groups.add(CommunityChannelGroup(
      categoryId: null,
      title: 'Uncategorized',
      channels: uncategorized,
    ));
  }

  return groups;
}
