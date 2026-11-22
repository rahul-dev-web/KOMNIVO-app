import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'match_detail_screen.dart';

class EventMatchesScreen extends StatefulWidget {
  const EventMatchesScreen({super.key, required this.event});
  final Map<String, dynamic> event;

  @override
  State<EventMatchesScreen> createState() => _EventMatchesScreenState();
}

class _EventMatchesScreenState extends State<EventMatchesScreen> {
  late Future<_EventMatchesData> _future;
  late Future<List<Map<String, dynamic>>> _myTestRegistrationsFuture;
  bool _registrationBusy = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _myTestRegistrationsFuture = _loadMyTestRegistrations();
  }

  Future<List<Map<String, dynamic>>> _loadMyTestRegistrations() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return <Map<String, dynamic>>[];
    final rows = await Supabase.instance.client
        .from('event_test_registrations')
        .select('id,status,review_note,created_at,teams(name,tag)')
        .eq('event_id', widget.event['id'])
        .eq('submitted_by', userId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<_EventMatchesData> _load() async {
    final client = Supabase.instance.client;
    final eventId = widget.event['id'] as String;
    final results = await Future.wait([
      client.from('matches')
        .select('id,round_number,group_label,match_number,starts_at,status,match_participants(team_id,check_in_status,teams(name,tag))')
        .eq('event_id', eventId)
        .order('round_number')
        .order('match_number'),
      client.from('event_standings')
        .select('event_id,team_id,points,kills,matches_played,first_places,teams(name,tag)')
        .eq('event_id', eventId)
        .order('points', ascending: false)
        .order('kills', ascending: false),
    ]);
    return _EventMatchesData(
      matches: List<Map<String, dynamic>>.from(results[0] as List),
      standings: List<Map<String, dynamic>>.from(results[1] as List),
    );
  }

  Future<void> _startRegistration(String registrationType) async {
    if (_registrationBusy) return;
    final event = widget.event;
    final status = event['status']?.toString() ?? '';
    final now = DateTime.now();
    final closeAt = DateTime.tryParse(event['registration_closes_at']?.toString() ?? '');
    final openAt = DateTime.tryParse(event['registration_opens_at']?.toString() ?? '');
    final eventIsPublished = status == 'published' || status == 'registration_open';

    if (!eventIsPublished || closeAt == null || !now.isBefore(closeAt)) {
      showMessage(context, 'This tournament registration window is closed or has no configured close time.');
      return;
    }
    if (registrationType == 'real' && (openAt == null || now.isBefore(openAt))) {
      showMessage(context, 'Real registration has not opened yet. Test registration is available separately while the test window remains open.');
      return;
    }

    String? teamId;
    final format = event['format']?.toString() ?? 'squad';
    if (format != 'solo') {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        showMessage(context, 'Sign in before registering.');
        return;
      }
      try {
        final rows = await Supabase.instance.client
            .from('team_members')
            .select('team_id, teams(id,name,tag,game_id)')
            .eq('user_id', userId);
        final gameId = event['game_id']?.toString();
        final teams = List<Map<String, dynamic>>.from(rows).where((row) {
          final team = row['teams'];
          return team is Map && team['game_id']?.toString() == gameId;
        }).map((row) => Map<String, dynamic>.from(row['teams'] as Map)).toList();

        if (teams.isEmpty) {
          showMessage(context, 'You need to belong to a team for this game before registering.');
          return;
        }

        String selectedTeamId = teams.first['id'].toString();
        final chosen = await showDialog<String>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(registrationType == 'test' ? 'Test registration' : 'Tournament registration'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Choose the team you are submitting for. Any current team member can submit once the minimum roster has joined this tournament community.'),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      value: selectedTeamId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Your team'),
                      items: teams.map((team) => DropdownMenuItem<String>(
                        value: team['id'].toString(),
                        child: Text(team['name']?.toString() ?? 'Team', overflow: TextOverflow.ellipsis),
                      )).toList(),
                      onChanged: (value) {
                        if (value != null) setDialogState(() => selectedTeamId = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      registrationType == 'test'
                          ? 'Test entries do not reserve real slots or affect public participants and standings.'
                          : 'This submits a real tournament registration for the selected team.',
                      style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, selectedTeamId),
                  child: Text(registrationType == 'test' ? 'Submit test' : 'Register team'),
                ),
              ],
            ),
          ),
        );
        if (chosen == null || !mounted) return;
        teamId = chosen;
      } catch (error) {
        if (mounted) showMessage(context, error.toString());
        return;
      }
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(registrationType == 'test' ? 'Submit test registration?' : 'Register for tournament?'),
          content: Text(
            registrationType == 'test'
                ? 'This creates an isolated test entry. It does not reserve a real slot or enter scoring.'
                : 'This submits your real registration for this tournament.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _registrationBusy = true);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'register-event',
        body: {
          'event_id': event['id'],
          'team_id': teamId,
          'registration_type': registrationType,
        },
      );
      if (response.status < 200 || response.status >= 300) {
        final details = response.data is Map ? (response.data as Map)['error'] : null;
        throw Exception(details?.toString() ?? 'Registration could not be submitted.');
      }
      if (mounted) {
        if (registrationType == 'test') {
          setState(() => _myTestRegistrationsFuture = _loadMyTestRegistrations());
        }
        showMessage(
          context,
          registrationType == 'test'
              ? 'Test registration submitted. It will not use real tournament capacity.'
              : 'Real tournament registration submitted.',
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _registrationBusy = false);
    }
  }

  bool get _realRegistrationOpen {
    final status = widget.event['status']?.toString();
    final opens = DateTime.tryParse(widget.event['registration_opens_at']?.toString() ?? '');
    final closes = DateTime.tryParse(widget.event['registration_closes_at']?.toString() ?? '');
    final now = DateTime.now();
    return (status == 'published' || status == 'registration_open') &&
        opens != null && closes != null &&
        !now.isBefore(opens) && now.isBefore(closes);
  }

  bool get _testRegistrationOpen {
    final status = widget.event['status']?.toString();
    final closes = DateTime.tryParse(widget.event['registration_closes_at']?.toString() ?? '');
    return (status == 'published' || status == 'registration_open') &&
        closes != null && DateTime.now().isBefore(closes);
  }

  Widget _registrationPanel() {
    final format = widget.event['format']?.toString() ?? 'squad';
    final openAt = DateTime.tryParse(widget.event['registration_opens_at']?.toString() ?? '');
    final closeAt = DateTime.tryParse(widget.event['registration_closes_at']?.toString() ?? '');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Tournament registration', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5),
        Text(
          format == 'solo'
              ? 'Solo registration'
              : 'Team registration · Any current team member can submit when the minimum required roster has joined the community.',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 8),
        Text(
          'Real registration: ' + (openAt?.toLocal().toString() ?? 'Not announced'),
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
        ),
        Text(
          'Registration closes: ' + (closeAt?.toLocal().toString() ?? 'Not configured'),
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _registrationBusy || !_realRegistrationOpen
                ? null : () => _startRegistration('real'),
            icon: _registrationBusy
                ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.how_to_reg_outlined, size: 17),
            label: const Text('Register'),
          ),
          OutlinedButton.icon(
            onPressed: _registrationBusy || !_testRegistrationOpen
                ? null : () => _startRegistration('test'),
            icon: const Icon(Icons.science_outlined, size: 17),
            label: const Text('Test registration'),
          ),
        ]),
        if (!_realRegistrationOpen && _testRegistrationOpen) ...[
          const SizedBox(height: 8),
          const Text('Real registration has not opened yet. You can submit a test entry before the deadline.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        ],
        if (!_realRegistrationOpen && !_testRegistrationOpen) ...[
          const SizedBox(height: 8),
          const Text('Registration is not currently available.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        ],
        const SizedBox(height: 14),
        const Divider(color: KomnivoTheme.line),
        const SizedBox(height: 8),
        const Text('Your test-registration history',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _myTestRegistrationsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              );
            }
            if (snapshot.hasError) {
              return Text(snapshot.error.toString(),
                style: const TextStyle(color: Color(0xFFFF8193), fontSize: 10));
            }
            final rows = snapshot.data ?? [];
            if (rows.isEmpty) {
              return const Text('You have not submitted a test entry for this tournament.',
                style: TextStyle(color: KomnivoTheme.muted, fontSize: 10));
            }
            return Column(children: rows.map((row) {
              final team = row['teams'] is Map
                  ? Map<String, dynamic>.from(row['teams'] as Map)
                  : <String, dynamic>{};
              final reviewNote = row['review_note']?.toString() ?? '';
              final state = row['status']?.toString() ?? 'submitted';
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.science_outlined, color: KomnivoTheme.cyan, size: 18),
                title: Text(team['name']?.toString() ?? 'Solo test entry',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                subtitle: Text(
                  reviewNote.isEmpty ? 'Status: ' + state.replaceAll('_', ' ') : reviewNote,
                  style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                ),
                trailing: Text(state.toUpperCase(),
                  style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w900)),
              );
            }).toList());
          },
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eventName = widget.event['name']?.toString() ?? 'Event';
    return Scaffold(
      appBar: AppBar(title: Text(eventName), actions: [
        IconButton(onPressed: () => setState(() => _future = _load()), tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
      ]),
      body: FutureBuilder<_EventMatchesData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(snapshot.error.toString())));
          final data = snapshot.data!;
          return ListView(padding: const EdgeInsets.all(20), children: [
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: const Color(0xFF282348),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .35)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(eventName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 19)),
                const SizedBox(height: 5),
                Text(
                  '${widget.event['status'] ?? 'Event'} · ${widget.event['format'] ?? 'squad'} · ${widget.event['capacity'] ?? '—'} slots',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  _EventMetric(label: 'Matches', value: '${data.matches.length}'),
                  const SizedBox(width: 20),
                  _EventMetric(label: 'Ranked teams', value: '${data.standings.length}'),
                ]),
              ]),
            ),
            const SizedBox(height: 18),
            _registrationPanel(),
            const SizedBox(height: 24),
            const SectionTitle('Match schedule', subtitle: 'Open a match to check in, view room details and submit evidence'),
            const SizedBox(height: 10),
            if (data.matches.isEmpty)
              const EmptyState(title: 'Matches are not scheduled yet', message: 'The organiser will publish match groups and timings here.', icon: Icons.calendar_month_outlined)
            else
              ...data.matches.map((match) => _MatchCard(
                match: match,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MatchDetailScreen(matchId: match['id'] as String))),
              )),
            const SizedBox(height: 24),
            const SectionTitle('Official standings', subtitle: 'Only organiser-approved results count'),
            const SizedBox(height: 10),
            if (data.standings.isEmpty)
              const EmptyState(title: 'Standings will appear here', message: 'Approved match scores will update this table.')
            else
              ...data.standings.asMap().entries.map((entry) {
                final row = entry.value;
                final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
                return Container(
                  margin: const EdgeInsets.only(bottom: 7),
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                  decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: KomnivoTheme.line)),
                  child: Row(children: [
                    CircleAvatar(radius: 15, child: Text('${entry.key + 1}', style: const TextStyle(fontSize: 11))),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(team['name']?.toString() ?? 'Team', style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text('${row['matches_played']} matches · ${row['kills']} kills · ${row['first_places']} wins', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                    ])),
                    Text('${row['points']} pts', style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w900)),
                  ]),
                );
              }),
          ]);
        },
      ),
    );
  }
}

class _EventMatchesData {
  const _EventMatchesData({required this.matches, required this.standings});
  final List<Map<String, dynamic>> matches;
  final List<Map<String, dynamic>> standings;
}

class _EventMetric extends StatelessWidget {
  const _EventMetric({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
    Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10)),
  ]);
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.onTap});
  final Map<String, dynamic> match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final participants = match['match_participants'] as List? ?? [];
    final start = DateTime.tryParse(match['starts_at']?.toString() ?? '');
    final schedule = start == null ? 'Time not confirmed' : start.toLocal().toString().substring(0, 16);
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: KomnivoTheme.line)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
        leading: Container(
          width: 42, height: 42,
          decoration: BoxDecoration(color: const Color(0xFF29234B), borderRadius: BorderRadius.circular(13)),
          child: const Icon(Icons.sports_esports_outlined, color: KomnivoTheme.accent),
        ),
        title: Text('Match #${match['match_number']} · ${match['group_label'] ?? 'Group pending'}', style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text('${match['status']} · $schedule · ${participants.length} teams', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
        trailing: const Icon(Icons.chevron_right, color: KomnivoTheme.cyan),
        onTap: onTap,
      ),
    );
  }
}
