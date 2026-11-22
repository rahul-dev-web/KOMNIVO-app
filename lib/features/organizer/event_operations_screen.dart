import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../community/role_management_screen.dart';
import '../liveops/liveops_screen.dart';

class EventOperationsScreen extends StatefulWidget {
  const EventOperationsScreen({super.key, required this.event});
  final Map<String, dynamic> event;

  @override
  State<EventOperationsScreen> createState() => _EventOperationsScreenState();
}

class _EventOperationsScreenState extends State<EventOperationsScreen> {
  late Future<_EventData> _future;
  bool _busy = false;
  final Set<String> _selectedMatchIds = <String>{};
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
        .select('*, teams(name,tag), matches!inner(id,event_id,match_number)')
        .eq('matches.event_id', eventId).order('submitted_at', ascending: false),
      _client.from('event_rounds')
        .select('*, event_groups(id,label,sort_order,event_group_teams(team_id,teams(name,tag)))')
        .eq('event_id', eventId).order('round_number'),
      _client.from('opponent_confirmations')
        .select('*, match_results!inner(id,match_id,team_id,matches!inner(id,event_id,match_number))')
        .eq('match_results.matches.event_id', eventId)
        .eq('decision', 'disputed')
        .order('created_at', ascending: false),
      _client.from('event_lobbies')
        .select('id,lobby_code,lobby_number,status,event_lobby_matches(sequence_no,match_id,matches(match_number,match_code))')
        .eq('event_id', eventId)
        .order('lobby_number'),
      _client.from('result_candidates')
        .select('id,match_id,team_id,candidate_placement,candidate_kills,reviewed_placement,reviewed_kills,review_status,review_note,created_at,teams(name,tag),matches!inner(id,event_id,match_number),result_candidate_evidence(id,reported_placement,reported_kills,liveops_captures(sequence_no,evidence_path,content_type))')
        .eq('matches.event_id', eventId)
        .order('created_at', ascending: false),
      _client.from('event_test_registrations')
        .select('*, teams(name,tag), event_test_registration_players(user_id)')
        .eq('event_id', eventId).order('created_at', ascending: false),
      _client.from('channels')
        .select('id,name,group_id,stage_id')
        .eq('event_id', eventId).like('name', '%-idp'),
    ]);
    final matches = List<Map<String, dynamic>>.from(results[1] as List);
    const eventKeys = [
      'event.manage',
      'event.registrations.manage',
      'event.roster.lock',
      'event.matches.manage',
      'event.matches.operate',
      'event.results.review',
      'event.disputes.review',
      'event.standings.publish',
    ];
    final eventValues = await Future.wait(eventKeys.map((key) =>
      KomnivoRepository.instance.hasPermission(
        permissionKey: key, scopeType: 'event', scopeId: eventId,
      ),
    ));
    final eventPermissions = Map<String, bool>.fromIterables(eventKeys, eventValues);

    const matchKeys = [
      'match.operate',
      'match.credentials.release',
      'match.results.review',
      'match.disputes.review',
    ];
    final matchPermissionEntries = await Future.wait(matches.map((match) async {
      final id = match['id'].toString();
      final values = await Future.wait(matchKeys.map((key) =>
        KomnivoRepository.instance.hasPermission(
          permissionKey: key, scopeType: 'match', scopeId: id,
        ),
      ));
      return MapEntry(id, Map<String, bool>.fromIterables(matchKeys, values));
    }));

    return _EventData(
      registrations: List<Map<String, dynamic>>.from(results[0] as List),
      matches: matches,
      results: List<Map<String, dynamic>>.from(results[2] as List),
      rounds: List<Map<String, dynamic>>.from(results[3] as List),
      disputedConfirmations: List<Map<String, dynamic>>.from(results[4] as List),
      lobbies: List<Map<String, dynamic>>.from(results[5] as List),
      ocrCandidates: List<Map<String, dynamic>>.from(results[6] as List),
      testRegistrations: List<Map<String, dynamic>>.from(results[7] as List),
      groupIdpChannels: List<Map<String, dynamic>>.from(results[8] as List),
      eventPermissions: eventPermissions,
      matchPermissions: Map<String, Map<String, bool>>.fromEntries(matchPermissionEntries),
    );
  }

  void _reload() => setState(() => _future = _load());

  bool _canEvent(_EventData data, String key) => data.eventPermissions[key] == true;

  bool _canMatch(_EventData data, String? matchId, String key) =>
      matchId != null && data.matchPermissions[matchId]?[key] == true;

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

  Future<void> _reviewTestRegistration(String id, String status) async {
    final note = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Mark test registration $status?'),
        content: TextField(
          controller: note,
          maxLength: 500,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Review note (optional)',
            hintText: 'Add a short note for the test submitter and audit trail.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text('Mark $status')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      note.dispose();
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.rpc('review_event_test_registration', params: {
        'p_test_registration_id': id,
        'p_status': status,
        'p_review_note': note.text.trim(),
      });
      _reload();
      if (mounted) showMessage(context, 'Test registration marked $status. No real slots or standings were changed.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      note.dispose();
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

  Future<List<String>?> _selectDirectInviteTeams({
    required int targetRoundNumber,
  }) async {
    final eventId = widget.event['id'].toString();
    final rows = await _client
        .from('event_registrations')
        .select('team_id, teams!inner(name,tag,game_id)')
        .eq('event_id', eventId)
        .inFilter('status', ['approved', 'checked_in'])
        .eq('roster_locked', true)
        .not('team_id', 'is', null)
        .order('registered_at');
    final gameId = widget.event['game_id']?.toString();
    final candidatesById = <String, Map<String, dynamic>>{};
    for (final raw in rows as List) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final team = row['teams'] is Map
          ? Map<String, dynamic>.from(row['teams'] as Map)
          : <String, dynamic>{};
      final id = row['team_id']?.toString() ?? '';
      if (id.isEmpty || (gameId != null && team['game_id']?.toString() != gameId)) continue;
      candidatesById[id] = {'id': id, ...team};
    }
    final candidates = candidatesById.values.toList()
      ..sort((a, b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    if (candidates.isEmpty) {
      throw StateError('No approved, roster-locked teams for this event and game are available.');
    }

    final current = await _client.from('event_stage_direct_invites')
        .select('team_id')
        .eq('event_id', eventId)
        .eq('target_round_number', targetRoundNumber);
    final assigned = <String>{for (final row in current as List) row['team_id'].toString()};
    final selected = <String>{};

    return showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Add direct-entry teams · Stage $targetRoundNumber'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Selected teams enter this stage directly. They will not be counted as qualifiers from the previous stage. Existing assignments are shown separately.'),
                const SizedBox(height: 8),
                ...candidates.map((team) {
                  final id = team['id'].toString();
                  final alreadyAssigned = assigned.contains(id);
                  return CheckboxListTile(
                    value: selected.contains(id),
                    onChanged: alreadyAssigned ? null : (value) => setDialogState(() {
                      if (value == true) selected.add(id); else selected.remove(id);
                    }),
                    title: Text(team['name']?.toString() ?? 'Team'),
                    subtitle: Text('${team['tag'] ?? ''}${alreadyAssigned ? ' · Already assigned to this stage' : ''}'),
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                }),
                const SizedBox(height: 8),
                Text('${selected.length} teams selected'),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: selected.isNotEmpty ? () => Navigator.pop(dialogContext, selected.toList()) : null,
              child: const Text('Add to selected stage'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _assignDirectEntryTeams() async {
    final config = widget.event['event_config'] is Map
        ? Map<String, dynamic>.from(widget.event['event_config'] as Map)
        : <String, dynamic>{};
    final stageCount = int.tryParse(config['stage_count']?.toString() ?? '') ?? 0;
    if (stageCount < 1) {
      showMessage(context, 'Set the tournament stage count before assigning direct-entry teams.');
      return;
    }
    final stageNames = config['stage_names'] is List ? config['stage_names'] as List : const [];
    final selectedRound = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose direct-entry stage'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: List.generate(stageCount, (index) {
            final label = index < stageNames.length && stageNames[index].toString().trim().isNotEmpty
                ? stageNames[index].toString()
                : 'Stage ${index + 1}';
            return ListTile(
              title: Text(label),
              subtitle: Text('Direct entry into stage ${index + 1}'),
              onTap: () => Navigator.pop(dialogContext, index + 1),
            );
          })),
        ),
      ),
    );
    if (selectedRound == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final selected = await _selectDirectInviteTeams(targetRoundNumber: selectedRound);
      if (selected == null || selected.isEmpty || !mounted) return;
      final result = await _client.rpc('set_event_stage_direct_invites', params: {
        'p_event_id': widget.event['id'],
        'p_target_round_number': selectedRound,
        'p_team_ids': selected,
      });
      _reload();
      if (mounted) showMessage(context,
        '${result['assigned_count']} team(s) added to Stage $selectedRound. Republish the complete tournament roadmap before progression.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishCompleteRoadmap() async {
    final event = widget.event;
    final config = event['event_config'] is Map
        ? Map<String, dynamic>.from(event['event_config'] as Map)
        : <String, dynamic>{};
    final stageCount = int.tryParse(config['stage_count']?.toString() ?? '') ?? 0;
    if (stageCount < 1 || stageCount > 16) {
      showMessage(context, 'The tournament must have 1–16 configured stages before publication.');
      return;
    }
    final oldRoadmap = config['roadmap'] is Map
        ? Map<String, dynamic>.from(config['roadmap'] as Map)
        : <String, dynamic>{};
    final stageNames = config['stage_names'] is List ? config['stage_names'] as List : const [];
    final directCounts = <int, int>{};
    final mapped = await _client.from('event_stage_direct_invites')
        .select('target_round_number').eq('event_id', event['id']);
    for (final row in mapped as List) {
      final round = int.tryParse(row['target_round_number'].toString()) ?? 0;
      directCounts[round] = (directCounts[round] ?? 0) + 1;
    }

    final fields = <Map<String, TextEditingController>>[];
    for (var index = 0; index < stageCount; index++) {
      final round = index + 1;
      final isFinal = round == stageCount;
      final oldName = index < stageNames.length ? stageNames[index].toString() : '';
      fields.add({
        'stage_name': TextEditingController(text: oldName),
        'stage_type': TextEditingController(text: isFinal ? 'final' : (round == 1 ? 'qualifier' : 'custom')),
        'group_size': TextEditingController(text: round == 1 ? oldRoadmap['group_size']?.toString() ?? '' : ''),
        'qualifiers_per_group': TextEditingController(text: isFinal ? '0' : (round == 1 ? oldRoadmap['qualifiers_per_group']?.toString() ?? '' : '')),
        'qualified_team_count': TextEditingController(text: round == 1 ? oldRoadmap['qualified_team_count']?.toString() ?? '' : (isFinal ? '0' : '')),
        'matches_per_group': TextEditingController(),
        'interval_minutes': TextEditingController(),
        'first_match_at': TextEditingController(text: round == 1 ? event['starts_at']?.toString() ?? '' : ''),
      });
    }

    final payload = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Publish complete tournament roadmap'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Configure every stage below. One publish action stores the complete stage-to-stage plan. Dates must be future ISO-8601 timestamps with an explicit timezone, for example 2026-12-01T18:00:00+05:30.'),
                const SizedBox(height: 12),
                ...List.generate(stageCount, (index) {
                  final round = index + 1;
                  final item = fields[index];
                  Widget field(String key, String label, String hint) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(controller: item[key],
                      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true)),
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Stage $round · ${directCounts[round] ?? 0} direct-entry teams',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        field('stage_name', 'Stage name', 'e.g. Qualifier / Semi Final / Final'),
                        field('stage_type', 'Stage type', 'qualifier / quarter_final / semi_final / final / grand_final / custom'),
                        field('group_size', 'Teams per group', '2–24'),
                        field('qualifiers_per_group', 'Qualifiers per group', round == stageCount ? '0 for final' : '1–group size'),
                        field('qualified_team_count', 'Expected qualified team count', round == stageCount ? '0' : 'Total advancing from this stage'),
                        field('matches_per_group', 'Matches per group', '1–20'),
                        field('interval_minutes', 'Minutes between matches', '1–240'),
                        field('first_match_at', 'First match timestamp (ISO-8601)', 'YYYY-MM-DDTHH:mm:ss+05:30'),
                        const Divider(),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              try {
                final rows = <Map<String, dynamic>>[];
                for (var i = 0; i < fields.length; i++) {
                  final item = fields[i];
                  final round = i + 1;
                  int parse(String key) {
                    final value = int.tryParse(item[key]!.text.trim());
                    if (value == null) throw FormatException('Complete Stage $round: ${key.replaceAll('_', ' ')}.');
                    return value;
                  }
                  final name = item['stage_name']!.text.trim();
                  final type = item['stage_type']!.text.trim();
                  final firstAt = item['first_match_at']!.text.trim();
                  if (name.isEmpty || type.isEmpty || DateTime.tryParse(firstAt) == null) {
                    throw FormatException('Complete Stage $round name, type and first-match timestamp.');
                  }
                  rows.add({
                    'round_number': round, 'stage_name': name, 'stage_type': type,
                    'group_size': parse('group_size'),
                    'qualifiers_per_group': parse('qualifiers_per_group'),
                    'qualified_team_count': parse('qualified_team_count'),
                    'direct_entry_count': directCounts[round] ?? 0,
                    'matches_per_group': parse('matches_per_group'),
                    'interval_minutes': parse('interval_minutes'),
                    'first_match_at': firstAt,
                  });
                }
                Navigator.pop(dialogContext, rows);
              } catch (error) {
                showMessage(context, error.toString());
              }
            },
            child: const Text('Publish all stages'),
          ),
        ],
      ),
    );

    for (final item in fields) {
      for (final controller in item.values) {
        controller.dispose();
      }
    }
    if (payload == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await _client.rpc('publish_event_roadmap', params: {
        'p_event_id': event['id'],
        'p_stage_configs': payload,
      });
      _reload();
      if (mounted) showMessage(context,
        'Complete roadmap v${result['roadmap_version']} published across ${result['stage_count']} stages.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateRoadmap() async {
    setState(() => _busy = true);
    try {
      final eventId = widget.event['id'].toString();
      final row = await _client.from('event_stage_roadmaps')
          .select('configuration').eq('event_id', eventId).eq('round_number', 1).maybeSingle();
      if (row == null) throw StateError('Publish the complete roadmap before generating Stage 1.');
      final cfg = Map<String, dynamic>.from(row['configuration'] as Map);
      final result = await _client.rpc('generate_event_roadmap', params: {
        'p_event_id': eventId,
        'p_matches_per_group': cfg['matches_per_group'],
        'p_interval_minutes': cfg['interval_minutes'],
      });
      _reload();
      if (mounted) showMessage(context,
        'Stage 1 generated: ${result['group_count']} groups · ${result['matches_created']} matches. Its schedule is published from the full roadmap.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _advanceRoadmapStage(Map<String, dynamic> stage) async {
    final nextRound = (stage['round_number'] as int? ?? 1) + 1;
    setState(() => _busy = true);
    try {
      final target = await _client.from('event_stage_roadmaps')
          .select('configuration').eq('event_id', widget.event['id']).eq('round_number', nextRound).maybeSingle();
      if (target == null) throw StateError('Stage $nextRound roadmap is missing. Publish the complete stage-to-stage roadmap before qualifying.');
      final cfg = Map<String, dynamic>.from(target['configuration'] as Map);
      final result = await _client.rpc('advance_event_stage_from_roadmap', params: {
        'p_source_stage_id': stage['id'],
        'p_matches_per_group': cfg['matches_per_group'],
        'p_interval_minutes': cfg['interval_minutes'],
        'p_first_match_at': cfg['first_match_at'],
      });
      _reload();
      if (mounted) showMessage(context,
        'Stage $nextRound generated: ${result['group_count']} groups · ${result['matches_created']} matches. Schedule published automatically.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishStageSchedule(String stageId) async {
    setState(() => _busy = true);
    try {
      final result = await _client.rpc('publish_event_stage_schedule', params: {'p_stage_id': stageId});
      _reload();
      if (mounted) showMessage(context,
        'Schedule version ${result['schedule_version']} published. Only affected group/team participants were notified.');
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

  Future<void> _createLobby(List<Map<String, dynamic>> matches) async {
    // Preserve the schedule order returned by the database, not checkbox tap order.
    final matchIds = matches
        .where((match) => _selectedMatchIds.contains(match['id']?.toString()))
        .map((match) => match['id'].toString())
        .toList();
    if (matchIds.isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await KomnivoRepository.instance.createEventLobby(
        eventId: widget.event['id'].toString(),
        matchIds: matchIds,
        idempotencyKey: 'lobby_${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 24)}',
      );
      if (!mounted) return;
      setState(() => _selectedMatchIds.clear());
      _reload();
      showMessage(
        context,
        'Lobby ${result['lobby_code']} created for ${matchIds.length} matches. Lobby ID: ${result['lobby_id']}',
      );
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startLiveOps(Map<String, dynamic> lobby) async {
    final lobbyId = lobby['id']?.toString();
    if (lobbyId == null || lobbyId.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('LiveOps · ${lobby['lobby_code'] ?? 'Lobby'}')),
          body: LiveOpsScreen(
            preview: false,
            initialLobbyId: lobbyId,
            onBack: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
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
      final releaseAt = DateTime.now()
          .add(const Duration(minutes: 10))
          .toUtc()
          .toIso8601String();
      await _client.rpc('publish_match_room_credentials', params: {
        'p_match_id': matchId,
        'p_room_code': code.text.trim(),
        'p_room_password': password.text.trim(),
        'p_release_at': releaseAt,
      });
      _reload();
      if (mounted) {
        showMessage(
          context,
          'Room details securely scheduled. Only eligible participants can view them after release.',
        );
      }
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

  Future<void> _reviewLiveOpsCandidate(
    String candidateId,
    String decision, {
    int? reviewedPlacement,
    int? reviewedKills,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await KomnivoRepository.instance.reviewLiveOpsTeamCandidate(
        candidateId: candidateId,
        decision: decision,
        note: decision == 'accepted'
            ? 'Reviewer confirmed final placement and kills against linked screenshot evidence.'
            : 'Reviewer rejected the provisional OCR candidate after evidence inspection.',
        reviewedPlacement: reviewedPlacement,
        reviewedKills: reviewedKills,
      );
      _reload();
      if (mounted) {
        showMessage(
          context,
          decision == 'accepted'
              ? 'OCR candidate accepted with reviewer-confirmed values. Official match result and standings are unchanged.'
              : 'OCR candidate rejected. Official match result and standings are unchanged.',
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<Map<String, dynamic>>> _loadOcrEvidencePreviews(
    Map<String, dynamic> row,
  ) async {
    final evidence = (row['result_candidate_evidence'] as List? ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final previews = <Map<String, dynamic>>[];
    for (final item in evidence) {
      final capture = item['liveops_captures'] is Map
          ? Map<String, dynamic>.from(item['liveops_captures'] as Map)
          : <String, dynamic>{};
      final path = capture['evidence_path']?.toString();
      String? signedUrl;
      String? previewError;
      if (path == null || path.isEmpty) {
        previewError = 'Screenshot storage reference is missing.';
      } else {
        try {
          // The bucket remains private. RLS grants access only to the uploader
          // or a result reviewer authorised for this exact Match ID.
          signedUrl = await _client.storage
              .from('match-evidence')
              .createSignedUrl(path, 900);
        } catch (error) {
          previewError = 'Preview unavailable: ${error.toString()}';
        }
      }
      previews.add(<String, dynamic>{
        'sequence_no': capture['sequence_no'],
        'content_type': capture['content_type'],
        'reported_placement': item['reported_placement'],
        'reported_kills': item['reported_kills'],
        'signed_url': signedUrl,
        'preview_error': previewError,
      });
    }
    return previews;
  }

  Widget _ocrEvidenceGallery(List<Map<String, dynamic>> previews) {
    if (previews.isEmpty) {
      return const Text(
        'No linked screenshot evidence was returned for this candidate.',
        style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Source screenshots',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
        ),
        const SizedBox(height: 8),
        ...previews.map((item) {
          final url = item['signed_url']?.toString();
          final contentType = item['content_type']?.toString() ?? '';
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: KomnivoTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: KomnivoTheme.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Screenshot ${item['sequence_no'] ?? '—'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Text(
                      'OCR P${item['reported_placement'] ?? '—'} / K${item['reported_kills'] ?? '—'}',
                      style: const TextStyle(
                        color: KomnivoTheme.cyan,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                if (url != null && url.isNotEmpty && contentType.startsWith('image/'))
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      url,
                      width: double.infinity,
                      height: 190,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Container(
                        height: 100,
                        width: double.infinity,
                        alignment: Alignment.center,
                        color: const Color(0xFF191E2C),
                        child: const Text(
                          'Screenshot preview failed to load. Reopen the review to request a fresh secure link.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    height: 90,
                    width: double.infinity,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF191E2C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item['preview_error']?.toString() ??
                          'No image preview is available for this evidence.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: KomnivoTheme.muted,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
        const SizedBox(height: 4),
      ],
    );
  }

  Future<void> _rejectOcrCandidate(Map<String, dynamic> row) async {
    try {
      final previews = await _loadOcrEvidencePreviews(row);
      if (!mounted) return;
      if (previews.isEmpty ||
          previews.any((item) => (item['signed_url']?.toString() ?? '').isEmpty)) {
        showMessage(context, 'All source screenshots must be available before rejecting this OCR candidate. Check private Match Evidence access and retry.');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Review screenshot evidence before rejection'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Inspect the original source images and the values transcribed from each one before rejecting this candidate.',
                    style: TextStyle(fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  _ocrEvidenceGallery(previews),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Reject candidate'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _reviewLiveOpsCandidate(row['id'].toString(), 'rejected');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, 'Could not load candidate screenshots: $error');
      }
    }
  }

  Future<void> _acceptOcrCandidate(Map<String, dynamic> row) async {
    final placement = TextEditingController(
      text: (row['candidate_placement'] ?? '').toString(),
    );
    final kills = TextEditingController(
      text: (row['candidate_kills'] ?? '').toString(),
    );
    try {
      final previews = await _loadOcrEvidencePreviews(row);
      if (!mounted) return;
      if (previews.isEmpty ||
          previews.any((item) => (item['signed_url']?.toString() ?? '').isEmpty)) {
        showMessage(context, 'All source screenshots must be available before accepting this OCR candidate. Check private Match Evidence access and retry.');
        return;
      }
      final values = await showDialog<Map<String, int>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Confirm final match values'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Compare the original screenshots and the transcribed values. Reviewer-confirmed placement/kills are saved separately from the original OCR/operator readings.',
                    style: TextStyle(fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  _ocrEvidenceGallery(previews),
                  const Divider(height: 22),
                  TextField(
                controller: placement,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Final placement'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: kills,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Final kills'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final finalPlacement = int.tryParse(placement.text.trim());
                final finalKills = int.tryParse(kills.text.trim());
                if (finalPlacement == null || finalPlacement < 1 ||
                    finalKills == null || finalKills < 0 || finalKills > 999) {
                  showMessage(context, 'Enter a valid placement and kill count.');
                  return;
                }
                Navigator.of(dialogContext).pop({
                  'placement': finalPlacement,
                  'kills': finalKills,
                });
              },
              child: const Text('Confirm values'),
            ),
          ],
        ),
      );
      if (values == null || !mounted) return;
      await _reviewLiveOpsCandidate(
        row['id'].toString(),
        'accepted',
        reviewedPlacement: values['placement'],
        reviewedKills: values['kills'],
      );
    } finally {
      placement.dispose();
      kills.dispose();
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
        IconButton(
          tooltip: 'Event staff and scopes',
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => EventStaffManagementScreen(
              eventId: widget.event['id'].toString(),
              eventName: eventName,
            )),
          ),
          icon: const Icon(Icons.badge_outlined),
        ),
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
            if (_canEvent(data, 'event.registrations.manage'))
            SectionTitle('Registration review', subtitle: 'Approve, waitlist or reject team applications', trailing: Text('${pending.length} pending', style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800))),
            const SizedBox(height: 10),
            if (pending.isEmpty) const EmptyState(title: 'No registrations awaiting review', message: 'New applications will appear here.')
            else ...pending.map((row) {
              final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
              return _OperationCard(
                title: team['name']?.toString() ?? 'Solo player registration',
                subtitle: '${row['status']} · Captain ID ${(row['captain_user_id'] ?? '').toString().substring(0, 8)}…',
                badge: row['status'] == 'waitlisted' ? 'WAITLIST' : 'PENDING',
                trailing: _canEvent(data, 'event.registrations.manage')
                    ? Wrap(spacing: 6, children: [
                        IconButton(tooltip: 'Reject', onPressed: _busy ? null : () => _reviewRegistration(row['id'] as String, 'rejected'), icon: const Icon(Icons.close, color: Color(0xFFFF8193))),
                        IconButton(tooltip: 'Approve', onPressed: _busy ? null : () => _reviewRegistration(row['id'] as String, 'approved'), icon: const Icon(Icons.check_circle, color: KomnivoTheme.cyan)),
                      ])
                    : null,
              );
            }),
            const SizedBox(height: 22),
            if (_canEvent(data, 'event.registrations.manage')) ...[
              SectionTitle(
                'Test-registration review',
                subtitle: 'Isolated test submissions only. These records never consume real slots or enter match scoring.',
                trailing: Text(
                  '${data.testRegistrations.where((row) => row['status'] == 'submitted').length} pending',
                  style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 10),
              if (data.testRegistrations.isEmpty)
                const EmptyState(
                  title: 'No test submissions',
                  message: 'Player test-registration entries will appear here separately from real registrations.',
                  icon: Icons.science_outlined,
                )
              else
                ...data.testRegistrations.map((row) {
                  final team = row['teams'] is Map
                      ? Map<String, dynamic>.from(row['teams'] as Map)
                      : <String, dynamic>{};
                  final players = row['event_test_registration_players'] as List? ?? [];
                  final status = row['status']?.toString() ?? 'submitted';
                  final submitter = (row['submitted_by'] ?? '').toString();
                  final canReview = status == 'submitted' &&
                      _canEvent(data, 'event.registrations.manage');
                  return _OperationCard(
                    title: team['name']?.toString() ?? 'Solo test submission',
                    subtitle: '${status.replaceAll('_', ' ').toUpperCase()} · ${players.length} roster member(s) · Submitted by ${submitter.length >= 8 ? submitter.substring(0, 8) : submitter}',
                    badge: 'TEST ONLY',
                    trailing: canReview
                        ? Wrap(spacing: 0, children: [
                            IconButton(
                              tooltip: 'Mark test passed',
                              onPressed: _busy ? null : () => _reviewTestRegistration(row['id'] as String, 'passed'),
                              icon: const Icon(Icons.check_circle_outline, color: KomnivoTheme.cyan),
                            ),
                            IconButton(
                              tooltip: 'Mark test failed',
                              onPressed: _busy ? null : () => _reviewTestRegistration(row['id'] as String, 'failed'),
                              icon: const Icon(Icons.cancel_outlined, color: Color(0xFFFF8193)),
                            ),
                            IconButton(
                              tooltip: 'Cancel test submission',
                              onPressed: _busy ? null : () => _reviewTestRegistration(row['id'] as String, 'cancelled'),
                              icon: const Icon(Icons.block_outlined, color: KomnivoTheme.muted),
                            ),
                          ])
                        : null,
                    footer: (row['review_note']?.toString().isNotEmpty == true)
                        ? row['review_note'].toString()
                        : 'Isolated test record · excluded from real registration capacity, participant roster and standings',
                  );
                }),
            ],
            const SizedBox(height: 22),
            if (_canEvent(data, 'event.roster.lock') || _canEvent(data, 'event.manage'))
              SectionTitle('Roster control', subtitle: 'Snapshot accepted team members before group allocation'),
            const SizedBox(height: 10),
            if (_canEvent(data, 'event.roster.lock') || _canEvent(data, 'event.manage'))
              Row(children: [
                if (_canEvent(data, 'event.roster.lock'))
                  Expanded(child: OutlinedButton.icon(
                    onPressed: _busy || approved.isEmpty ? null : _lockRosters,
                    icon: const Icon(Icons.lock_outline),
                    label: Text('Lock rosters (${approved.length - locked.length} remaining)'),
                  )),
                if (_canEvent(data, 'event.roster.lock') && _canEvent(data, 'event.manage')) const SizedBox(width: 8),
                if (_canEvent(data, 'event.manage'))
                  Expanded(child: FilledButton.icon(
                    onPressed: _busy || locked.length < 2 || data.rounds.isNotEmpty ? null : _generateRoadmap,
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('Generate Stage 1'),
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
              const Text('Approve registrations and lock rosters. Generate groups and matches from the saved tournament roadmap in one transaction.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            if (data.rounds.isNotEmpty) ...[
              const SizedBox(height: 18),
              SectionTitle('Roadmap stages', subtitle: 'Groups, generated matches, private IDP rooms and explicit schedule publication'),
              const SizedBox(height: 10),
              ...data.rounds.map((stage) {
                final stageGroups = List<Map<String, dynamic>>.from(stage['event_groups'] as List? ?? []);
                final stageMatches = data.matches.where((match) => match['stage_id'] == stage['id']).length;
                final roundNumber = int.tryParse(stage['round_number']?.toString() ?? '') ?? 0;
                final stageCount = int.tryParse((widget.event['event_config'] is Map
                    ? (widget.event['event_config'] as Map)['stage_count']
                    : null)?.toString() ?? '') ?? 1;
                final isLastGenerated = roundNumber == (int.tryParse(data.rounds.last['round_number']?.toString() ?? '') ?? 0);
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _OperationCard(
                    title: stage['name']?.toString() ?? 'Stage $roundNumber',
                    subtitle: '${stageGroups.length} groups · $stageMatches generated matches · ${stage['schedule_published_at'] == null ? 'schedule not published' : 'schedule v${stage['schedule_version'] ?? 1} published'}',
                    badge: (stage['status'] ?? 'draft').toString().toUpperCase(),
                    trailing: _canEvent(data, 'event.manage') && stageMatches > 0
                        ? TextButton.icon(
                            onPressed: _busy ? null : () => _publishStageSchedule(stage['id'].toString()),
                            icon: const Icon(Icons.campaign_outlined),
                            label: Text(stage['schedule_published_at'] == null ? 'Publish' : 'Republish'),
                          )
                        : null,
                  ),
                  ...stageGroups.map((group) {
                    final idpReady = data.groupIdpChannels.any((channel) => channel['group_id'] == group['id']);
                    final assigned = group['event_group_teams'] as List? ?? [];
                    return _OperationCard(
                      title: group['label']?.toString() ?? 'Group',
                      subtitle: '${assigned.length} teams · ${idpReady ? 'private IDP channel ready' : 'IDP channel pending read-back'}',
                      badge: 'GROUP',
                    );
                  }),
                  if (isLastGenerated && roundNumber < stageCount && _canEvent(data, 'event.matches.manage'))
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _advanceRoadmapStage(stage),
                        icon: const Icon(Icons.skip_next),
                        label: const Text('Generate next stage from approved results'),
                      ),
                    ),
                ]);
              }),
            ],
            const SizedBox(height: 22),
            SectionTitle(
              'Match operations',
              subtitle: 'Select scheduled matches to group them under one generated Lobby ID',
              trailing: Wrap(spacing: 8, runSpacing: 6, children: [
                if (_canEvent(data, 'event.manage')) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _publishCompleteRoadmap,
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('Publish full roadmap'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _assignDirectEntryTeams,
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('Add direct-entry teams'),
                  ),
                ],
                if (_canEvent(data, 'event.matches.manage')) ...[
                  OutlinedButton.icon(
                    onPressed: _busy || _selectedMatchIds.isEmpty ? null : () => _createLobby(data.matches),
                    icon: const Icon(Icons.view_week_outlined),
                    label: Text('Create Lobby (${_selectedMatchIds.length})'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy || eligible.length < 2 ? null : () => _createMatch(eligible, groups),
                    icon: const Icon(Icons.add),
                    label: const Text('Manual match fallback'),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 10),
            if (data.matches.isEmpty) const EmptyState(title: 'No matches created', message: 'Lock at least two team rosters, then create a match.')
            else ...data.matches.map((row) {
              final participants = row['match_participants'] as List? ?? [];
              final credentials = row['room_credentials'] as List? ?? [];
              final hasCredentials = credentials.isNotEmpty;
              final matchId = row['id']?.toString();
              final menuItems = <PopupMenuEntry<String>>[];
              if (_canEvent(data, 'event.matches.manage')) {
                menuItems.addAll([
                  const PopupMenuItem(value: 'check_in', child: Text('Open check-in')),
                  const PopupMenuItem(value: 'room_setup', child: Text('Room setup')),
                  const PopupMenuItem(value: 'lobby_review', child: Text('Lobby review')),
                  const PopupMenuItem(value: 'live', child: Text('Mark live')),
                  const PopupMenuItem(value: 'awaiting_result', child: Text('Await result')),
                ]);
              }
              if (_canMatch(data, matchId, 'match.credentials.release')) {
                menuItems.add(const PopupMenuItem(value: 'room', child: Text('Add room credentials')));
              }
              return _OperationCard(
                title: 'Match #${row['match_number']} · ${row['group_label'] ?? 'Unassigned group'}',
                subtitle: '${participants.length} teams · ${row['status']} · ${row['starts_at'] ?? 'Time pending'}',
                badge: (row['status'] ?? 'scheduled').toString().toUpperCase(),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_canEvent(data, 'event.matches.manage') &&
                      row['status'] == 'scheduled' &&
                      !data.lobbies.any((lobby) {
                        final lobbyMatches = lobby['event_lobby_matches'] as List? ?? [];
                        return lobbyMatches.any((item) => item is Map && item['match_id'] == matchId);
                      }))
                    Checkbox(
                      value: _selectedMatchIds.contains(matchId),
                      onChanged: _busy || matchId == null ? null : (selected) {
                        setState(() {
                          if (selected == true) _selectedMatchIds.add(matchId);
                          else _selectedMatchIds.remove(matchId);
                        });
                      },
                    ),
                  if (menuItems.isNotEmpty) PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'room') _addRoomCredentials(row['id'] as String);
                      else _updateMatchStatus(row['id'] as String, value);
                    },
                    itemBuilder: (_) => menuItems,
                  ),
                ]),
                footer: hasCredentials
                    ? 'Room details saved · release at ${credentials.first['release_at']}'
                    : (data.lobbies.any((lobby) {
                        final lobbyMatches = lobby['event_lobby_matches'] as List? ?? [];
                        return lobbyMatches.any((item) => item is Map && item['match_id'] == matchId);
                      }) ? 'Assigned to a LiveOps lobby' : 'Room details not added yet'),
              );
            }),
            const SizedBox(height: 22),
            SectionTitle('LiveOps lobbies', subtitle: 'One generated Lobby ID can run one or more ordered Match IDs'),
            const SizedBox(height: 10),
            if (data.lobbies.isEmpty)
              const Text('No lobbies yet. Select one or more scheduled matches and create a lobby.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11))
            else
              ...data.lobbies.map((lobby) {
                final lobbyMatches = (lobby['event_lobby_matches'] as List? ?? [])
                    .whereType<Map>()
                    .toList()
                  ..sort((a, b) => (a['sequence_no'] as int? ?? 0).compareTo(b['sequence_no'] as int? ?? 0));
                final matchLabels = lobbyMatches.map((item) {
                  final match = item['matches'] is Map
                      ? Map<String, dynamic>.from(item['matches'] as Map)
                      : <String, dynamic>{};
                  return 'M${match['match_number'] ?? '—'}';
                }).join(' → ');
                return _OperationCard(
                  title: '${lobby['lobby_code']} · ${lobby['status']}',
                  subtitle: matchLabels.isEmpty ? 'No linked matches' : matchLabels,
                  badge: 'LOBBY ID',
                  trailing: _canEvent(data, 'event.matches.operate')
                      ? IconButton(
                          tooltip: 'Start LiveOps with this Lobby ID',
                          onPressed: _busy || lobby['status'] == 'completed' || lobby['status'] == 'cancelled'
                              ? null
                              : () => _startLiveOps(Map<String, dynamic>.from(lobby)),
                          icon: const Icon(Icons.radar, color: KomnivoTheme.cyan),
                        )
                      : null,
                  footer: 'Lobby UUID: ${lobby['id']} · Match IDs remain separate for scoring',
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
                trailing: _canMatch(
                  data,
                  result['match_id']?.toString(),
                  'match.disputes.review',
                ) ? IconButton(
                  tooltip: 'Mark dispute reviewed',
                  onPressed: _busy ? null : () => _resolveOpponentDispute(row['id'] as String),
                  icon: const Icon(Icons.fact_check_outlined, color: KomnivoTheme.cyan),
                ) : null,
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
              final matchDetails = row['matches'] is Map
                  ? Map<String, dynamic>.from(row['matches'] as Map)
                  : <String, dynamic>{};
              final matchId = matchDetails['id']?.toString();
              return _OperationCard(
                title: team['name']?.toString() ?? 'Team result',
                subtitle: 'Placement ${row['placement'] ?? '—'} · ${row['kills']} kills · ${row['status']}${disputed ? ' · dispute must be reviewed' : ''}',
                badge: disputed ? 'DISPUTED' : 'REVIEW',
                trailing: _canMatch(data, matchId, 'match.results.review') ? IconButton(
                  tooltip: 'Approve official result',
                  onPressed: _busy || disputed ? null : () => _approveResult(row['id'] as String),
                  icon: const Icon(Icons.verified_outlined, color: KomnivoTheme.cyan),
                ) : null,
              );
            }),
            const SizedBox(height: 22),
            SectionTitle('OCR candidate review', subtitle: 'Accept or reject manually mapped Team ID rows. This does not publish official scores.'),
            const SizedBox(height: 10),
            if (data.ocrCandidates.where((row) => row['review_status'] == 'provisional' || row['review_status'] == 'needs_review').isEmpty)
              const EmptyState(title: 'No provisional OCR candidates', message: 'Once the LiveOps operator maps screenshot text to Match teams, candidates will appear here for review.')
            else ...data.ocrCandidates
                .where((row) => row['review_status'] == 'provisional' || row['review_status'] == 'needs_review')
                .map((row) {
              final team = row['teams'] is Map ? Map<String, dynamic>.from(row['teams'] as Map) : <String, dynamic>{};
              final match = row['matches'] is Map ? Map<String, dynamic>.from(row['matches'] as Map) : <String, dynamic>{};
              final matchId = match['id']?.toString();
              final evidence = (row['result_candidate_evidence'] as List? ?? [])
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList();
              final sourceValues = evidence
                  .map((item) => 'P${item['reported_placement'] ?? '—'}/K${item['reported_kills'] ?? '—'}')
                  .toSet()
                  .toList()
                ..sort();
              final evidenceConflict = evidence.any((item) =>
                  item['reported_placement'] != row['candidate_placement'] ||
                  item['reported_kills'] != row['candidate_kills']);
              final canReview = _canMatch(data, matchId, 'match.results.review');
              return _OperationCard(
                title: team['name']?.toString() ?? 'OCR team candidate',
                subtitle: 'Match ${match['match_number'] ?? '—'} · Provisional P${row['candidate_placement'] ?? '—'} / K${row['candidate_kills'] ?? '—'} · ${evidence.length} screenshot source(s)${evidenceConflict ? ' · conflicting readings' : ''}',
                badge: evidenceConflict ? 'CONFLICT' : (row['review_status'] ?? 'NEEDS REVIEW').toString().replaceAll('_', ' ').toUpperCase(),
                trailing: canReview
                    ? Wrap(spacing: 0, children: [
                        IconButton(
                          tooltip: 'Reject OCR candidate',
                          onPressed: _busy ? null : () => _rejectOcrCandidate(row),
                          icon: const Icon(Icons.close, color: Color(0xFFFF8193)),
                        ),
                        IconButton(
                          tooltip: 'Confirm final values and accept',
                          onPressed: _busy ? null : () => _acceptOcrCandidate(row),
                          icon: const Icon(Icons.verified_outlined, color: KomnivoTheme.cyan),
                        ),
                      ])
                    : const Text('Reviewer only', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                footer: 'Screenshot readings: ${sourceValues.join(', ')}. Acceptance stores separate reviewer-confirmed values; official result publication is a later action.',
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
    required this.lobbies,
    required this.ocrCandidates,
    required this.testRegistrations,
    required this.groupIdpChannels,
    required this.eventPermissions,
    required this.matchPermissions,
  });
  final List<Map<String, dynamic>> registrations;
  final List<Map<String, dynamic>> matches;
  final List<Map<String, dynamic>> results;
  final List<Map<String, dynamic>> rounds;
  final List<Map<String, dynamic>> disputedConfirmations;
  final List<Map<String, dynamic>> lobbies;
  final List<Map<String, dynamic>> ocrCandidates;
  final List<Map<String, dynamic>> testRegistrations;
  final List<Map<String, dynamic>> groupIdpChannels;
  final Map<String, bool> eventPermissions;
  final Map<String, Map<String, bool>> matchPermissions;
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
