import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../liveops/liveops_screen.dart';

class MatchDetailScreen extends StatefulWidget {
  const MatchDetailScreen({super.key, required this.matchId});
  final String matchId;

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> {
  late Future<_MatchDetailData> _future;
  bool _busy = false;

  SupabaseClient get _client => Supabase.instance.client;
  String get _userId => _client.auth.currentUser!.id;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_MatchDetailData> _load() async {
    final results = await Future.wait([
      _client.from('matches')
        .select('*, events(id,name,format,scoring_config,game_id), match_participants(team_id,registration_id,check_in_status,teams(name,tag))')
        .eq('id', widget.matchId)
        .single(),
      _client.from('match_results')
        .select('*, teams(name,tag)')
        .eq('match_id', widget.matchId)
        .order('submitted_at', ascending: false),
      _client.from('match_checkins')
        .select('match_id,user_id,status,checked_in_at')
        .eq('match_id', widget.matchId)
        .eq('user_id', _userId)
        .maybeSingle(),
      _client.from('room_credentials')
        .select('room_code,room_password,release_at')
        .eq('match_id', widget.matchId)
        .maybeSingle(),
      _client.from('team_members')
        .select('team_id,role,teams(name,tag)')
        .eq('user_id', _userId),
      _client.from('opponent_confirmations')
        .select('result_id,confirming_team_id,decision,note,confirmed_by')
        .order('created_at'),
    ]);

    return _MatchDetailData(
      match: Map<String, dynamic>.from(results[0] as Map),
      results: List<Map<String, dynamic>>.from(results[1] as List),
      checkIn: results[2] == null ? null : Map<String, dynamic>.from(results[2] as Map),
      room: results[3] == null ? null : Map<String, dynamic>.from(results[3] as Map),
      myTeams: List<Map<String, dynamic>>.from(results[4] as List),
      confirmations: List<Map<String, dynamic>>.from(results[5] as List),
    );
  }

  void _refresh() => setState(() => _future = _load());

  Future<void> _checkIn() async {
    setState(() => _busy = true);
    try {
      final response = await _client.functions.invoke('check-in', body: {'match_id': widget.matchId});
      if (response.status < 200 || response.status >= 300) throw Exception('Check-in could not be completed.');
      _refresh();
      if (mounted) showMessage(context, 'You are checked in as ready.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitResult(_MatchDetailData data, List<Map<String, dynamic>> eligibleTeams) async {
    if (eligibleTeams.isEmpty) {
      showMessage(context, 'Only a registered team member can submit a match result.');
      return;
    }

    String? selectedTeamId = eligibleTeams.first['team_id'] as String;
    final placement = TextEditingController();
    final kills = TextEditingController(text: '0');
    PlatformFile? evidence;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Submit match result'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: selectedTeamId,
                decoration: const InputDecoration(labelText: 'Your registered team'),
                items: eligibleTeams.map((team) {
                  final details = team['teams'] is Map ? Map<String, dynamic>.from(team['teams'] as Map) : <String, dynamic>{};
                  return DropdownMenuItem(value: team['team_id'] as String, child: Text(details['name']?.toString() ?? 'Team'));
                }).toList(),
                onChanged: (value) => setDialogState(() => selectedTeamId = value),
              ),
              const SizedBox(height: 12),
              TextField(controller: placement, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Final placement', hintText: '1, 2, 3…')),
              const SizedBox(height: 12),
              TextField(controller: kills, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Team kills')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await FilePicker.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
                  );
                  if (picked.isNotEmpty) {
                    setDialogState(() => evidence = picked.first);
                  }
                },
                icon: const Icon(Icons.attach_file),
                label: Text(evidence?.name ?? 'Attach screenshot or PDF evidence'),
              ),
              const SizedBox(height: 6),
              const Text('Evidence is stored privately. OCR suggestions never become official points without organiser approval.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            ])),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final p = int.tryParse(placement.text);
                final k = int.tryParse(kills.text);
                Navigator.pop(dialogContext, p != null && p > 0 && k != null && k >= 0);
              },
              child: const Text('Submit result'),
            ),
          ],
        ),
      ),
    );

    final p = int.tryParse(placement.text);
    final k = int.tryParse(kills.text);
    if (confirmed != true || p == null || k == null || selectedTeamId == null || !mounted) {
      placement.dispose();
      kills.dispose();
      return;
    }

    setState(() => _busy = true);
    try {
      final evidencePaths = <String>[];
      if (evidence != null) {
        evidencePaths.add(await KomnivoRepository.instance.uploadEvidence(evidence!, widget.matchId));
      }

      final response = await _client.functions.invoke('submit-result', body: {
        'match_id': widget.matchId,
        'team_id': selectedTeamId,
        'placement': p,
        'kills': k,
        'evidence_paths': evidencePaths,
      });
      if (response.status < 200 || response.status >= 300) throw Exception('Result submission failed.');
      _refresh();
      if (mounted) showMessage(context, 'Result submitted for verification.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      placement.dispose();
      kills.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmOpponentResult(String resultId, String teamId, String decision) async {
    setState(() => _busy = true);
    try {
      final mine = await _client.from('team_members').select('team_id').eq('user_id', _userId);
      final teamIds = List<Map<String, dynamic>>.from(mine).map((row) => row['team_id'] as String).toSet();
      final eligible = (await _client.from('match_participants').select('team_id').eq('match_id', widget.matchId))
          .where((row) =>
              teamIds.contains(row['team_id'] as String) &&
              row['team_id'] != teamId)
          .toList();
      if (eligible.isEmpty) {
        throw Exception('You need a different registered team in this match to confirm this result.');
      }
      final confirmingTeamId = eligible.first['team_id'] as String;
      await _client.from('opponent_confirmations').insert({
        'result_id': resultId,
        'confirming_team_id': confirmingTeamId,
        'confirmed_by': _userId,
        'decision': decision,
        'note': decision == 'disputed' ? 'Opponent requested organiser review.' : '',
      });
      _refresh();
      if (mounted) showMessage(context, decision == 'confirmed' ? 'Opponent result confirmed.' : 'Result dispute submitted.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Match operations'), actions: [
        IconButton(onPressed: _refresh, tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
      ]),
      body: FutureBuilder<_MatchDetailData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(snapshot.error.toString())));
          final data = snapshot.data!;
          final match = data.match;
          final event = match['events'] is Map ? Map<String, dynamic>.from(match['events'] as Map) : <String, dynamic>{};
          final participants = (match['match_participants'] as List? ?? [])
              .map((row) => Map<String, dynamic>.from(row as Map)).toList();
          final participantTeamIds = participants.map((row) => row['team_id'] as String).toSet();
          final eligibleTeams = data.myTeams.where((row) => participantTeamIds.contains(row['team_id'])).toList();

          return ListView(padding: const EdgeInsets.all(20), children: [
            if (_busy) const LinearProgressIndicator(),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: const Color(0xFF282348),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .35)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(event['name']?.toString() ?? 'Tournament match', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 5),
                Text(
                  'Round ${match['round_number']} · ${match['group_label'] ?? 'Group pending'} · Match #${match['match_number']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.circle, size: 8, color: KomnivoTheme.cyan),
                  const SizedBox(width: 7),
                  Text((match['status'] ?? 'scheduled').toString().toUpperCase(), style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  if (match['starts_at'] != null) Text(DateTime.parse(match['starts_at'].toString()).toLocal().toString().substring(0, 16), style: const TextStyle(color: Colors.white70, fontSize: 10)),
                ]),
              ]),
            ),
            const SizedBox(height: 18),
            const SectionTitle('Registered teams', subtitle: 'This match uses the locked tournament roster'),
            const SizedBox(height: 8),
            ...participants.map((participant) {
              final team = participant['teams'] is Map ? Map<String, dynamic>.from(participant['teams'] as Map) : <String, dynamic>{};
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: const CircleAvatar(child: Icon(Icons.shield_outlined)),
                title: Text(team['name']?.toString() ?? 'Team'),
                subtitle: Text('${participant['check_in_status'] ?? 'pending'}'),
              );
            }),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Your match check-in', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                const SizedBox(height: 5),
                Text(data.checkIn?['status']?.toString().toUpperCase() ?? 'NOT CHECKED IN', style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800, fontSize: 12)),
                const SizedBox(height: 12),
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: _busy || eligibleTeams.isEmpty || data.checkIn?['status'] == 'ready' ? null : _checkIn,
                  icon: const Icon(Icons.how_to_reg_outlined),
                  label: Text(data.checkIn?['status'] == 'ready' ? 'Checked in' : 'Check in as ready'),
                )),
                if (eligibleTeams.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 8), child: Text('You are not on an approved team roster for this match.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11))),
              ]),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Room credentials', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                const SizedBox(height: 6),
                if (data.room == null)
                  const Text('Room ID and password will appear here when the organiser releases them.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12))
                else ...[
                  _Credential(label: 'Room ID', value: data.room!['room_code']?.toString() ?? '—'),
                  const SizedBox(height: 8),
                  _Credential(label: 'Password', value: data.room!['room_password']?.toString().isNotEmpty == true ? data.room!['room_password'].toString() : 'No password'),
                  const SizedBox(height: 6),
                  Text('Released at ${DateTime.parse(data.room!['release_at'].toString()).toLocal()}', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                ],
              ]),
            ),
            const SizedBox(height: 14),
            if (eligibleTeams.isNotEmpty)
              FilledButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('LiveOps Assistant')),
                  body: LiveOpsScreen(preview: false, initialMatchId: widget.matchId, onBack: () => Navigator.pop(context)),
                ))),
                icon: const Icon(Icons.radar),
                label: const Text('Start same-phone LiveOps'),
              ),
            const SizedBox(height: 18),
            SectionTitle('Result submissions', subtitle: 'Opponent confirmation and organiser approval control official scores', trailing: eligibleTeams.isEmpty ? null : FilledButton.icon(
              onPressed: _busy ? null : () => _submitResult(data, eligibleTeams),
              icon: const Icon(Icons.upload_file),
              label: const Text('Submit result'),
            )),
            const SizedBox(height: 8),
            if (data.results.isEmpty)
              const EmptyState(title: 'No results submitted', message: 'A registered team can submit placement, kills and supporting evidence.')
            else
              ...data.results.map((result) {
                final team = result['teams'] is Map ? Map<String, dynamic>.from(result['teams'] as Map) : <String, dynamic>{};
                final teamId = result['team_id'] as String;
                final isOwn = eligibleTeams.any((row) => row['team_id'] == teamId);
                final confirmations = data.confirmations.where((row) => row['result_id'] == result['id']).toList();
                final myTeamIds = eligibleTeams.map((row) => row['team_id']).toSet();
                final alreadyConfirmed = confirmations.any((row) => myTeamIds.contains(row['confirming_team_id']));
                return Container(
                  margin: const EdgeInsets.only(bottom: 9),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: KomnivoTheme.line)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(team['name']?.toString() ?? 'Team result', style: const TextStyle(fontWeight: FontWeight.w900))),
                      Text((result['status'] ?? 'submitted').toString().toUpperCase(), style: TextStyle(color: result['status'] == 'approved' ? KomnivoTheme.cyan : KomnivoTheme.muted, fontSize: 9, fontWeight: FontWeight.w900)),
                    ]),
                    const SizedBox(height: 7),
                    Text('Placement ${result['placement'] ?? '—'} · ${result['kills']} kills · ${result['points']} points', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
                    if (!isOwn && eligibleTeams.isNotEmpty && result['status'] != 'approved' && !alreadyConfirmed) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(child: OutlinedButton.icon(
                          onPressed: _busy ? null : () => _confirmOpponentResult(result['id'] as String, teamId, 'disputed'),
                          icon: const Icon(Icons.flag_outlined),
                          label: const Text('Dispute'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: FilledButton.icon(
                          onPressed: _busy ? null : () => _confirmOpponentResult(result['id'] as String, teamId, 'confirmed'),
                          icon: const Icon(Icons.verified_outlined),
                          label: const Text('Confirm'),
                        )),
                      ]),
                    ],
                    if (confirmations.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 8), child: Text('${confirmations.length} opponent confirmation(s)', style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 10))),
                  ]),
                );
              }),
            const SizedBox(height: 20),
            const Text('KOMNIVO never turns OCR text into official match points automatically. The organiser verifies the submission before standings update.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.45)),
          ]);
        },
      ),
    );
  }
}

class _MatchDetailData {
  const _MatchDetailData({
    required this.match,
    required this.results,
    required this.checkIn,
    required this.room,
    required this.myTeams,
    required this.confirmations,
  });
  final Map<String, dynamic> match;
  final List<Map<String, dynamic>> results;
  final Map<String, dynamic>? checkIn;
  final Map<String, dynamic>? room;
  final List<Map<String, dynamic>> myTeams;
  final List<Map<String, dynamic>> confirmations;
}

class _Credential extends StatelessWidget {
  const _Credential({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Row(children: [
    SizedBox(width: 82, child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11))),
    Expanded(child: SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: .5))),
    IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Copy',
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) showMessage(context, '$label copied.');
      },
      icon: const Icon(Icons.copy_outlined, size: 16),
    ),
  ]);
}
