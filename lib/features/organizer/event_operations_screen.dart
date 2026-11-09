import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class EventOperationsScreen extends StatefulWidget {
  const EventOperationsScreen({super.key, required this.event});
  final Map<String, dynamic> event;

  @override
  State<EventOperationsScreen> createState() => _EventOperationsScreenState();
}

class _EventOperationsScreenState extends State<EventOperationsScreen> {
  late Future<_EventData> _future;
  bool _busy = false;
  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_EventData> _load() async {
    final eventId = widget.event['id'] as String;
    final results = await Future.wait([
      _client.from('event_registrations')
        .select('*, teams(name,tag), registration_players(count)')
        .eq('event_id', eventId).order('registered_at'),
      _client.from('matches')
        .select('*, match_participants(team_id,check_in_status,teams(name,tag)), room_credentials(id,release_at)')
        .eq('event_id', eventId).order('match_number'),
      _client.from('match_results')
        .select('*, teams(name,tag), matches!inner(event_id,match_number)')
        .eq('matches.event_id', eventId).order('submitted_at', ascending: false),
      _client.from('event_rounds')
        .select('*, event_groups(id,label,sort_order,event_group_teams(team_id,teams(name,tag)))')
        .eq('event_id', eventId).order('round_number'),
      _client.from('opponent_confirmations')
        .select('*, match_results!inner(id,match_id,team_id,matches!inner(event_id,match_number))')
        .eq('match_results.matches.event_id', eventId)
        .eq('decision', 'disputed')
        .order('created_at', ascending: false),
    ]);
    return _EventData(
      registrations: List<Map<String, dynamic>>.from(results[0] as List),
      matches: List<Map<String, dynamic>>.from(results[1] as List),
      results: List<Map<String, dynamic>>.from(results[2] as List),
      rounds: List<Map<String, dynamic>>.from(results[3] as List),
      disputedConfirmations: List<Map<String, dynamic>>.from(results[4] as List),
    );
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _reviewRegistration(String id, String status) async {
    setState(() => _busy = true);
    try {
      final response = await _client.functions.invoke('review-registration', body: {
        'registration_id': id,
        'status': status,
      });
      if (response.status < 200 || response.status >= 300) throw Exception('Registration review failed.');
      _reload();
      if (mounted) showMessage(context, 'Registration $status.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lockRosters() async {
    setState(() => _busy = true);
    try {
      final result = await _client.rpc('lock_event_rosters', params: {'p_event_id': widget.event['id']});
      _reload();
      if (mounted) showMessage(context, 'Roster lock complete. Newly locked registrations: ${result['locked'] ?? 0}.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateGroups() async {
    final size = TextEditingController(text: '12');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Generate balanced groups'),
        content: TextField(
          controller: size,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Target team count per group'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Generate')),
        ],
      ),
    );
    final groupSize = int.tryParse(size.text);
    size.dispose();
    if (ok != true || groupSize == null || groupSize < 2 || groupSize > 24) return;

    setState(() => _busy = true);
    try {
      final result = await _client.rpc('generate_event_groups', params: {
        'p_event_id': widget.event['id'],
        'p_round_number': 1,
        'p_group_size': groupSize,
      });
      _reload();
      if (mounted) showMessage(context, 'Generated ${result['group_count']} balanced groups for ${result['team_count']} teams.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createMatch(List<Map<String, dynamic>> eligible, List<Map<String, dynamic>> groups) async {
    final selected = <String>{};
    String? selectedGroup = groups.isNotEmpty ? groups.first['label']?.toString() : null;
    final result = await showDialog<_MatchSetup>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Create match'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (groups.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    value: selectedGroup,
                    decoration: const InputDecoration(labelText: 'Tournament group'),
                    items: groups.map((group) => DropdownMenuItem(
                      value: group['label'].toString(),
                      child: Text(group['label'].toString()),
                    )).toList(),
                    onChanged: (value) => setDialogState(() {
                      selectedGroup = value;
                      selected.clear();
                    }),
                  ),
                  const SizedBox(height: 10),
                ],
                ...eligible.where((row) {
                  if (selectedGroup == null) return true;
                  final groupRow = groups.firstWhere(
                    (group) => group['label']?.toString() == selectedGroup,
                    orElse: () => <String, dynamic>{},
                  );
                  final assigned = groupRow['event_group_teams'] as List? ?? [];
                  return assigned.any((item) => item is Map && item['team_id'] == row['team_id']);
                }).map((row) {
                  final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
                  final id = row['team_id'] as String;
                  return CheckboxListTile(
                    value: selected.contains(id),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(id);
                      } else {
                        selected.remove(id);
                      }
                    }),
                    title: Text(team['name']?.toString() ?? 'Team'),
                    subtitle: Text(team['tag']?.toString() ?? ''),
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                }),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: selected.length < 2 ? null : () => Navigator.pop(dialogContext, _MatchSetup(selected.toList(), selectedGroup)),
              child: Text('Create match (${selected.length})'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    setState(() => _busy = true);
    try {
      final matchId = await _client.rpc('create_match', params: {
        'p_event_id': widget.event['id'],
        'p_team_ids': result.teamIds,
        'p_starts_at': DateTime.now().add(const Duration(minutes: 15)).toUtc().toIso8601String(),
        'p_group_label': result.groupLabel,
      });
      _reload();
      if (mounted) showMessage(context, 'Match created: $matchId');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addRoomCredentials(String matchId) async {
    final code = TextEditingController();
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add room credentials'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: code, decoration: const InputDecoration(labelText: 'Room ID')),
          const SizedBox(height: 12),
          TextField(controller: password, decoration: const InputDecoration(labelText: 'Room password')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save credentials')),
        ],
      ),
    );
    if (ok != true || code.text.trim().isEmpty || !mounted) {
      code.dispose();
      password.dispose();
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.from('room_credentials').insert({
        'match_id': matchId,
        'room_code': code.text.trim(),
        'room_password': password.text.trim(),
        'release_at': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
        'created_by': _client.auth.currentUser!.id,
      });
      _reload();
      if (mounted) showMessage(context, 'Room details saved with a 10-minute release delay.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      code.dispose();
      password.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolveOpponentDispute(String confirmationId) async {
    setState(() => _busy = true);
    try {
      await _client.from('opponent_confirmations').update({
        'review_status': 'resolved',
        'reviewed_by': _client.auth.currentUser!.id,
        'reviewed_at': DateTime.now().toUtc().toIso8601String(),
        'review_note': 'Reviewed by event organiser. Result remains subject to evidence verification.',
      }).eq('id', confirmationId);
      _reload();
      if (mounted) showMessage(context, 'Opponent dispute marked as reviewed. Review the evidence before approving the result.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approveResult(String resultId) async {
    setState(() => _busy = true);
    try {
      final response = await _client.functions.invoke('approve-result', body: {
        'result_id': resultId,
        'reason': 'Approved in organiser workspace',
      });
      if (response.status < 200 || response.status >= 300) throw Exception('Result approval failed.');
      _reload();
      if (mounted) showMessage(context, 'Official points calculated and standings updated.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateMatchStatus(String matchId, String status) async {
    setState(() => _busy = true);
    try {
      await _client.from('matches').update({'status': status}).eq('id', matchId);
      _reload();
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eventName = widget.event['name']?.toString() ?? 'Event';
    return Scaffold(
      appBar: AppBar(title: Text(eventName), actions: [
        IconButton(onPressed: _reload, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
      ]),
      body: FutureBuilder<_EventData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(snapshot.error.toString())));
          final data = snapshot.data!;
          final pending = data.registrations.where((row) => row['status'] == 'pending' || row['status'] == 'waitlisted').toList();
          final approved = data.registrations.where((row) => row['status'] == 'approved').toList();
          final locked = approved.where((row) => row['roster_locked'] == true).toList();
          final eligible = locked.where((row) => row['team_id'] != null).toList();
          final needsReview = data.results.where((row) => row['status'] != 'approved').toList();
          final groups = data.rounds.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(data.rounds.first['event_groups'] as List? ?? []);

          return ListView(padding: const EdgeInsets.all(20), children: [
            if (_busy) const LinearProgressIndicator(),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFF282348), borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .3))),
              child: Row(children: [
                const Icon(Icons.event_available, color: KomnivoTheme.cyan, size: 25),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(eventName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                  const SizedBox(height: 4),
                  Text('${data.registrations.length} registrations · ${data.matches.length} matches · ${needsReview.length} results to review', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ])),
              ]),
            ),
            const SizedBox(height: 22),
            SectionTitle('Registration review', subtitle: 'Approve, waitlist or reject team applications', trailing: Text('${pending.length} pending', style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800))),
            const SizedBox(height: 10),
            if (pending.isEmpty) const EmptyState(title: 'No registrations awaiting review', message: 'New applications will appear here.')
            else ...pending.map((row) {
              final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
              return _OperationCard(
                title: team['name']?.toString() ?? 'Solo player registration',
                subtitle: '${row['status']} · Captain ID ${(row['captain_user_id'] ?? '').toString().substring(0, 8)}…',
                badge: row['status'] == 'waitlisted' ? 'WAITLIST' : 'PENDING',
                trailing: Wrap(spacing: 6, children: [
                  IconButton(tooltip: 'Reject', onPressed: _busy ? null : () => _reviewRegistration(row['id'] as String, 'rejected'), icon: const Icon(Icons.close, color: Color(0xFFFF8193))),
                  IconButton(tooltip: 'Approve', onPressed: _busy ? null : () => _reviewRegistration(row['id'] as String, 'approved'), icon: const Icon(Icons.check_circle, color: KomnivoTheme.cyan)),
                ]),
              );
            }),
            const SizedBox(height: 22),
            SectionTitle('Roster control', subtitle: 'Snapshot accepted team members before group allocation'),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: _busy || approved.isEmpty ? null : _lockRosters,
                icon: const Icon(Icons.lock_outline),
                label: Text('Lock rosters (${approved.length - locked.length} remaining)'),
              )),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(
                onPressed: _busy || locked.length < 2 ? null : _generateGroups,
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Generate groups'),
              )),
            ]),
            const SizedBox(height: 10),
            if (groups.isNotEmpty)
              ...groups.map((group) {
                final assigned = group['event_group_teams'] as List? ?? [];
                return _OperationCard(
                  title: group['label']?.toString() ?? 'Group',
                  subtitle: '${assigned.length} teams · balanced allocation',
                  badge: 'ROUND 1',
                );
              })
            else
              const Text('Approve registrations, lock rosters, then generate balanced groups.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            const SizedBox(height: 22),
            SectionTitle('Match operations', subtitle: 'Create matches only from approved, locked team rosters', trailing: FilledButton.icon(
              onPressed: _busy || eligible.length < 2 ? null : () => _createMatch(eligible, groups),
              icon: const Icon(Icons.add),
              label: const Text('Create match'),
            )),
            const SizedBox(height: 10),
            if (data.matches.isEmpty) const EmptyState(title: 'No matches created', message: 'Lock at least two team rosters, then create a match.')
            else ...data.matches.map((row) {
              final participants = row['match_participants'] as List? ?? [];
              final credentials = row['room_credentials'] as List? ?? [];
              final hasCredentials = credentials.isNotEmpty;
              return _OperationCard(
                title: 'Match #${row['match_number']} · ${row['group_label'] ?? 'Unassigned group'}',
                subtitle: '${participants.length} teams · ${row['status']} · ${row['starts_at'] ?? 'Time pending'}',
                badge: (row['status'] ?? 'scheduled').toString().toUpperCase(),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'room') _addRoomCredentials(row['id'] as String);
                    else _updateMatchStatus(row['id'] as String, value);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'check_in', child: Text('Open check-in')),
                    const PopupMenuItem(value: 'room_setup', child: Text('Room setup')),
                    const PopupMenuItem(value: 'lobby_review', child: Text('Lobby review')),
                    const PopupMenuItem(value: 'live', child: Text('Mark live')),
                    const PopupMenuItem(value: 'awaiting_result', child: Text('Await result')),
                    const PopupMenuItem(value: 'room', child: Text('Add room credentials')),
                  ],
                ),
                footer: hasCredentials ? 'Room details saved · release at ${credentials.first['release_at']}' : 'Room details not added yet',
              );
            }),
            const SizedBox(height: 22),
            SectionTitle('Opponent disputes', subtitle: 'Review disputed confirmations before approving results'),
            const SizedBox(height: 10),
            if (data.disputedConfirmations.isEmpty)
              const Text('No opponent disputes currently require review.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11))
            else ...data.disputedConfirmations.where((row) => row['review_status'] != 'resolved').map((row) {
              final result = row['match_results'] is Map ? Map<String, dynamic>.from(row['match_results'] as Map) : <String, dynamic>{};
              return _OperationCard(
                title: 'Match result · team ${(result['team_id'] ?? '').toString().substring(0, 8)}…',
                subtitle: 'Opponent has disputed this submission.',
                badge: 'DISPUTED',
                trailing: IconButton(
                  tooltip: 'Mark dispute reviewed',
                  onPressed: _busy ? null : () => _resolveOpponentDispute(row['id'] as String),
                  icon: const Icon(Icons.fact_check_outlined, color: KomnivoTheme.cyan),
                ),
              );
            }),
            const SizedBox(height: 22),
            SectionTitle('Result verification', subtitle: 'Official standings update only after evidence and dispute review'),
            const SizedBox(height: 10),
            if (needsReview.isEmpty) const EmptyState(title: 'No results to review', message: 'Submitted match results will appear here.')
            else ...needsReview.map((row) {
              final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
              final disputed = data.disputedConfirmations.any((d) {
                final result = d['match_results'] is Map ? Map<String, dynamic>.from(d['match_results'] as Map) : <String, dynamic>{};
                return result['id'] == row['id'] && d['review_status'] != 'resolved';
              });
              return _OperationCard(
                title: team['name']?.toString() ?? 'Team result',
                subtitle: 'Placement ${row['placement'] ?? '—'} · ${row['kills']} kills · ${row['status']}${disputed ? ' · dispute must be reviewed' : ''}',
                badge: disputed ? 'DISPUTED' : 'REVIEW',
                trailing: IconButton(
                  tooltip: 'Approve official result',
                  onPressed: _busy || disputed ? null : () => _approveResult(row['id'] as String),
                  icon: const Icon(Icons.verified_outlined, color: KomnivoTheme.cyan),
                ),
              );
            }),
            const SizedBox(height: 22),
            SectionTitle('Current standings', subtitle: 'Calculated only from approved match results'),
            const SizedBox(height: 10),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _client.from('event_standings').select('*, teams(name,tag)').eq('event_id', widget.event['id']).order('points', ascending: false),
              builder: (context, standings) {
                final rows = standings.data ?? [];
                if (rows.isEmpty) return const EmptyState(title: 'Standings will appear here', message: 'Approved match results feed the leaderboard.');
                return Column(children: rows.asMap().entries.map((entry) {
                  final row = entry.value;
                  final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
                  return ListTile(
                    leading: CircleAvatar(radius: 16, child: Text('${entry.key + 1}')),
                    title: Text(team['name']?.toString() ?? 'Team'),
                    subtitle: Text('${row['matches_played']} matches · ${row['kills']} kills'),
                    trailing: Text('${row['points']} pts', style: const TextStyle(fontWeight: FontWeight.w900, color: KomnivoTheme.cyan)),
                  );
                }).toList());
              },
            ),
          ]);
        },
      ),
    );
  }
}

class _EventData {
  const _EventData({
    required this.registrations,
    required this.matches,
    required this.results,
    required this.rounds,
    required this.disputedConfirmations,
  });
  final List<Map<String, dynamic>> registrations;
  final List<Map<String, dynamic>> matches;
  final List<Map<String, dynamic>> results;
  final List<Map<String, dynamic>> rounds;
  final List<Map<String, dynamic>> disputedConfirmations;
}

class _MatchSetup {
  const _MatchSetup(this.teamIds, this.groupLabel);
  final List<String> teamIds;
  final String? groupLabel;
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({required this.title, required this.subtitle, required this.badge, this.trailing, this.footer});
  final String title, subtitle, badge;
  final Widget? trailing;
  final String? footer;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4), Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
        ])),
        if (trailing != null) trailing!,
      ]),
      const SizedBox(height: 5),
      Align(alignment: Alignment.centerLeft, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFF29234B), borderRadius: BorderRadius.circular(20)),
        child: Text(badge, style: const TextStyle(color: KomnivoTheme.accent, fontWeight: FontWeight.w900, fontSize: 9, letterSpacing: .6)),
      )),
      if (footer != null) ...[const SizedBox(height: 8), Text(footer!, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10))],
    ]),
  );
}
