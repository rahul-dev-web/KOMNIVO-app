import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../teams/teams_screen.dart';
import 'event_operations_screen.dart';

class OrganizerScreen extends StatefulWidget {
  const OrganizerScreen({super.key, required this.preview, this.onBack});
  final bool preview;
  final VoidCallback? onBack;
  @override
  State<OrganizerScreen> createState() => _OrganizerScreenState();
}

class _OrganizerScreenState extends State<OrganizerScreen> {
  final _name = TextEditingController();
  final _capacity = TextEditingController(text: '48');
  bool _busy = false;
  String _status = 'Create an event and manage its competition flow from one workspace.';
  Future<List<Map<String, dynamic>>>? _eventsFuture;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _eventsFuture = _loadEvents();
  }

  Future<List<Map<String, dynamic>>> _loadEvents() async {
    final client = Supabase.instance.client;
    final rows = await client.from('events').select('*, games(name,code)')
      .eq('organizer_id', client.auth.currentUser!.id)
      .order('created_at', ascending: false).limit(30);
    return List<Map<String, dynamic>>.from(rows);
  }

  void _reloadEvents() => setState(() => _eventsFuture = _loadEvents());

  Future<void> _publish() async {
    if (_name.text.trim().isEmpty) { showMessage(context, 'Enter an event name.'); return; }
    setState(() => _busy = true);
    try {
      final event = await KomnivoRepository.instance.createEvent(
        name: _name.text.trim(),
        gameId: freeFireGameId,
        startsAt: DateTime.now().add(const Duration(days: 7)),
        capacity: int.tryParse(_capacity.text) ?? 48,
        scoring: {
          'kill_point': 1,
          'placement_points': {'1': 12, '2': 9, '3': 8, '4': 7, '5': 6, '6': 5, '7': 4, '8': 3, '9': 2, '10': 1},
        },
      );
      setState(() => _status = 'Published: ${event['name']}');
      _name.clear();
      _reloadEvents();
    } catch (error) { setState(() => _status = error.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void dispose() { _name.dispose(); _capacity.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      SectionTitle('Organiser workspace', subtitle: 'Event operations, approvals and moderation', trailing: widget.onBack == null ? null : IconButton(onPressed: widget.onBack, icon: const Icon(Icons.close))),
      const SizedBox(height: 16),
      if (widget.preview) const PreviewBanner(),
      GridView.count(
        crossAxisCount: MediaQuery.sizeOf(context).width > 760 ? 3 : 1,
        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: MediaQuery.sizeOf(context).width > 760 ? 2.2 : 3.4,
        crossAxisSpacing: 10, mainAxisSpacing: 10,
        children: const [
          _DeskStat(icon: Icons.event_available, label: 'Event setup', value: 'Ready'),
          _DeskStat(icon: Icons.fact_check_outlined, label: 'Result review', value: 'Human approval'),
          _DeskStat(icon: Icons.history, label: 'Audit trail', value: 'Enabled'),
        ],
      ),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Publish an event', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 7),
          const Text('Free Fire MAX · Squad · IND region · seven-day default schedule', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
          const SizedBox(height: 14),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Event name')),
          const SizedBox(height: 12),
          TextField(controller: _capacity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Team capacity')),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: widget.preview || _busy ? null : _publish, icon: const Icon(Icons.publish), label: Text(_busy ? 'Publishing…' : 'Publish event'))),
          const SizedBox(height: 10),
          Text(_status, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
        ]),
      ),
      const SizedBox(height: 22),
      SectionTitle('Your events', subtitle: 'Manage registrations, matches, room access and verified results', trailing: IconButton(onPressed: widget.preview ? null : _reloadEvents, icon: const Icon(Icons.refresh))),
      const SizedBox(height: 10),
      if (widget.preview)
        const _EventPreviewRow()
      else
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _eventsFuture,
          builder: (context, snapshot) {
            final events = snapshot.data ?? [];
            if (snapshot.connectionState == ConnectionState.waiting) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
            if (events.isEmpty) return const EmptyState(title: 'No events created', message: 'Publish your first event above to open its complete operations desk.');
            return Column(children: events.map((event) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(17), border: Border.all(color: KomnivoTheme.line)),
              child: Row(children: [
                Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFF282348), borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.emoji_events, color: KomnivoTheme.accent)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(event['name']?.toString() ?? 'Event', style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text('${event['status']} · ${event['capacity']} slots · ${event['starts_at']}', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                ])),
                IconButton(
                  tooltip: 'Open event operations',
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EventOperationsScreen(event: event))),
                  icon: const Icon(Icons.open_in_new, color: KomnivoTheme.cyan),
                ),
              ]),
            )).toList());
          },
        ),
      const SizedBox(height: 18),
      const Text('Platform operations', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      const SizedBox(height: 10),
      const _ModuleRow(icon: Icons.people_alt_outlined, title: 'Registration & roster control', detail: 'Approvals, waitlists, check-in and roster locks'),
      const _ModuleRow(icon: Icons.account_tree_outlined, title: 'Groups, rounds & schedules', detail: 'Tournament structure and match allocation'),
      const _ModuleRow(icon: Icons.meeting_room_outlined, title: 'Room access', detail: 'Time and eligibility-controlled room details'),
      const _ModuleRow(icon: Icons.fact_check_outlined, title: 'Evidence and disputes', detail: 'Review OCR candidates, evidence and opponent confirmation'),
      const _ModuleRow(icon: Icons.leaderboard_outlined, title: 'Scoring and qualification', detail: 'Deterministic points, tie-breakers and standings'),
    ]);
  }
}

class _EventPreviewRow extends StatelessWidget {
  const _EventPreviewRow();
  @override
  Widget build(BuildContext context) => const _ModuleRow(
    icon: Icons.emoji_events_outlined,
    title: 'KOMNIVO Open Series',
    detail: 'Preview event operations — connect Supabase to manage real registrations and matches.',
  );
}

class _DeskStat extends StatelessWidget {
  const _DeskStat({required this.icon, required this.label, required this.value});
  final IconData icon; final String label, value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(17), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [Icon(icon, color: KomnivoTheme.cyan), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)), const SizedBox(height: 4), Text(value, style: const TextStyle(fontWeight: FontWeight.w800))]))]),
  );
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({required this.icon, required this.title, required this.detail});
  final IconData icon; final String title, detail;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 9), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [Icon(icon, color: KomnivoTheme.accent), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 3), Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11))]))]),
  );
}
