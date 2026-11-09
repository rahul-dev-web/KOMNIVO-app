import 'package:flutter/material.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../inbox/chat_screen.dart';

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key, required this.preview});
  final bool preview;

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _future = KomnivoRepository.instance.communities();
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final description = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create community'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Community name')),
          const SizedBox(height: 12),
          TextField(controller: description, minLines: 2, maxLines: 3, decoration: const InputDecoration(labelText: 'What is this community about?')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    );
    if (result != true || name.text.trim().isEmpty || !mounted) return;
    try {
      await KomnivoRepository.instance.createCommunity(name: name.text.trim(), description: description.text.trim(), isPublic: true);
      setState(() => _future = KomnivoRepository.instance.communities());
      if (mounted) showMessage(context, 'Community created.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      name.dispose();
      description.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) {
      return ListView(padding: const EdgeInsets.all(20), children: const [
        PreviewBanner(),
        SectionTitle('Communities', subtitle: 'Discover your next squad space'),
        SizedBox(height: 14),
        _CommunityCard(name: 'KOMNIVO India Esports', description: 'Scrims, squads, Free Fire MAX and match updates.', members: '2.4K', tag: 'INDIA'),
        _CommunityCard(name: 'Night Owls Gaming', description: 'Late-night customs and competitive practice.', members: '860', tag: 'COMMUNITY'),
        _CommunityCard(name: 'Rank Push Collective', description: 'Find teammates and improve together.', members: '1.2K', tag: 'LFG'),
      ]);
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        return ListView(padding: const EdgeInsets.all(20), children: [
          SectionTitle('Communities', subtitle: 'Discover, join and manage gaming spaces', trailing: FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Create'))),
          const SizedBox(height: 16),
          if (snapshot.connectionState == ConnectionState.waiting) const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
          else if (rows.isEmpty) const EmptyState(title: 'No communities yet', message: 'Create your community or join one to start building your gaming circle.')
          else ...rows.map((row) => _CommunityDataCard(
            row: row,
            onJoin: () async {
              try {
                await KomnivoRepository.instance.joinCommunity(row['id'] as String);
                if (mounted) {
                  setState(() => _future = KomnivoRepository.instance.communities());
                  showMessage(context, 'Joined community.');
                }
              } catch (error) { if (mounted) showMessage(context, error.toString()); }
            },
            onChat: () async {
              try {
                final channels = await KomnivoRepository.instance.channels(communityId: row['id'] as String);
                final textChannels = channels.where((c) => c['kind'] == 'text');
                final channel = textChannels.isEmpty ? null : textChannels.first;
                if (channel == null || !mounted) return;
                Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(channel: channel)));
              } catch (error) { if (mounted) showMessage(context, error.toString()); }
            },
          )),
        ]);
      },
    );
  }
}

class _CommunityCard extends StatelessWidget {
  const _CommunityCard({required this.name, required this.description, required this.members, required this.tag});
  final String name, description, members, tag;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(19), border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [const CircleAvatar(backgroundColor: KomnivoTheme.surfaceRaised, child: Icon(Icons.groups, color: KomnivoTheme.cyan)), const SizedBox(width: 12), Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800))), Text(tag, style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w800))]),
      const SizedBox(height: 12), Text(description, style: const TextStyle(color: KomnivoTheme.muted)),
      const SizedBox(height: 12), Row(children: [Text('$members members', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)), const Spacer(), const Text('Preview', style: TextStyle(color: KomnivoTheme.accent, fontWeight: FontWeight.w800))]),
    ]),
  );
}

class _CommunityDataCard extends StatelessWidget {
  const _CommunityDataCard({required this.row, required this.onJoin, required this.onChat});
  final Map<String, dynamic> row;
  final VoidCallback onJoin;
  final VoidCallback onChat;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(19), border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const CircleAvatar(backgroundColor: KomnivoTheme.surfaceRaised, child: Icon(Icons.groups, color: KomnivoTheme.cyan)),
        const SizedBox(width: 12),
        Expanded(child: Text(row['name']?.toString() ?? 'Community', style: const TextStyle(fontWeight: FontWeight.w800))),
        Text((row['visibility'] ?? 'public').toString().toUpperCase(), style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w800)),
      ]),
      if ((row['description'] ?? '').toString().isNotEmpty) ...[
        const SizedBox(height: 10), Text(row['description'].toString(), style: const TextStyle(color: KomnivoTheme.muted)),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: onJoin, icon: const Icon(Icons.person_add_alt_1), label: const Text('Join'))),
        const SizedBox(width: 8),
        Expanded(child: FilledButton.icon(onPressed: onChat, icon: const Icon(Icons.forum_outlined), label: const Text('Open chat'))),
      ]),
    ]),
  );
}
