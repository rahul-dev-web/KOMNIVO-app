import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'chat_screen.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, required this.preview});
  final bool preview;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  Future<List<Map<String, dynamic>>>? _future;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _activeFilter = 'All';

  static const List<Map<String, dynamic>> _previewConversations = <Map<String, dynamic>>[
    <String, dynamic>{'id': 'preview-dm-1', 'name': 'Nova', 'kind': 'dm'},
    <String, dynamic>{'id': 'preview-group-1', 'name': 'Rank Push Trio', 'kind': 'group'},
    <String, dynamic>{'id': 'preview-dm-2', 'name': 'Raze', 'kind': 'dm'},
  ];

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _future = KomnivoRepository.instance.directConversations();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (widget.preview) return;
    final next = KomnivoRepository.instance.directConversations();
    setState(() => _future = next);
    try {
      await next;
    } catch (_) {}
  }

  Future<void> _startConversation() async {
    if (widget.preview) {
      showMessage(context, 'Connect Supabase to start a real conversation.');
      return;
    }

    final search = TextEditingController();
    List<Map<String, dynamic>> people = <Map<String, dynamic>>[];
    bool searching = false;
    String? errorText;
    Map<String, dynamic>? createdChannel;

    Future<void> searchPlayers(StateSetter setDialogState) async {
      final query = search.text.trim();
      if (query.length < 2) {
        setDialogState(() => errorText = 'Enter at least 2 characters.');
        return;
      }

      setDialogState(() {
        searching = true;
        errorText = null;
        people = <Map<String, dynamic>>[];
      });

      try {
        final rows = await Supabase.instance.client
            .from('profiles')
            .select('id,display_name,username')
            .neq('id', KomnivoRepository.instance.userId)
            .ilike('display_name', '%' + query + '%')
            .limit(8);
        setDialogState(() => people = List<Map<String, dynamic>>.from(rows));
      } catch (error) {
        setDialogState(() => errorText = error.toString());
      } finally {
        setDialogState(() => searching = false);
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Start a conversation'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Search players by display name',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search_rounded),
                      onPressed: () => searchPlayers(setDialogState),
                    ),
                  ),
                  onSubmitted: (_) => searchPlayers(setDialogState),
                ),
                const SizedBox(height: 12),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(),
                  ),
                if (errorText != null)
                  Text(
                    errorText!,
                    style: const TextStyle(color: KomnivoTheme.danger, fontSize: 12),
                  ),
                if (!searching && people.isEmpty && errorText == null)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Search for another KOMNIVO player to message privately.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 12),
                    ),
                  ),
                if (people.isNotEmpty)
                  SizedBox(
                    height: 240,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: people.length,
                      itemBuilder: (context, index) {
                        final person = people[index];
                        final displayName = person['display_name']?.toString() ?? 'Player';
                        final username = person['username']?.toString() ?? '';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: KomnivoTheme.accent.withValues(alpha: .14),
                            child: Text(
                              displayName.isEmpty ? 'P' : displayName.substring(0, 1).toUpperCase(),
                              style: const TextStyle(color: KomnivoTheme.accent, fontWeight: FontWeight.w900),
                            ),
                          ),
                          title: Text(displayName),
                          subtitle: Text(username.isNotEmpty ? '@' + username : 'KOMNIVO player'),
                          onTap: () async {
                            try {
                              final response = await Supabase.instance.client.functions.invoke(
                                'create-conversation',
                                body: <String, dynamic>{'member_ids': <String>[person['id'] as String]},
                              );
                              if (response.status < 200 || response.status >= 300) {
                                throw Exception('Could not create conversation.');
                              }
                              final payload = response.data;
                              if (payload is! Map || payload['channel'] is! Map) {
                                throw Exception('The conversation response was incomplete.');
                              }
                              createdChannel = Map<String, dynamic>.from(payload['channel'] as Map);
                              if (dialogContext.mounted) Navigator.pop(dialogContext);
                            } catch (error) {
                              setDialogState(() => errorText = error.toString());
                            }
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );

    search.dispose();

    final channel = createdChannel;
    if (channel != null && mounted) {
      setState(() => _future = KomnivoRepository.instance.directConversations());
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(builder: (_) => ChatScreen(channel: channel)),
      );
      if (mounted) await _reload();
    }
  }

  List<Map<String, dynamic>> _filteredConversations(List<Map<String, dynamic>> rows) {
    final query = _searchQuery.toLowerCase().trim();
    return rows.where((row) {
      final name = row['name']?.toString() ?? '';
      final kind = (row['kind'] ?? 'dm').toString();
      final matchesFilter = _activeFilter == 'All' ||
          (_activeFilter == 'Direct' && kind == 'dm') ||
          (_activeFilter == 'Groups' && kind == 'group');
      final matchesSearch = query.isEmpty || name.toLowerCase().contains(query);
      return matchesFilter && matchesSearch;
    }).toList();
  }

  Widget _conversationTile(Map<String, dynamic> row, {required bool preview}) {
    final name = row['name']?.toString() ?? 'Direct message';
    final kind = (row['kind'] ?? 'dm').toString();
    final isGroup = kind == 'group';
    final initial = name.isEmpty ? 'D' : name.substring(0, 1).toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: preview
              ? () => showMessage(context, 'Preview mode — connect Supabase to open this conversation.')
              : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(builder: (_) => ChatScreen(channel: row)),
                  ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: isGroup
                      ? KomnivoTheme.cyan.withValues(alpha: .14)
                      : KomnivoTheme.accent.withValues(alpha: .14),
                  child: isGroup
                      ? const Icon(Icons.group_outlined, color: KomnivoTheme.cyan)
                      : Text(
                          initial,
                          style: const TextStyle(color: KomnivoTheme.accent, fontWeight: FontWeight.w900),
                        ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      const SizedBox(height: 5),
                      Text(
                        isGroup ? 'Private group conversation' : 'Direct message',
                        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, color: KomnivoTheme.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) {
      return _buildInbox(
        rows: _previewConversations,
        preview: true,
      );
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) => _buildInbox(
        rows: snapshot.data ?? <Map<String, dynamic>>[],
        loading: snapshot.connectionState == ConnectionState.waiting && snapshot.data == null,
        error: snapshot.hasError ? snapshot.error.toString() : null,
        preview: false,
      ),
    );
  }

  Widget _buildInbox({
    required List<Map<String, dynamic>> rows,
    required bool preview,
    bool loading = false,
    String? error,
  }) {
    final visibleRows = _filteredConversations(rows);
    return Scaffold(
      backgroundColor: KomnivoTheme.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              MediaQuery.sizeOf(context).width < 560 ? 16 : 28,
              18,
              MediaQuery.sizeOf(context).width < 560 ? 16 : 28,
              28,
            ),
            children: [
              if (preview) const PreviewBanner(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Messages', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)),
                        SizedBox(height: 4),
                        Text(
                          'Private conversations with players.',
                          style: TextStyle(color: KomnivoTheme.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _startConversation,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('New message'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                decoration: InputDecoration(
                  hintText: 'Search people or group chats',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 13),
              Wrap(
                spacing: 8,
                children: [
                  for (final filter in const ['All', 'Direct', 'Groups'])
                    ChoiceChip(
                      label: Text(filter),
                      selected: _activeFilter == filter,
                      onSelected: (_) => setState(() => _activeFilter = filter),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (error != null)
                EmptyState(
                  title: 'Messages could not load',
                  message: error,
                  icon: Icons.error_outline_rounded,
                )
              else if (visibleRows.isEmpty)
                EmptyState(
                  title: rows.isEmpty ? 'No private conversations yet' : 'No matching conversations',
                  message: rows.isEmpty
                      ? 'Start a direct message with another KOMNIVO player. Community channels and voice rooms stay in their own sections.'
                      : 'Try a different name or conversation filter.',
                  icon: Icons.chat_bubble_outline_rounded,
                )
              else ...visibleRows.map((row) => _conversationTile(row, preview: preview)),
            ],
          ),
        ),
      ),
    );
  }
}
