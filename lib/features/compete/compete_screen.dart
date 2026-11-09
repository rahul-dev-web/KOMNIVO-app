import 'package:flutter/material.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class CompeteScreen extends StatefulWidget {
  const CompeteScreen({super.key, required this.preview});
  final bool preview;
  @override
  State<CompeteScreen> createState() => _CompeteScreenState();
}

class _CompeteScreenState extends State<CompeteScreen> {
  Future<List<Map<String, dynamic>>>? _future;
  final Set<String> _joining = {};

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _future = KomnivoRepository.instance.events();
  }

  Future<void> _register(Map<String, dynamic> event) async {
    final eventId = event['id'] as String;
    String? teamId;
    final format = (event['format'] ?? 'squad').toString();

    if (format != 'solo') {
      try {
        final teams = await KomnivoRepository.instance.myRegistrableTeams();
        if (teams.isEmpty) {
          if (mounted) showMessage(context, 'Create a team or become its captain before registering for a team event.');
          return;
        }
        if (teams.length == 1) {
          teamId = teams.first['id'] as String;
        } else {
          final choice = await showDialog<String>(
            context: context,
            builder: (dialogContext) {
              String? selected = teams.first['id'] as String;
              return StatefulBuilder(
                builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Choose your team'),
                  content: SizedBox(
                    width: 420,
                    child: Column(mainAxisSize: MainAxisSize.min, children: teams.map((team) => RadioListTile<String>(
                      value: team['id'] as String,
                      groupValue: selected,
                      onChanged: (value) => setDialogState(() => selected = value),
                      title: Text(team['name']?.toString() ?? 'Team'),
                      subtitle: Text((team['tag'] ?? '').toString()),
                    )).toList()),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(dialogContext, selected), child: const Text('Continue')),
                  ],
                ),
              );
            },
          );
          if (choice == null) return;
          teamId = choice;
        }
      } catch (error) {
        if (mounted) showMessage(context, error.toString());
        return;
      }
    }

    setState(() => _joining.add(eventId));
    try {
      await KomnivoRepository.instance.registerForEvent(eventId, teamId: teamId);
      if (mounted) showMessage(context, 'Registration submitted. Check the event for its approval status.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _joining.remove(eventId));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) return ListView(padding: const EdgeInsets.all(20), children: const [
      PreviewBanner(),
      SectionTitle('Compete', subtitle: 'Scrims, tournaments and your match journey'),
      SizedBox(height: 14),
      _EventCard(name: 'KOMNIVO Open Series', game: 'Free Fire MAX · Squad', date: 'Registration open', prize: 'Community event'),
      _EventCard(name: 'Raipur Night Scrims', game: 'Free Fire MAX · Squad', date: 'Check-in soon', prize: 'Practice series'),
    ]);

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        return ListView(padding: const EdgeInsets.all(20), children: [
          const SectionTitle('Compete', subtitle: 'Find events and manage registrations'),
          const SizedBox(height: 14),
          if (snapshot.connectionState == ConnectionState.waiting) const Center(child: Padding(padding: EdgeInsets.all(36), child: CircularProgressIndicator()))
          else if (rows.isEmpty) const EmptyState(title: 'No open events', message: 'When organisers publish a scrim or tournament, it will appear here.', icon: Icons.emoji_events_outlined)
          else ...rows.map((row) {
            final eventId = row['id'] as String;
            final game = row['games'] is Map ? (row['games'] as Map)['name']?.toString() : 'Esports';
            final start = DateTime.tryParse(row['starts_at']?.toString() ?? '');
            final date = start == null ? 'Schedule pending' : start.toLocal().toString().substring(0, 16);
            return _EventCard(
              name: row['name']?.toString() ?? 'Tournament',
              game: '$game · ${row['format'] ?? 'squad'}',
              date: date,
              prize: '${row['capacity'] ?? 'Open'} slots',
              action: FilledButton(
                onPressed: _joining.contains(eventId) ? null : () => _register(row),
                child: Text(_joining.contains(eventId) ? 'Joining…' : 'Register'),
              ),
            );
          }),
        ]);
      },
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.name, required this.game, required this.date, required this.prize, this.action});
  final String name, game, date, prize;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 13),
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(19), border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFF2A244C), borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.emoji_events, color: KomnivoTheme.accent)),
        const SizedBox(width: 12),
        Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
        const Icon(Icons.more_horiz, color: KomnivoTheme.muted),
      ]),
      const SizedBox(height: 13),
      Text(game, style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Row(children: [
        const Icon(Icons.calendar_month_outlined, size: 15, color: KomnivoTheme.muted),
        const SizedBox(width: 5), Text(date, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
        const Spacer(), Text(prize, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ]),
      if (action != null) ...[const SizedBox(height: 14), SizedBox(width: double.infinity, child: action!)],
    ]),
  );
}
