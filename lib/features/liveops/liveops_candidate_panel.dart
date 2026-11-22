import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class LiveOpsCandidatePanel extends StatefulWidget {
  const LiveOpsCandidatePanel({
    super.key,
    required this.sessionId,
    required this.matchId,
    required this.capturing,
    required this.onNextMatch,
    required this.onEvidenceSkipped,
  });

  final String sessionId;
  final String matchId;
  final bool capturing;
  final VoidCallback onNextMatch;
  final ValueChanged<String> onEvidenceSkipped;

  @override
  State<LiveOpsCandidatePanel> createState() => _LiveOpsCandidatePanelState();
}

class _LiveOpsCandidatePanelState extends State<LiveOpsCandidatePanel> {
  final _placementController = TextEditingController();
  final _killsController = TextEditingController();
  bool _loading = false;
  bool _saving = false;
  bool _submitting = false;
  bool _evidenceSkipped = false;
  String _evidenceSkipReason = '';
  List<Map<String, dynamic>> _participants = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _observations = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _candidates = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _officialResults = <Map<String, dynamic>>[];
  String? _selectedTeamId;
  final Set<String> _selectedObservationIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  @override
  void didUpdateWidget(covariant LiveOpsCandidatePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId || oldWidget.matchId != widget.matchId) {
      _selectedTeamId = null;
      _selectedObservationIds.clear();
      _placementController.clear();
      _killsController.clear();
      _loadContext();
    }
  }

  Future<void> _loadContext() async {
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final result = await Future.wait([
        client.from('match_participants')
            .select('team_id,slot_number,teams(name,tag)')
            .eq('match_id', widget.matchId)
            .order('slot_number'),
        client.from('screen_observations')
            .select('id,evidence_batch_id,extracted_text,observed_at,liveops_captures(sequence_no,content_sha256)')
            .eq('session_id', widget.sessionId)
            .order('observed_at'),
        client.from('result_candidates')
            .select('id,team_id,candidate_placement,candidate_kills,reviewed_placement,reviewed_kills,review_status,review_note,result_candidate_evidence(id,source_observation_id,reported_placement,reported_kills)')
            .eq('match_id', widget.matchId)
            .order('candidate_placement'),
        client.from('match_results')
            .select('id,team_id,placement,kills,status,result_json')
            .eq('match_id', widget.matchId)
            .order('placement'),
        client.from('liveops_sessions')
            .select('evidence_skipped_at,evidence_skip_reason')
            .eq('id', widget.sessionId).maybeSingle(),
      ]);
      if (!mounted) return;
      final observations = List<Map<String, dynamic>>.from(result[1] as List)
          .where((row) => row['evidence_batch_id'] != null)
          .toList();
      final candidateRows = List<Map<String, dynamic>>.from(result[2] as List);
      setState(() {
        _participants = List<Map<String, dynamic>>.from(result[0] as List);
        _observations = observations;
        _candidates = candidateRows;
        _officialResults = List<Map<String, dynamic>>.from(result[3] as List);
        final sessionState = result[4] as Map<String, dynamic>?;
        _evidenceSkipped = sessionState?['evidence_skipped_at'] != null;
        _evidenceSkipReason = sessionState?['evidence_skip_reason']?.toString() ?? '';
        final participantIds = _participants.map((row) => row['team_id'].toString()).toSet();
        if (_selectedTeamId != null && !participantIds.contains(_selectedTeamId)) {
          _selectedTeamId = null;
        }
      });
    } catch (error) {
      if (mounted) showMessage(context, 'Could not load Match roster or OCR observations: ' + error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _teamName(Map<String, dynamic> participant) {
    final team = participant['teams'] is Map
        ? Map<String, dynamic>.from(participant['teams'] as Map)
        : <String, dynamic>{};
    final tag = team['tag']?.toString() ?? '';
    final name = team['name']?.toString() ?? 'Team';
    return tag.isEmpty ? name : '[' + tag + '] ' + name;
  }

  Future<void> _saveCandidate() async {
    if (_evidenceSkipped) {
      showMessage(context, 'This Match evidence step was skipped; candidate edits are locked.');
      return;
    }
    if (widget.capturing) {
      showMessage(context, 'Pause LiveOps before mapping OCR rows to teams.');
      return;
    }
    final teamId = _selectedTeamId;
    final placement = int.tryParse(_placementController.text.trim());
    final kills = int.tryParse(_killsController.text.trim());
    if (teamId == null) {
      showMessage(context, 'Select the canonical Team from this Match roster.');
      return;
    }
    if (placement == null || placement < 1 || kills == null || kills < 0 || kills > 999) {
      showMessage(context, 'Enter a valid placement and kill count.');
      return;
    }
    if (_selectedObservationIds.isEmpty) {
      showMessage(context, 'Select at least one screenshot observation that supports this team row.');
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await KomnivoRepository.instance.saveLiveOpsTeamCandidate(
        sessionId: widget.sessionId,
        teamId: teamId,
        placement: placement,
        kills: kills,
        sourceObservationIds: _selectedObservationIds.toList(),
      );
      if (!mounted) return;
      setState(() => _selectedObservationIds.clear());
      await _loadContext();
      if (!mounted) return;
      if (result['conflict_with_accepted_values'] == true) {
        showMessage(context, 'New screenshot values conflict with an accepted candidate. It has been returned to Needs review; accepted values were not overwritten.');
      } else {
        showMessage(context, 'Team candidate saved. Matching screenshots are linked to one Match + Team record; reviewer approval is still required.');
      }
    } catch (error) {
      if (mounted) showMessage(context, 'Could not save team candidate: ' + error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _officialSubmittedForCurrentSession {
    if (_participants.isEmpty || _officialResults.length != _participants.length) {
      return false;
    }
    for (final row in _officialResults) {
      final resultJson = row['result_json'] is Map
          ? Map<String, dynamic>.from(row['result_json'] as Map)
          : <String, dynamic>{};
      if (resultJson['source'] != 'liveops_reviewed_candidates' ||
          resultJson['liveops_session_id']?.toString() != widget.sessionId) {
        return false;
      }
    }
    return true;
  }

  bool get _canSubmitReviewedResults {
    if (_evidenceSkipped || widget.capturing || _loading || _saving || _submitting ||
        _participants.isEmpty || _officialResults.isNotEmpty) {
      return false;
    }
    for (final participant in _participants) {
      final teamId = participant['team_id']?.toString();
      if (teamId == null) return false;
      Map<String, dynamic>? candidate;
      for (final row in _candidates) {
        if (row['team_id']?.toString() == teamId) {
          candidate = row;
          break;
        }
      }
      if (candidate == null ||
          candidate['review_status'] != 'accepted' ||
          candidate['reviewed_placement'] == null ||
          candidate['reviewed_kills'] == null ||
          (candidate['result_candidate_evidence'] as List? ?? []).isEmpty) {
        return false;
      }
    }
    return true;
  }

  Future<void> _skipEvidenceStep() async {
    if (widget.capturing || _submitting || _evidenceSkipped || _officialResults.isNotEmpty) {
      return;
    }
    final controller = TextEditingController();
    String? reason;
    try {
      reason = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Skip this Match evidence step?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('This records an audited skip reason and allows this Lobby to move to its next scheduled Match. No result rows, points or standings will be created for this Match.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 5,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Reason for skipping (required)',
                  hintText: 'Explain why the screenshot evidence cannot be submitted.',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.length < 10) {
                  showMessage(context, 'Enter at least 10 characters explaining the skip.');
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Record skip'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
    if (reason == null || !mounted) return;

    setState(() => _submitting = true);
    try {
      await Supabase.instance.client.rpc('skip_liveops_match_evidence', params: {
        'p_session_id': widget.sessionId,
        'p_reason': reason,
      });
      await _loadContext();
      if (!mounted) return;
      widget.onEvidenceSkipped(reason);
      showMessage(context, 'Evidence skip reason recorded for this Match. No score was created; Next Match is now available.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not record evidence skip: ' +
          error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitReviewedResults() async {
    if (!_canSubmitReviewedResults) return;
    setState(() => _submitting = true);
    try {
      final result = await KomnivoRepository.instance
          .submitReviewedLiveOpsMatchResults(
        sessionId: widget.sessionId,
        matchId: widget.matchId,
      );
      await _loadContext();
      if (!mounted) return;
      final count = result['submitted_count']?.toString() ??
          (result['result_ids'] is List
              ? (result['result_ids'] as List).length.toString()
              : '0');
      showMessage(
        context,
        '$count official result rows submitted for review. Points and standings remain unchanged until an authorised reviewer approves them.',
      );
    } catch (error) {
      if (mounted) {
        showMessage(
          context,
          'Could not submit reviewed results: ' +
              error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _placementController.dispose();
    _killsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.fact_check_outlined, color: KomnivoTheme.cyan), SizedBox(width: 9), Expanded(child: Text('OCR team-row reconciliation', style: TextStyle(fontWeight: FontWeight.w900)))]),
      const SizedBox(height: 7),
      const Text('Read the selected screenshots, choose the matching canonical Team ID, then transcribe placement and kills. If the same team appears in overlapping screenshots, select all supporting observations before saving.', style: TextStyle(color: KomnivoTheme.muted,fontSize:11,height:1.45)),
      const SizedBox(height: 12),
      if (_loading)
        const Center(child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2)))
      else if (_participants.isEmpty)
        const Text('No teams are assigned to this Match yet. Generate the match roster first.', style: TextStyle(color: KomnivoTheme.muted,fontSize:11))
      else if (_observations.isEmpty)
        const Text('Upload at least one standing screenshot batch before transcribing team rows.', style: TextStyle(color: KomnivoTheme.muted,fontSize:11))
      else ...[
        const Text('1. OCR screenshot observations', style: TextStyle(fontWeight: FontWeight.w800,fontSize:12)),
        const SizedBox(height: 5),
        ..._observations.map((observation) {
          final id = observation['id'].toString();
          final capture = observation['liveops_captures'] is Map
              ? Map<String, dynamic>.from(observation['liveops_captures'] as Map)
              : <String, dynamic>{};
          final sequence = capture['sequence_no']?.toString() ?? '—';
          final text = observation['extracted_text']?.toString() ?? '';
          return CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _selectedObservationIds.contains(id),
            onChanged: widget.capturing || _saving ? null : (checked) {
              setState(() {
                if (checked == true) _selectedObservationIds.add(id);
                else _selectedObservationIds.remove(id);
              });
            },
            title: Text('Screenshot ' + sequence, style: const TextStyle(fontWeight: FontWeight.w800,fontSize:11)),
            subtitle: Text(text.isEmpty ? 'No text detected in this image.' : text, maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(color:KomnivoTheme.muted,fontSize:10,height:1.4)),
          );
        }),
        const Divider(height: 18),
        const Text('2. Map OCR row to canonical Team ID', style: TextStyle(fontWeight: FontWeight.w800,fontSize:12)),
        const SizedBox(height: 7),
        DropdownButtonFormField<String>(
          value: _selectedTeamId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Match participant team', isDense: true),
          items: _participants.map((participant) => DropdownMenuItem<String>(
            value: participant['team_id'].toString(),
            child: Text(_teamName(participant), overflow: TextOverflow.ellipsis),
          )).toList(),
          onChanged: widget.capturing || _saving ? null : (value) => setState(() => _selectedTeamId = value),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _placementController, enabled: !widget.capturing && !_saving, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Placement', isDense: true))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _killsController, enabled: !widget.capturing && !_saving, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Kills', isDense: true))),
        ]),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: widget.capturing || _saving ? null : _saveCandidate,
          icon: _saving ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.playlist_add_check),
          label: Text(_saving ? 'Saving candidate…' : 'Save provisional team row'),
        )),
      ],
      if (_candidates.isNotEmpty) ...[
        const Divider(height: 22),
        const Text('3. Canonical rows for this Match', style: TextStyle(fontWeight: FontWeight.w800,fontSize:12)),
        const SizedBox(height: 6),
        ..._candidates.map((candidate) {
          final participant = _participants.cast<Map<String, dynamic>?>().firstWhere(
            (row) => row?['team_id']?.toString() == candidate['team_id']?.toString(),
            orElse: () => null,
          );
          final evidence = candidate['result_candidate_evidence'] as List? ?? [];
          final status = candidate['review_status']?.toString() ?? 'provisional';
          return Container(
            margin: const EdgeInsets.only(bottom: 7),padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF191E2C),borderRadius:BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(participant == null ? 'Team' : _teamName(participant),style:const TextStyle(fontWeight:FontWeight.w800,fontSize:11)),
                const SizedBox(height:3),
                Text(
                  status == 'accepted'
                      ? 'Provisional P' + (candidate['candidate_placement'] ?? '—').toString() +
                        '/K' + (candidate['candidate_kills'] ?? '—').toString() +
                        ' · Reviewed P' + (candidate['reviewed_placement'] ?? '—').toString() +
                        '/K' + (candidate['reviewed_kills'] ?? '—').toString() +
                        ' · ' + evidence.length.toString() + ' source screenshots'
                      : 'Placement ' + (candidate['candidate_placement'] ?? '—').toString() +
                        ' · ' + (candidate['candidate_kills'] ?? '—').toString() +
                        ' kills · ' + evidence.length.toString() + ' source screenshots',
                  style:const TextStyle(color:KomnivoTheme.muted,fontSize:10),
                ),
              ])),
              Text(status.replaceAll('_',' ').toUpperCase(),style:TextStyle(color:status=='accepted'?KomnivoTheme.cyan:KomnivoTheme.muted,fontSize:9,fontWeight:FontWeight.w900)),
            ]),
          );
        }),
      ],
      if (_evidenceSkipped) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF192231),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: KomnivoTheme.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Evidence step skipped · reason recorded', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
            const SizedBox(height: 6),
            Text(_evidenceSkipReason, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4)),
            const SizedBox(height: 6),
            const Text('This Match remains without official result rows. Skipping does not create a placement, score or standing.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, height: 1.4)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.capturing || _submitting ? null : widget.onNextMatch,
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('Load next Match in this Lobby'),
              ),
            ),
          ]),
        ),
      ] else if (_officialResults.isNotEmpty) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF192231),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: KomnivoTheme.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Official result rows submitted', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
            const SizedBox(height: 5),
            Text(
              '${_officialResults.length} team result(s) · ${_officialResults.map((row) => row['status']?.toString() ?? 'submitted').toSet().join(', ')}',
              style: const TextStyle(color: KomnivoTheme.muted,fontSize:10),
            ),
            const SizedBox(height: 5),
            const Text('Final points and standings are not calculated yet. An authorised organiser/result reviewer must approve the submitted results in Event Operations.', style: TextStyle(color:KomnivoTheme.cyan,fontSize:10,height:1.4)),
            if (_officialSubmittedForCurrentSession) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: widget.capturing || _submitting ? null : widget.onNextMatch,
                  icon: const Icon(Icons.skip_next_rounded),
                  label: const Text('Load next Match in this Lobby'),
                ),
              ),
              const SizedBox(height: 4),
              const Text('The previous session will close. The next Match is prepared, but screen capture starts only after you press Start.', style: TextStyle(color:KomnivoTheme.muted,fontSize:10,height:1.4)),
            ],
          ]),
        ),
      ] else if (_canSubmitReviewedResults) ...[
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _submitting ? null : _submitReviewedResults,
            icon: _submitting
                ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2))
                : const Icon(Icons.send_and_archive_outlined),
            label: Text(_submitting
                ? 'Submitting official result rows…'
                : 'Submit all reviewed teams for official approval'),
          ),
        ),
        const SizedBox(height: 5),
        const Text('This creates the official Match result submissions with each team’s own screenshots. It does not approve results or calculate standings.', style: TextStyle(color:KomnivoTheme.muted,fontSize:10,height:1.4)),
      ] else if (_candidates.isNotEmpty && !widget.capturing) ...[
        const SizedBox(height: 10),
        const Text('Official submission unlocks after every team in this Match has an accepted reviewer-confirmed row and at least one linked screenshot.', style: TextStyle(color:KomnivoTheme.muted,fontSize:10,height:1.4)),
      ],
      if (!_evidenceSkipped && _officialResults.isEmpty &&
          !widget.capturing && !_loading && !_submitting) ...[
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _skipEvidenceStep,
            icon: const Icon(Icons.skip_next_rounded),
            label: const Text('Skip evidence step with reason'),
          ),
        ),
        const SizedBox(height: 4),
        const Text('Use only when this Match cannot provide screenshot evidence. The backend stores the reason and never creates fake results.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4)),
      ],
      const SizedBox(height: 8),
      const Text('This creates one candidate per Team ID in this Match ID. Overlapping screenshots add provenance links, not extra points. The same team in another Match ID remains a separate candidate. Provisional OCR rows do not affect official results; a reviewer must accept every team before the operator can submit this Match for official result approval.',style:TextStyle(color:KomnivoTheme.cyan,fontSize:10,height:1.4)),
    ]),
  );
}
