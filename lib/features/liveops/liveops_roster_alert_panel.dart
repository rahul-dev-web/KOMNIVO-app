import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';

/// Read-only Match roster comparison. OCR alerts are temporary local suggestions;
/// this widget never edits the official roster or controls the game.
class LiveOpsRosterAlertPanel extends StatefulWidget {
  const LiveOpsRosterAlertPanel({
    super.key,
    required this.sessionId,
    required this.matchId,
    required this.ocrText,
    required this.lobbyConfirmed,
    this.preview = false,
  });

  final String sessionId;
  final String matchId;
  final String ocrText;
  final bool lobbyConfirmed;
  final bool preview;

  @override
  State<LiveOpsRosterAlertPanel> createState() => _LiveOpsRosterAlertPanelState();
}

class _LiveOpsRosterAlertPanelState extends State<LiveOpsRosterAlertPanel> {
  static const Duration _alertLifetime = Duration(seconds: 15);
  static const Duration _repeatSuppression = Duration(seconds: 45);

  final Map<String, DateTime> _recentAlerts = <String, DateTime>{};
  final List<_TimedRosterAlert> _alerts = <_TimedRosterAlert>[];
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
    if (slotLines.isEmpty) return;

    final knownPlayers = _teams
        .expand((team) => team.players)
        .where((player) => player.isVerified &&
            player.identitySnapshotAvailable &&
            player.nickname.trim().isNotEmpty)
        .toList(growable: false);
    final allKnownNames = knownPlayers
        .map((player) => _normalise(player.nickname))
        .where((name) => name.isNotEmpty)
        .toSet();
    final generated = <_TimedRosterAlert>[];

    for (final team in _teams) {
      final slot = team.slotNumber;
      if (slot == null) continue;
      final visibleLines = slotLines[slot] ?? <String>[];
      if (visibleLines.isEmpty) continue;

      final expected = team.players
          .where((player) => player.isVerified &&
              player.identitySnapshotAvailable &&
              player.nickname.trim().isNotEmpty)
          .toList(growable: false);
      final notSeen = <String>[];

      for (final player in expected) {
        final playerName = _normalise(player.nickname);
        final foundSlots = <int>[];
        for (final entry in slotLines.entries) {
          if (entry.value.any((line) => _normalise(line).contains(playerName))) {
            foundSlots.add(entry.key);
          }
        }
        if (foundSlots.length > 1) {
          generated.add(_TimedRosterAlert(
            key: 'duplicate:' + player.userId + ':' + foundSlots.join(','),
            title: 'Possible duplicate player across slots',
            detail: player.nickname + ' was read under multiple slots (' +
                foundSlots.join(', ') + '). This may be an OCR overlap/duplicate row or the same player appearing twice; inspect the live lobby before acting.',
            icon: Icons.copy_all_rounded,
          ));
        }
        if (foundSlots.contains(slot)) continue;
        if (foundSlots.isNotEmpty) {
          final otherSlot = foundSlots.first;
          generated.add(_TimedRosterAlert(
            key: 'slot:' + player.userId + ':' + slot.toString() + ':' + otherSlot.toString(),
            title: 'Player appears in a different slot',
            detail: player.nickname + ' is expected in Slot ' + slot.toString() +
                ' (' + team.displayName + ') but OCR text appears under Slot ' +
                otherSlot.toString() + '. Name-based comparison only; check the game lobby manually.',
            icon: Icons.swap_horiz_rounded,
          ));
        } else {
          notSeen.add(player.nickname);
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
        if (candidate.isEmpty ||
            allKnownNames.any((name) => name.isNotEmpty &&
                (candidate.contains(name) || name.contains(candidate)))) {
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

  Map<int, List<String>> _readSlotLines(String rawText) {
    final result = <int, List<String>>{};
    int? activeSlot;
    final lines = rawText.split(RegExp(r'[\r\n]+'));
    final slotMarker = RegExp(r'\bTEAM\s*#?\s*(\d{1,2})\b', caseSensitive: false);

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final marker = slotMarker.firstMatch(line);
      if (marker != null) {
        activeSlot = int.tryParse(marker.group(1) ?? '');
        if (activeSlot != null) result.putIfAbsent(activeSlot, () => <String>[]);
        final remainder = line.substring(marker.end).trim();
        if (activeSlot != null && _looksLikePlayerName(remainder)) {
          result[activeSlot]!.add(remainder);
        }
        continue;
      }
      if (_isLobbyBoundary(line)) {
        activeSlot = null;
        continue;
      }
      if (activeSlot != null && _looksLikePlayerName(line)) {
        final rows = result.putIfAbsent(activeSlot, () => <String>[]);
        if (!rows.any((value) => _normalise(value) == _normalise(line))) {
          rows.add(line);
        }
      }
    }
    return result;
  }

  bool _isLobbyBoundary(String line) {
    final value = _normalise(line);
    const exact = <String>{
      'startmatch', 'invitefriends', 'invite', 'spectate', 'observe',
      'back', 'exit', 'cancel', 'customroom', 'freefire', 'players',
      'friends', 'roomid', 'password',
    };
    return exact.contains(value);
  }

  bool _looksLikePlayerName(String line) {
    final value = line.trim();
    if (value.length < 3 || value.length > 28 ||
        _isLobbyBoundary(value) ||
        RegExp(r'^\d+$').hasMatch(value) ||
        RegExp(r'^TEAM\s*#?\s*\d+$', caseSensitive: false).hasMatch(value)) {
      return false;
    }
    // Keep Unicode letters and symbols intact; this only selects review candidates.
    return value.runes.any((rune) =>
        (rune >= 48 && rune <= 57) ||
        (rune >= 65 && rune <= 90) ||
        (rune >= 97 && rune <= 122) ||
        rune > 127);
  }

  static String _normalise(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();

  void _expireAlerts() {
    if (!mounted || _alerts.isEmpty) return;
    final now = DateTime.now();
    final remaining = _alerts.where((alert) => alert.expiresAt?.isAfter(now) ?? false).toList();
    setState(() {
      _alerts
        ..clear()
        ..addAll(remaining);
    });
    _recentAlerts.removeWhere((_, until) =>
        until.isBefore(now.subtract(const Duration(minutes: 2))));
  }

  void _markHandled(_TimedRosterAlert alert) {
    _recentAlerts[alert.key] = DateTime.now().add(_repeatSuppression);
    setState(() => _alerts.removeWhere((item) => item.key == alert.key));
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              Text(_teams.length.toString() + ' SLOTS',
                style: const TextStyle(color: KomnivoTheme.muted,
                  fontSize: 9, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Expected identities come from this Match’s registration snapshot. A later IGN refresh does not rename this locked roster.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4),
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
            'Player comparisons are IGN/name-based only unless a visible UID is separately read. Alerts are suggestions, not player verification. “Handled in game” only dismisses the reminder; it does not kick players, move slots or change the official roster.',
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
            final slotLines = widget.lobbyConfirmed ? _readSlotLines(widget.ocrText) : <int, List<String>>{};
            final playerName = _normalise(player.nickname);
            final seenSlots = playerName.isEmpty ? <int>[] : slotLines.entries
                .where((entry) => entry.value.any((line) =>
                    _normalise(line).contains(playerName)))
                .map((entry) => entry.key).toList();
            final compareLabel = !widget.lobbyConfirmed || !player.isVerified ||
                    !player.identitySnapshotAvailable || playerName.isEmpty
                ? null
                : (seenSlots.length > 1
                    ? 'Possible duplicate · slots ' + seenSlots.join(', ')
                    : (seenSlots.contains(team.slotNumber)
                        ? 'IGN/name matched in assigned slot'
                        : (seenSlots.isNotEmpty
                            ? 'IGN/name seen under Slot ' + seenSlots.first.toString()
                            : 'IGN/name not detected in this scan')));
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
                      color: compareLabel == 'IGN/name matched in assigned slot'
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
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => _markHandled(alert),
            child: const Text('Handled in game'),
          ),
        ),
      ]),
    );
  }
}

class _ExpectedTeamSlot {
  const _ExpectedTeamSlot({
    required this.teamId,
    required this.teamName,
    required this.teamTag,
    required this.slotNumber,
    required this.players,
  });

  final String teamId;
  final String teamName;
  final String teamTag;
  final int? slotNumber;
  final List<_ExpectedRosterPlayer> players;

  String get displayName =>
      teamTag.isEmpty ? teamName : '[' + teamTag + '] ' + teamName;

  factory _ExpectedTeamSlot.fromMap(Map<String, dynamic> map) {
    final rawPlayers = map['players'];
    return _ExpectedTeamSlot(
      teamId: map['team_id']?.toString() ?? '',
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
