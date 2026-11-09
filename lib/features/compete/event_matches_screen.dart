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

  @override
  void initState() {
    super.initState();
    _future = _load();
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
