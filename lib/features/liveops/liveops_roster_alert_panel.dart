import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import 'liveops_roster_matcher.dart';

/// Read-only Match roster comparison. OCR alerts are temporary local suggestions;
/// this widget never edits the official roster or controls the game.
class LiveOpsRosterAlertPanel extends StatefulWidget {
  const LiveOpsRosterAlertPanel({
    super.key,
    required this.sessionId,
    required this.matchId,
    required this.ocrText,
    required this.lobbyConfirmed,
    this.observedAt,
    this.observationSource = 'On-device OCR',
    this.preview = false,
  });

  final String sessionId;
  final String matchId;
  final String ocrText;
  final bool lobbyConfirmed;
  final DateTime? observedAt;
  final String observationSource;
  final bool preview;

  @override
  State<LiveOpsRosterAlertPanel> createState() => _LiveOpsRosterAlertPanelState();
}

class _LiveOpsRosterAlertPanelState extends State<LiveOpsRosterAlertPanel> {
  static const Duration _alertLifetime = Duration(seconds: 15);
  static const Duration _repeatSuppression = Duration(seconds: 45);

  final Map<String, DateTime> _recentAlerts = <String, DateTime>{};
  final List<_TimedRosterAlert> _alerts = <_TimedRosterAlert>[];
  final Set<String> _processingAlertKeys = <String>{};
  List<_ExpectedTeamSlot> _teams = <_ExpectedTeamSlot>[];
  Timer? _expiryTimer;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _expireAlerts());
    unawaited(_loadSnapshot());
  }

  @override
  void didUpdateWidget(covariant LiveOpsRosterAlertPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.matchId != widget.matchId) {
      _recentAlerts.clear();
      _alerts.clear();
      _teams = <_ExpectedTeamSlot>[];
      unawaited(_loadSnapshot());
      return;
    }
    if (oldWidget.lobbyConfirmed && !widget.lobbyConfirmed && _alerts.isNotEmpty) {
      setState(_alerts.clear);
      return;
    }
    if (oldWidget.ocrText != widget.ocrText ||
        oldWidget.lobbyConfirmed != widget.lobbyConfirmed) {
      _evaluateLobby();
    }
  }

  Future<void> _loadSnapshot() async {
    if (widget.preview) {
      if (mounted) setState(() {
        _loading = false;
        _loadError = null;
      });
      return;
    }
    if (mounted) setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final response = await Supabase.instance.client.rpc(
        'get_liveops_match_roster_snapshot',
        params: <String, dynamic>{'p_session_id': widget.sessionId},
      );
      if (response is! Map) {
        throw Exception('The server returned an invalid Match roster snapshot.');
      }
      final payload = Map<String, dynamic>.from(response);
      if (payload['match_id']?.toString() != widget.matchId) {
        throw Exception('The roster snapshot belongs to a different Match ID.');
      }
      final rawTeams = payload['roster_snapshot'];
      final teams = rawTeams is List
          ? rawTeams.whereType<Map>().map((row) =>
              _ExpectedTeamSlot.fromMap(Map<String, dynamic>.from(row))).toList()
          : <_ExpectedTeamSlot>[];
      if (!mounted) return;
      setState(() {
        _teams = teams;
        _loading = false;
      });
      _evaluateLobby();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _evaluateLobby() {
    if (!mounted || _loading || _loadError != null ||
        !widget.lobbyConfirmed || _teams.isEmpty ||
        widget.ocrText.trim().isEmpty) {
      return;
    }

    final slotLines = _readSlotLines(widget.ocrText);
    final slotUids = _readSlotUids(widget.ocrText);
    if (slotLines.isEmpty && slotUids.isEmpty) return;

    final knownPlayers = _teams
        .expand((team) => team.players)
        .where((player) => player.isVerified &&
            (player.uid.isNotEmpty ||
                (player.identitySnapshotAvailable && player.nickname.trim().isNotEmpty)))
        .toList(growable: false);
    final allKnownNames = knownPlayers
        .map((player) => _normalise(player.nickname))
        .where((name) => name.isNotEmpty)
        .toSet();
    final knownUids = knownPlayers
        .map((player) => player.uid)
        .where((uid) => uid.isNotEmpty)
        .toSet();
    final namesPairedWithUids =
        LiveOpsRosterOcrParser.readNamesPairedWithUids(widget.ocrText);
    final generated = <_TimedRosterAlert>[];
    final ambiguousOcrNames = <String>{};

    for (final team in _teams) {
      final slot = team.slotNumber;
      if (slot == null) continue;
      final visibleLines = slotLines[slot] ?? <String>[];
      final visibleUids = slotUids[slot] ?? <String>[];
      if (visibleLines.isEmpty && visibleUids.isEmpty) continue;

      final expected = team.players
          .where((player) => player.isVerified &&
              (player.uid.isNotEmpty ||
                  (player.identitySnapshotAvailable && player.nickname.trim().isNotEmpty)))
          .toList(growable: false);
      final notSeen = <String>[];

      for (final player in expected) {
        final playerName = _normalise(player.nickname);
        final foundNameSlots = LiveOpsRosterOcrParser.slotsForExactName(
          slotLines, player.nickname,
        );
        final foundUidSlots = LiveOpsRosterOcrParser.slotsForExactUid(
          slotUids, player.uid,
        );
        final foundSlots = <int>{
          ...foundNameSlots,
          ...foundUidSlots,
        }.toList()..sort();
        final nameOccurrenceCount = slotLines.values
            .expand((lines) => lines)
            .where((line) => _normalise(line) == playerName)
            .length;
        final uidOccurrenceCount = slotUids.values
            .expand((uids) => uids)
            .where((uid) => player.uid.isNotEmpty && uid == player.uid)
            .length;
        final nearHits = <MapEntry<int, String>>[];
        for (final entry in slotLines.entries) {
          for (final line in entry.value) {
            final candidate = _normalise(line);
            if (playerName.isNotEmpty &&
                candidate.isNotEmpty &&
                candidate != playerName &&
                _isLikelySimilarName(playerName, candidate)) {
              nearHits.add(MapEntry<int, String>(entry.key, line));
              ambiguousOcrNames.add(candidate);
            }
          }
        }
        if (!foundSlots.contains(slot) && nearHits.isNotEmpty) {
          final samples = nearHits.take(2).map((hit) =>
              '"' + hit.value + '" under Slot ' + hit.key.toString()).join('; ');
          generated.add(_TimedRosterAlert(
            key: 'ambiguous:' + player.userId + ':' +
                nearHits.map((hit) => hit.key.toString() + ':' + _normalise(hit.value)).join('|'),
            title: 'Possible clipped or similar IGN',
            detail: 'Expected ' + player.nickname + ', but OCR read ' + samples +
                '. This is not an identity match; the name may be clipped, changed or misread. Host should inspect the live lobby.',
            icon: Icons.help_outline_rounded,
          ));
        }
        if (foundSlots.length > 1 ||
            nameOccurrenceCount > 1 ||
            uidOccurrenceCount > 1) {
          final slotLabel = foundSlots.join(', ');
          generated.add(_TimedRosterAlert(
            key: 'duplicate:' + player.userId + ':' + slotLabel + ':' + (nameOccurrenceCount + uidOccurrenceCount).toString(),
            title: 'Possible duplicate player entry',
            detail: player.nickname + ' was read more than once in slot(s) ' + slotLabel +
                ' by exact IGN or UID text. This may be overlapping OCR or a duplicate lobby entry; inspect the game before acting.',
            icon: Icons.copy_all_rounded,
          ));
        }
        if (foundSlots.contains(slot)) continue;
        if (nearHits.isNotEmpty) continue;
        if (foundSlots.isNotEmpty) {
          final otherSlot = foundSlots.first;
          generated.add(_TimedRosterAlert(
            key: 'slot:' + player.userId + ':' + slot.toString() + ':' + otherSlot.toString(),
            title: 'Player appears in a different slot',
            detail: player.nickname + ' is expected in Slot ' + slot.toString() +
                ' (' + team.displayName + ') but OCR found this identity under Slot ' +
                otherSlot.toString() + (foundUidSlots.isNotEmpty
                  ? ' using an exact visible UID.'
                  : ' using an exact IGN/name match only.') +
                ' Check the actual lobby before deciding.',
            icon: Icons.swap_horiz_rounded,
          ));
        } else {
          notSeen.add(player.nickname.isNotEmpty
              ? player.nickname
              : 'UID ' + player.uid);
        }
      }

      if (notSeen.isNotEmpty && expected.isNotEmpty) {
        generated.add(_TimedRosterAlert(
          key: 'not-seen:' + slot.toString() + ':' +
              notSeen.map(_normalise).join('|'),
          title: 'Expected player not detected',
          detail: 'Slot ' + slot.toString() + ' (' + team.displayName + '): ' +
              notSeen.length.toString() +
              ' expected player name(s) were not read in this OCR scan. This is not proof they are absent; check scrolling, clipping and the actual lobby.',
          icon: Icons.person_search_rounded,
        ));
      }
    }

    for (final entry in slotLines.entries) {
      for (final line in entry.value) {
          final candidate = _normalise(line);
        final pairedUid = namesPairedWithUids[entry.key]?[candidate];
        if (candidate.isEmpty ||
            ambiguousOcrNames.contains(candidate) ||
            allKnownNames.contains(candidate) ||
            (pairedUid != null && knownUids.contains(pairedUid))) {
          continue;
        }
        generated.add(_TimedRosterAlert(
          key: 'unknown:' + entry.key.toString() + ':' + candidate,
          title: 'Possible unrecognised lobby name',
          detail: '"' + line + '" was read under Slot ' + entry.key.toString() +
              ', but is not in this Match’s verified identity snapshot. It could be an unverified roster member, OCR noise or an unexpected player; inspect the actual lobby before deciding.',
          icon: Icons.person_search_rounded,
        ));
      }
    }

    final visibleSlots = slotLines.keys.toSet();
    final expectedSlots = _teams
        .map((team) => team.slotNumber)
        .whereType<int>()
        .toSet();
    final unobservedSlots = expectedSlots.difference(visibleSlots).toList()..sort();
    if (unobservedSlots.isNotEmpty) {
      generated.add(_TimedRosterAlert(
        key: 'coverage:' + unobservedSlots.join(','),
        title: 'Lobby slot coverage is incomplete',
        detail: 'This OCR view did not expose Slot(s) ' + unobservedSlots.join(', ') +
            '. They are unassessed, not marked Missing. Scroll or capture the other lobby rows before making a decision.',
        icon: Icons.photo_library_outlined,
      ));
    }
    final emptyVisibleSlots = slotLines.entries
        .where((entry) => entry.value.isEmpty &&
            (slotUids[entry.key] ?? <String>[]).isEmpty)
        .map((entry) => entry.key)
        .toList()
      ..sort();
    if (emptyVisibleSlots.isNotEmpty) {
      generated.add(_TimedRosterAlert(
        key: 'empty-slot:' + emptyVisibleSlots.join(','),
        title: 'Slot header found, player text unreadable',
        detail: 'OCR saw Slot(s) ' + emptyVisibleSlots.join(', ') +
            ' but could not read player names beneath them. This is unreadable coverage, not proof that a player is absent.',
        icon: Icons.document_scanner_outlined,
      ));
    }

    final now = DateTime.now();
    var changed = false;
    for (final alert in generated) {
      final suppressedUntil = _recentAlerts[alert.key];
      if (suppressedUntil != null && suppressedUntil.isAfter(now)) continue;
      _recentAlerts[alert.key] = now.add(_repeatSuppression);
      _alerts.removeWhere((existing) => existing.key == alert.key);
      _alerts.insert(0, alert.withExpiry(now.add(_alertLifetime)));
      changed = true;
    }
    if (changed && mounted) {
      setState(() {
        if (_alerts.length > 4) _alerts.removeRange(4, _alerts.length);
      });
    }
  }

  Map<int, List<String>> _readSlotLines(String rawText) =>
      LiveOpsRosterOcrParser.readSlots(rawText);

  Map<int, List<String>> _readSlotUids(String rawText) =>
      LiveOpsRosterOcrParser.readSlotUids(rawText);

  static String _normalise(String value) =>
      LiveOpsRosterOcrParser.normalise(value);

  static bool _isLikelySimilarName(String expected, String candidate) {
    final shortest = expected.length < candidate.length
        ? expected.length
        : candidate.length;
    final longest = expected.length > candidate.length
        ? expected.length
        : candidate.length;
    if (shortest < 4) return false;
    if (expected.startsWith(candidate) || candidate.startsWith(expected) ||
        expected.endsWith(candidate) || candidate.endsWith(expected)) {
      return true;
    }
    if (longest - shortest > 2) return false;
    final maxDistance = shortest >= 8 ? 2 : 1;
    final previous = List<int>.generate(candidate.length + 1, (i) => i);
    for (var i = 1; i <= expected.length; i++) {
      final current = <int>[i];
      for (var j = 1; j <= candidate.length; j++) {
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] +
            (expected.codeUnitAt(i - 1) == candidate.codeUnitAt(j - 1) ? 0 : 1);
        var best = deletion < insertion ? deletion : insertion;
        if (substitution < best) best = substitution;
        current.add(best);
      }
      for (var j = 0; j < current.length; j++) {
        previous[j] = current[j];
      }
    }
    return previous.last <= maxDistance;
  }

  void _expireAlerts() {
    if (!mounted || _alerts.isEmpty) return;
    final now = DateTime.now();
    setState(() {
      _alerts.removeWhere((alert) => alert.expiresAt?.isAfter(now) != true);
    });
    _recentAlerts.removeWhere((_, until) =>
        until.isBefore(now.subtract(const Duration(minutes: 2))));
  }

  Future<void> _recordHostDecision(
    _TimedRosterAlert alert,
    String decision,
  ) async {
    if (_processingAlertKeys.contains(alert.key)) return;
    setState(() => _processingAlertKeys.add(alert.key));
    try {
      await Supabase.instance.client.rpc(
        'record_liveops_roster_alert_decision',
        params: <String, dynamic>{
          'p_session_id': widget.sessionId,
          'p_alert_type': alert.key.split(':').first,
          'p_decision': decision,
        },
      );
      if (!mounted) return;
      _recentAlerts[alert.key] = DateTime.now().add(_repeatSuppression);
      setState(() => _alerts.removeWhere((item) => item.key == alert.key));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Host decision could not be recorded: ' +
              error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _processingAlertKeys.remove(alert.key));
      }
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rosterPlayers = _teams.expand((team) => team.players).toList(growable: false);
    final verifiedPlayers = rosterPlayers.where((player) => player.isVerified).length;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.groups_2_outlined, color: KomnivoTheme.cyan),
            const SizedBox(width: 9),
            const Expanded(child: Text(
              'Match player & slot check',
              style: TextStyle(fontWeight: FontWeight.w900),
            )),
            if (_loading)
              const SizedBox(width: 15, height: 15,
                child: CircularProgressIndicator(strokeWidth: 2)),
            if (!_loading && _teams.isNotEmpty)
              Text(
                _teams.length.toString() + ' SLOTS · ' +
                    verifiedPlayers.toString() + '/' +
                    rosterPlayers.length.toString() + ' VERIFIED',
                style: const TextStyle(color: KomnivoTheme.muted,
                  fontSize: 9, fontWeight: FontWeight.w900),
              ),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Expected identities come from this Match’s registration snapshot. A later IGN refresh does not rename this locked roster.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4),
          ),
          const SizedBox(height: 5),
          Text(
            'Source: ' + widget.observationSource +
                ' · Observed: ' +
                (widget.observedAt?.toLocal().toString().split('.').first ?? '—') +
                '. Screen stability is based on 3 consecutive Lobby observations; OCR name confidence is not statistically calibrated.',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.35),
          ),
          if (widget.preview) ...[
            const SizedBox(height: 10),
            const Text('Preview only — no live roster is queried.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
          ] else if (_loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 2),
          ] else if (_loadError != null) ...[
            const SizedBox(height: 10),
            Text(_loadError!,
              style: const TextStyle(color: Color(0xFFFFB86B), fontSize: 11)),
            Align(alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _loadSnapshot,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Retry snapshot'),
              )),
          ] else if (_teams.isEmpty) ...[
            const SizedBox(height: 10),
            const Text('No assigned teams were found for this Match. Generate or assign the Match roster first.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
          ] else ...[
            const SizedBox(height: 11),
            ..._teams.map(_buildTeam),
            if (widget.lobbyConfirmed && _alerts.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('OPTIONAL HOST ALERTS · AUTO-HIDE IN 15 SECONDS',
                style: TextStyle(color: Color(0xFFFFC078), fontSize: 9,
                  fontWeight: FontWeight.w900, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              ..._alerts.map(_buildAlert),
            ] else if (widget.lobbyConfirmed) ...[
              const SizedBox(height: 10),
              const Text('No current slot mismatch or unrecognised-name alert. OCR remains provisional.',
                style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10)),
            ] else ...[
              const SizedBox(height: 9),
              const Text('Alerts are evaluated only after the Lobby screen is stable across three OCR observations.',
                style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
            ],
          ],
          const SizedBox(height: 9),
          const Text(
            'Player comparisons use exact OCR IGN/name matching against the locked verified-profile snapshot; they are not proof of UID identity. Host decisions are audit-logged against this Match. The host performs any game change manually; KOMNIVO never kicks players, moves slots or edits the official roster.',
            style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildTeam(_ExpectedTeamSlot team) {
    final slot = team.slotNumber;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF151D2B),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 27, height: 27,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF29344A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(slot?.toString() ?? '—',
              style: const TextStyle(fontWeight: FontWeight.w900,
                color: KomnivoTheme.cyan, fontSize: 12)),
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(team.displayName,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
          Text(slot == null ? 'UNASSIGNED' : 'SLOT ' + slot.toString(),
            style: const TextStyle(color: KomnivoTheme.muted,
              fontSize: 9, fontWeight: FontWeight.w900)),
        ]),
        if (team.players.isEmpty) ...[
          const SizedBox(height: 6),
          const Text('No player identity rows are attached to this registration.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        ] else ...[
          const SizedBox(height: 6),
          ...team.players.map((player) {
            final title = !player.isVerified
                ? 'Unverified / no linked game-account snapshot'
                : (player.nickname.isEmpty || !player.identitySnapshotAvailable
                    ? 'Verified UID · IGN snapshot unavailable'
                    : player.nickname);
            final detail = player.isVerified
                ? 'UID ' + (player.uid.isEmpty ? '—' : player.uid) +
                    ' · ' + (player.region.isEmpty ? 'Region —' : player.region) +
                    ' · Snapshot ' + player.snapshotAtLabel
                : 'This roster member remains in the team but cannot be name-matched by verified UID.';
            final slotLines = widget.lobbyConfirmed
                ? _readSlotLines(widget.ocrText)
                : <int, List<String>>{};
            final slotUids = widget.lobbyConfirmed
                ? _readSlotUids(widget.ocrText)
                : <int, List<String>>{};
            final playerName = _normalise(player.nickname);
            final seenByName = playerName.isEmpty
                ? <int>[]
                : LiveOpsRosterOcrParser.slotsForExactName(
                    slotLines, player.nickname,
                  );
            final seenByUid = LiveOpsRosterOcrParser.slotsForExactUid(
              slotUids, player.uid,
            );
            final seenSlots = <int>{...seenByName, ...seenByUid}.toList()..sort();
            final compareLabel = !widget.lobbyConfirmed || !player.isVerified ||
                    (playerName.isEmpty && player.uid.isEmpty)
                ? null
                : (seenByUid.contains(team.slotNumber)
                    ? 'Exact UID matched in assigned slot'
                    : (seenByUid.isNotEmpty
                        ? 'Exact UID seen under Slot ' + seenByUid.first.toString()
                        : (seenByName.contains(team.slotNumber)
                            ? 'IGN/name matched in assigned slot'
                            : (seenSlots.length > 1
                                ? 'Possible duplicate · slots ' + seenSlots.join(', ')
                                : (seenSlots.isNotEmpty
                                    ? 'IGN/name seen under Slot ' + seenSlots.first.toString()
                                    : 'Identity not detected in this OCR scan')))));
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(player.isVerified ? Icons.verified_user_outlined : Icons.person_outline,
                  size: 14, color: player.isVerified ? KomnivoTheme.cyan : KomnivoTheme.muted),
                const SizedBox(width: 7),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                  Text(detail, style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
                  if (compareLabel != null)
                    Text(compareLabel, style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: compareLabel.contains('matched in assigned slot')
                          ? KomnivoTheme.cyan
                          : const Color(0xFFFFC078),
                    )),
                ])),
              ]),
            );
          }),
        ],
      ]),
    );
  }

  Widget _buildAlert(_TimedRosterAlert alert) {
    final remaining = alert.expiresAt!.difference(DateTime.now()).inSeconds.clamp(0, 15);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF32281F),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFF8A673C)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(alert.icon, size: 16, color: const Color(0xFFFFC078)),
          const SizedBox(width: 7),
          Expanded(child: Text(alert.title,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900))),
          Text(remaining.toString() + 's',
            style: const TextStyle(color: Color(0xFFFFC078), fontSize: 10,
              fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 6),
        Text(alert.detail, style: const TextStyle(fontSize: 10, height: 1.4,
          color: Color(0xFFE8DED1))),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _processingAlertKeys.contains(alert.key)
                  ? null
                  : () => _recordHostDecision(alert, 'kept_as_is'),
              child: const Text('Keep as-is'),
            ),
            const SizedBox(width: 6),
            FilledButton.tonal(
              onPressed: _processingAlertKeys.contains(alert.key)
                  ? null
                  : () => _recordHostDecision(alert, 'adjusted_in_game'),
              child: _processingAlertKeys.contains(alert.key)
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Adjusted in game'),
            ),
          ],
        ),
      ]),
    );
  }
}

class _ExpectedTeamSlot {
  const _ExpectedTeamSlot({
    required this.teamName,
    required this.teamTag,
    required this.slotNumber,
    required this.players,
  });

  final String teamName;
  final String teamTag;
  final int? slotNumber;
  final List<_ExpectedRosterPlayer> players;

  String get displayName =>
      teamTag.isEmpty ? teamName : '[' + teamTag + '] ' + teamName;

  factory _ExpectedTeamSlot.fromMap(Map<String, dynamic> map) {
    final rawPlayers = map['players'];
    return _ExpectedTeamSlot(
      teamName: map['team_name']?.toString() ?? 'Team',
      teamTag: map['team_tag']?.toString() ?? '',
      slotNumber: int.tryParse(map['slot_number']?.toString() ?? ''),
      players: rawPlayers is List
          ? rawPlayers.whereType<Map>().map((row) =>
              _ExpectedRosterPlayer.fromMap(Map<String, dynamic>.from(row))).toList()
          : <_ExpectedRosterPlayer>[],
    );
  }
}

class _ExpectedRosterPlayer {
  const _ExpectedRosterPlayer({
    required this.userId,
    required this.isVerified,
    required this.uid,
    required this.region,
    required this.nickname,
    required this.profileSnapshotAt,
    required this.identitySnapshotAvailable,
  });

  final String userId;
  final bool isVerified;
  final String uid;
  final String region;
  final String nickname;
  final DateTime? profileSnapshotAt;
  final bool identitySnapshotAvailable;

  String get snapshotAtLabel => profileSnapshotAt == null
      ? 'Unavailable'
      : profileSnapshotAt!.toLocal().toString().split('.').first;

  factory _ExpectedRosterPlayer.fromMap(Map<String, dynamic> map) {
    return _ExpectedRosterPlayer(
      userId: map['user_id']?.toString() ?? '',
      isVerified: map['is_verified'] == true,
      uid: map['uid']?.toString() ?? '',
      region: map['region']?.toString() ?? '',
      nickname: map['nickname']?.toString() ?? '',
      profileSnapshotAt: DateTime.tryParse(map['profile_snapshot_at']?.toString() ?? ''),
      identitySnapshotAvailable: map['identity_snapshot_available'] == true,
    );
  }
}

class _TimedRosterAlert {
  const _TimedRosterAlert({
    required this.key,
    required this.title,
    required this.detail,
    required this.icon,
    this.expiresAt,
  });

  final String key;
  final String title;
  final String detail;
  final IconData icon;
  final DateTime? expiresAt;

  _TimedRosterAlert withExpiry(DateTime expiry) => _TimedRosterAlert(
    key: key,
    title: title,
    detail: detail,
    icon: icon,
    expiresAt: expiry,
  );
}
