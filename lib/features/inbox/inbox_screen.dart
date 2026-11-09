import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'chat_screen.dart';
import 'voice_room_screen.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, required this.preview});
  final bool preview;
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  Future<List<Map<String, dynamic>>>? _future;
  @override
  void initState() {
    super.initState();
    if (!widget.preview) _future = KomnivoRepository.instance.channels();
  }

  Future<void> _startConversation() async {
    final search = TextEditingController();
    List<Map<String, dynamic>> people = [];
    bool searching = false;
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Start a conversation'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: search,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Search public player names',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () async {
                      final q = search.text.trim();
                      if (q.length < 2) {
                        setDialogState(() => errorText = 'Enter at least 2 characters.');
                        return;
                      }
                      setDialogState(() { searching = true; errorText = null; people = []; });
                      try {
                        final rows = await Supabase.instance.client.from('profiles')
                          .select('id,display_name,username')
                          .neq('id', KomnivoRepository.instance.userId)
                          .ilike('display_name', '%$q%')
                          .limit(8);
                        setDialogState(() => people = List<Map<String, dynamic>>.from(rows));
                      } catch (error) {
                        setDialogState(() => errorText = error.toString());
                      } finally {
                        setDialogState(() => searching = false);
                      }
                    },
                  ),
                ),
                onSubmitted: (_) async {
                  final q = search.text.trim();
                  if (q.length < 2) return;
                  setDialogState(() { searching = true; errorText = null; people = []; });
                  try {
                    final rows = await Supabase.instance.client.from('profiles')
                      .select('id,display_name,username')
                      .neq('id', KomnivoRepository.instance.userId)
                      .ilike('display_name', '%$q%')
                      .limit(8);
                    setDialogState(() => people = List<Map<String, dynamic>>.from(rows));
                  } catch (error) {
                    setDialogState(() => errorText = error.toString());
                  } finally {
                    setDialogState(() => searching = false);
                  }
                },
              ),
              const SizedBox(height: 12),
              if (searching) const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator()),
              if (errorText != null) Text(errorText!, style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12)),
              if (!searching && people.isEmpty && errorText == null)
                const Padding(padding: EdgeInsets.all(12), child: Text('Search for a player by their public display name.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12))),
              if (people.isNotEmpty)
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: people.length,
                    itemBuilder: (context, index) {
                      final person = people[index];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                        title: Text(person['display_name']?.toString() ?? 'Player'),
                        subtitle: Text(person['username']?.toString().isNotEmpty == true ? '@${person['username']}' : 'KOMNIVO player'),
                        onTap: () async {
                          try {
                            final response = await Supabase.instance.client.functions.invoke(
                              'create-conversation',
                              body: {'member_ids': [person['id']]},
                            );
                            if (response.status < 200 || response.status >= 300) throw Exception('Could not create conversation.');
                            if (mounted) setState(() => _future = KomnivoRepository.instance.channels());
                            if (dialogContext.mounted) Navigator.pop(dialogContext);
                            if (mounted) showMessage(this.context, 'Conversation created.');
                          } catch (error) {
                            setDialogState(() => errorText = error.toString());
                          }
                        },
                      );
                    },
                  ),
                ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
        ),
      ),
    );
    search.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) return ListView(padding: const EdgeInsets.all(20), children: const [
      PreviewBanner(),
      SectionTitle('Inbox', subtitle: 'Direct messages and group conversations'),
      SizedBox(height: 14),
      _InboxTile(name: 'IGL Squad Room', detail: 'Captain: match check-in is open', unread: 3),
      _InboxTile(name: 'Night Owls Gaming', detail: 'Scrim schedule shared', unread: 1),
      _InboxTile(name: 'KOMNIVO Support', detail: 'Welcome to the platform', unread: 0),
    ]);

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        return ListView(padding: const EdgeInsets.all(20), children: [
          SectionTitle('Inbox', subtitle: 'Your channels and conversations', trailing: FilledButton.icon(
            onPressed: _startConversation,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('New message'),
          )),
          const SizedBox(height: 14),
          if (snapshot.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator())
          else if (rows.isEmpty) const EmptyState(title: 'Nothing in your inbox', message: 'Join a community or start a conversation with a player.', icon: Icons.mark_chat_unread_outlined)
          else ...rows.map((row) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
            child: Row(children: [
              Expanded(child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.forum_outlined)),
                title: Text(row['name']?.toString() ?? 'Conversation'),
                subtitle: Text((row['kind'] ?? 'text').toString()),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(channel: row))),
              )),
              if ((row['kind'] ?? 'text') == 'voice' || (row['kind'] ?? 'text') == 'text' || (row['kind'] ?? 'text') == 'group' || (row['kind'] ?? 'text') == 'dm')
                IconButton(
                  tooltip: 'Join voice room',
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VoiceRoomScreen(
                    channelId: row['id'] as String,
                    channelName: row['name']?.toString() ?? 'Voice room',
                  ))),
                  icon: const Icon(Icons.headset_mic_outlined, color: KomnivoTheme.cyan),
                ),
              const SizedBox(width: 8),
            ]),
          )),
        ]);
      },
    );
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.name, required this.detail, required this.unread});
  final String name, detail;
  final int unread;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      const CircleAvatar(child: Icon(Icons.forum_outlined)), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4), Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ])),
      if (unread > 0) CircleAvatar(radius: 13, backgroundColor: KomnivoTheme.accent, child: Text('$unread', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900))),
    ]),
  );
}
