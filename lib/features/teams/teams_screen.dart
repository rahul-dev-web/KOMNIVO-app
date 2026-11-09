import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

const freeFireGameId = '11111111-1111-4111-8111-111111111111';

class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key, required this.preview});
  final bool preview;
  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  Future<List<Map<String, dynamic>>>? _future;
  Future<List<Map<String, dynamic>>>? _invitesFuture;
  @override
  void initState() {
    super.initState();
    if (!widget.preview) _reload();
  }

  void _reload() {
    setState(() {
      _future = KomnivoRepository.instance.teams();
      final client = Supabase.instance.client;
      _invitesFuture = client.from('team_invites')
        .select('*, teams(name,tag)')
        .eq('invited_user_id', client.auth.currentUser!.id)
        .eq('status', 'pending')
        .order('created_at', ascending: false);
    });
  }

  Future<void> _createTeam() async {
    final name = TextEditingController();
    final tag = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Create your team'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Team name')),
        const SizedBox(height: 12),
        TextField(controller: tag, maxLength: 5, decoration: const InputDecoration(labelText: 'Short tag (optional)')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create team'))],
    ));
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    try {
      await KomnivoRepository.instance.createTeam(name: name.text.trim(), tag: tag.text.trim(), gameId: freeFireGameId);
      _reload();
      if (mounted) showMessage(context, 'Team created. You are its owner.');
    } catch (error) { if (mounted) showMessage(context, error.toString()); }
    finally { name.dispose(); tag.dispose(); }
  }

  Future<void> _invitePlayer(Map<String, dynamic> team) async {
    final search = TextEditingController();
    List<Map<String, dynamic>> people = [];
    bool searching = false;
    String? errorText;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Invite to ${team['name']}'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: search,
              decoration: InputDecoration(
                labelText: 'Search public player names',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () async {
                    if (search.text.trim().length < 2) {
                      setDialogState(() => errorText = 'Enter at least 2 characters.');
                      return;
                    }
                    setDialogState(() { searching = true; people = []; errorText = null; });
                    try {
                      final rows = await Supabase.instance.client.from('profiles')
                        .select('id,display_name,username')
                        .neq('id', KomnivoRepository.instance.userId)
                        .ilike('display_name', '%${search.text.trim()}%')
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
                if (search.text.trim().length < 2) return;
                setDialogState(() { searching = true; people = []; errorText = null; });
                try {
                  final rows = await Supabase.instance.client.from('profiles')
                    .select('id,display_name,username')
                    .neq('id', KomnivoRepository.instance.userId)
                    .ilike('display_name', '%${search.text.trim()}%')
                    .limit(8);
                  setDialogState(() => people = List<Map<String, dynamic>>.from(rows));
                } catch (error) {
                  setDialogState(() => errorText = error.toString());
                } finally {
                  setDialogState(() => searching = false);
                }
              },
            ),
            const SizedBox(height: 10),
            if (searching) const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
            if (errorText != null) Text(errorText!, style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12)),
            if (people.isNotEmpty) SizedBox(
              height: 240,
              child: ListView(children: people.map((person) => ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(person['display_name']?.toString() ?? 'Player'),
                subtitle: Text(person['username']?.toString().isNotEmpty == true ? '@${person['username']}' : 'KOMNIVO player'),
                trailing: const Icon(Icons.person_add_alt_1, color: KomnivoTheme.cyan),
                onTap: () async {
                  try {
                    await Supabase.instance.client.from('team_invites').insert({
                      'team_id': team['id'],
                      'invited_user_id': person['id'],
                      'invited_by': KomnivoRepository.instance.userId,
                    });
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                    if (mounted) showMessage(this.context, 'Team invitation sent.');
                  } catch (error) {
                    setDialogState(() => errorText = error.toString());
                  }
                },
              )).toList()),
            ),
            if (!searching && people.isEmpty && errorText == null)
              const Padding(padding: EdgeInsets.all(10), child: Text('Search by the public display name of the player.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12))),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
        ),
      ),
    );
    search.dispose();
  }

  Future<void> _acceptInvite(String inviteId) async {
    try {
      final response = await Supabase.instance.client.functions.invoke('accept-team-invite', body: {'invite_id': inviteId});
      if (response.status < 200 || response.status >= 300) throw Exception('Invitation could not be accepted.');
      _reload();
      if (mounted) showMessage(context, 'You joined the team.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) return ListView(padding: const EdgeInsets.all(20), children: const [
      PreviewBanner(),
      SectionTitle('Teams', subtitle: 'Build a roster that competes together'),
      SizedBox(height: 14),
      _TeamCard(name: 'IGL Esports', tag: 'IGL', members: '4 players', status: 'Active roster'),
      _TeamCard(name: 'Raipur Royals', tag: 'RR', members: '6 players', status: 'Recruiting substitute'),
    ]);

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        return ListView(padding: const EdgeInsets.all(20), children: [
          SectionTitle('Teams', subtitle: 'Create, manage and recruit your squad', trailing: FilledButton.icon(onPressed: _createTeam, icon: const Icon(Icons.add), label: const Text('Create'))),
          const SizedBox(height: 14),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _invitesFuture,
            builder: (context, inviteSnapshot) {
              final invites = inviteSnapshot.data ?? [];
              if (invites.isEmpty) return const SizedBox.shrink();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Team invitations', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                const SizedBox(height: 8),
                ...invites.map((invite) {
                  final team = invite['teams'] is Map ? Map<String, dynamic>.from(invite['teams'] as Map) : <String, dynamic>{};
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
                    child: Row(children: [
                      Expanded(child: Text('Join ${team['name'] ?? 'team'}?', style: const TextStyle(fontWeight: FontWeight.w800))),
                      FilledButton(onPressed: () => _acceptInvite(invite['id'] as String), child: const Text('Accept')),
                    ]),
                  );
                }),
                const SizedBox(height: 14),
              ]);
            },
          ),
          if (snapshot.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator())
          else if (rows.isEmpty) const EmptyState(title: 'No teams yet', message: 'Create a team and invite players to build your first roster.', icon: Icons.shield_outlined)
          else ...rows.map((row) => _TeamDataCard(
            row: row,
            onInvite: () => _invitePlayer(row),
          )),
        ]);
      },
    );
  }
}

class _TeamCard extends StatelessWidget {
  const _TeamCard({required this.name, required this.tag, required this.members, required this.status});
  final String name, tag, members, status;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      Container(width: 48, height: 48, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF29234B), borderRadius: BorderRadius.circular(14)), child: Text(tag, style: const TextStyle(fontWeight: FontWeight.w900, color: KomnivoTheme.accent))),
      const SizedBox(width: 13),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 4), Text('$members · $status', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ])),
      const Icon(Icons.chevron_right, color: KomnivoTheme.muted),
    ]),
  );
}

class _TeamDataCard extends StatelessWidget {
  const _TeamDataCard({required this.row, required this.onInvite});
  final Map<String, dynamic> row;
  final VoidCallback onInvite;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      Container(width: 48, height: 48, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF29234B), borderRadius: BorderRadius.circular(14)), child: Text((row['tag'] ?? 'TEAM').toString(), style: const TextStyle(fontWeight: FontWeight.w900, color: KomnivoTheme.accent))),
      const SizedBox(width: 13),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(row['name']?.toString() ?? 'Team', style: const TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(row['owner_user_id'] == KomnivoRepository.instance.userId ? 'You own this team' : 'Team roster', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ])),
      IconButton(onPressed: onInvite, tooltip: 'Invite player', icon: const Icon(Icons.person_add_alt_1, color: KomnivoTheme.cyan)),
    ]),
  );
}
