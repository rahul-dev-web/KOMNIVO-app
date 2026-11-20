/// Applies the channel's recent-history display rule without deleting stored data.
List<T> applyChannelHistoryPolicy<T>(
  List<T> messages, {
  required bool keepHistory,
  required bool canManageMessages,
  int recentLimit = 50,
}) {
  if (keepHistory || canManageMessages || messages.length <= recentLimit) {
    return messages;
  }
  return messages.sublist(messages.length - recentLimit);
}
