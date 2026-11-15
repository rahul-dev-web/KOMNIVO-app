import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

const freeFireGameId = '11111111-1111-4111-8111-111111111111';

class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key, required this.preview});
  final bool preview;
  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  final TextEditingController _searchController = TextEditingController();
  Future<List<Map<String, dynamic>>>? _future;
  Future<List<Map<String, dynamic>>>? _invitesFuture;
  @override
  void initState() {
    super.initState();
    if (!widget.preview) _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = KomnivoRepository.instance.teams();
      final client = Supabase.instance.client;
      _invitesFuture = client.from('team_invites')
        .select('*, teams(name,tag)')
        .eq('invited_user_id', client.auth.currentUser!.id)
        .eq('status', 'pending')
        .order('created_at', ascending: false);
    });
  }

  Future<void> _createTeam() async {
    final name = TextEditingController();
    final tag = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Create your team'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Team name')),
        const SizedBox(height: 12),
        TextField(controller: tag, maxLength: 5, decoration: const InputDecoration(labelText: 'Short tag (optional)')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create team'))],
    ));
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    try {
      await KomnivoRepository.instance.createTeam(name: name.text.trim(), tag: tag.text.trim(), gameId: freeFireGameId);
      _reload();
      if (mounted) showMessage(context, 'Team created. You are its owner.');
    } catch (error) { if (mounted) showMessage(context, error.toString()); }
    finally { name.dispose(); tag.dispose(); }
  }

  Future<void> _invitePlayer(Map<String, dynamic> team) async {
    final search = TextEditingController();
    List<Map<String, dynamic>> people = [];
    bool searching = false;
    String? errorText;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Invite to ${team['name']}'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: search,
              decoration: InputDecoration(
                labelText: 'Search public player names',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () async {
                    if (search.text.trim().length < 2) {
                      setDialogState(() => errorText = 'Enter at least 2 characters.');
                      return;
                    }
                    setDialogState(() { searching = true; people = []; errorText = null; });
                    try {
                      final rows = await Supabase.instance.client.from('profiles')
                        .select('id,display_name,username')
                        .neq('id', KomnivoRepository.instance.userId)
                        .ilike('display_name', '%${search.text.trim()}%')
                        .limit(8);
                      setDialogState(() => people = List<Map<String, dynamic>>.from(rows));
                    } catch (error) {
                      setDialogState(() => errorText = error.toString());
                    } finally {
                      setDialogState(() => searching = false);
                    }
                  },
                ),
              ),
              onSubmitted: (_) async {
                if (search.text.trim().length < 2) return;
                setDialogState(() { searching = true; people = []; errorText = null; });
                try {
                  final rows = await Supabase.instance.client.from('profiles')
                    .select('id,display_name,username')
                    .neq('id', KomnivoRepository.instance.userId)
                    .ilike('display_name', '%${search.text.trim()}%')
                    .limit(8);
                  setDialogState(() => people = List<Map<String, dynamic>>.from(rows));
                } catch (error) {
                  setDialogState(() => errorText = error.toString());
                } finally {
                  setDialogState(() => searching = false);
                }
              },
            ),
            const SizedBox(height: 10),
            if (searching) const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
            if (errorText != null) Text(errorText!, style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12)),
            if (people.isNotEmpty) SizedBox(
              height: 240,
              child: ListView(children: people.map((person) => ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(person['display_name']?.toString() ?? 'Player'),
                subtitle: Text(person['username']?.toString().isNotEmpty == true ? '@${person['username']}' : 'KOMNIVO player'),
                trailing: const Icon(Icons.person_add_alt_1, color: KomnivoTheme.cyan),
                onTap: () async {
                  try {
                    await Supabase.instance.client.from('team_invites').insert({
                      'team_id': team['id'],
                      'invited_user_id': person['id'],
                      'invited_by': KomnivoRepository.instance.userId,
                    });
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                    if (mounted) showMessage(this.context, 'Team invitation sent.');
                  } catch (error) {
                    setDialogState(() => errorText = error.toString());
                  }
                },
              )).toList()),
            ),
            if (!searching && people.isEmpty && errorText == null)
              const Padding(padding: EdgeInsets.all(10), child: Text('Search by the public display name of the player.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12))),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
        ),
      ),
    );
    search.dispose();
  }

  Future<void> _acceptInvite(String inviteId) async {
    try {
      final response = await Supabase.instance.client.functions.invoke('accept-team-invite', body: {'invite_id': inviteId});
      if (response.status < 200 || response.status >= 300) throw Exception('Invitation could not be accepted.');
      _reload();
      if (mounted) showMessage(context, 'You joined the team.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _openTeam(Map<String, dynamic> team) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => _TeamClubhouseScreen(
        team: team,
        preview: widget.preview,
        onInvite: _invitePlayer,
      ),
    ));
    if (mounted && !widget.preview) _reload();
  }

  Widget _directory({
    required List<Map<String, dynamic>> teams,
    required List<Map<String, dynamic>> invites,
    required bool preview,
  }) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = teams.where((team) {
      final name = (team['name']?.toString() ?? '').toLowerCase();
      final tag = (team['tag']?.toString() ?? '').toLowerCase();
      return query.isEmpty || name.contains(query) || tag.contains(query);
    }).toList();

    return RefreshIndicator(
      onRefresh: () async {
        if (preview) return;
        final next = KomnivoRepository.instance.teams();
        setState(() => _future = next);
        try { await next; } catch (_) {}
      },
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 480;
        final desktop = constraints.maxWidth >= 900;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(compact ? 16 : 28, 18, compact ? 16 : 28, 28),
          children: [
            if (preview) const PreviewBanner(),
            Row(children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  gradient: KomnivoTheme.brandGradient,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.shield_moon_rounded, color: Colors.white, size: 25),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Team Clubhouse', style: TextStyle(
                    fontSize: compact ? 20 : 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.6,
                  )),
                  const SizedBox(height: 3),
                  Text(filtered.length.toString() + ' squads in your arena',
                    style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                ],
              )),
              FilledButton.icon(
                onPressed: _createTeam,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(compact ? 'Create' : 'Create team'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 42),
                  padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 15),
                ),
              ),
            ]),
            const SizedBox(height: 15),
            SizedBox(height: 44, child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search teams by name or tag',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty ? null : IconButton(
                  onPressed: () { _searchController.clear(); setState(() {}); },
                  icon: const Icon(Icons.close_rounded),
                ),
                isDense: true,
              ),
            )),
            if (invites.isNotEmpty) ...[
              const SizedBox(height: 19),
              _ClubhouseInvites(invites: invites, onAccept: _acceptInvite),
            ],
            const SizedBox(height: 24),
            _DirectoryHeading(
              title: 'Squad Spaces',
              subtitle: 'Every team has its own identity and clubhouse',
              count: filtered.length,
            ),
            const SizedBox(height: 11),
            if (filtered.isEmpty)
              _ClubhouseEmpty(
                title: query.isEmpty ? 'Your clubhouse starts here' : 'No teams match your search',
                message: query.isEmpty
                  ? 'Create a team or accept an invitation to build your squad.'
                  : 'Try another team name or tag.',
                icon: Icons.shield_moon_outlined,
              )
            else
              _ClubhouseGrid(teams: filtered, desktop: desktop, onOpen: _openTeam),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) {
      return _directory(
        preview: true,
        invites: const [],
        teams: [
          {
            'id': 'preview-komnivo',
            'name': 'Komnivo',
            'tag': 'KMNV',
            'description': 'From scrims to championships, we rise as one.',
            'games': {'name': 'Free Fire MAX'},
            'team_members': [{'count': 6}],
            'owner_user_id': '',
          },
          {
            'id': 'preview-iron',
            'name': 'Iron Wolves',
            'tag': 'IRNW',
            'description': 'Built for the final circle.',
            'games': {'name': 'Free Fire MAX'},
            'team_members': [{'count': 5}],
            'owner_user_id': 'other',
          },
        ],
      );
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ClubhouseError(message: snapshot.error.toString(), onRetry: _reload);
        }
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _invitesFuture,
          builder: (context, inviteSnapshot) => _directory(
            preview: false,
            teams: snapshot.data ?? const [],
            invites: inviteSnapshot.data ?? const [],
          ),
        );
      },
    );
  }
}


class _ClubhouseGrid extends StatelessWidget {
  const _ClubhouseGrid({required this.teams, required this.desktop, required this.onOpen});
  final List<Map<String, dynamic>> teams;
  final bool desktop;
  final ValueChanged<Map<String, dynamic>> onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final columns = box.maxWidth >= 900 ? 3 : box.maxWidth >= 560 ? 2 : 1;
    const gap = 12.0;
    final width = (box.maxWidth - gap * (columns - 1)) / columns;
    return Wrap(
      spacing: gap, runSpacing: gap,
      children: teams.map((team) => SizedBox(
        width: width,
        child: _ClubhouseTeamCard(team: team, onTap: () => onOpen(team)),
      )).toList(),
    );
  });
}

class _ClubhouseTeamCard extends StatelessWidget {
  const _ClubhouseTeamCard({required this.team, required this.onTap});
  final Map<String, dynamic> team;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final game = team['games'] is Map ? (team['games'] as Map)['name']?.toString() : null;
    final rawMembers = team['team_members'];
    final members = rawMembers is List && rawMembers.isNotEmpty
      ? ((rawMembers.first as Map)['count'] as num?)?.toInt() ?? 0 : 0;
    final tag = team['tag']?.toString() ?? 'TEAM';
    return Material(
      color: KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: KomnivoTheme.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _TeamEmblem(tag: tag, size: 54),
              const Spacer(),
              const _ClubhousePill(label: 'CLUBHOUSE', color: KomnivoTheme.accent),
            ]),
            const SizedBox(height: 14),
            Text(team['name']?.toString() ?? 'Team',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(height: 5),
            Text((game ?? 'Free Fire MAX') + '  ·  #' + tag,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            if ((team['description']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(team['description'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4)),
            ],
            const SizedBox(height: 15),
            Row(children: [
              const Icon(Icons.groups_2_outlined, size: 16, color: KomnivoTheme.cyan),
              const SizedBox(width: 6),
              Text(members.toString() + ' members',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11)),
              const Spacer(),
              const Text('Open clubhouse',
                style: TextStyle(color: KomnivoTheme.accent, fontSize: 11, fontWeight: FontWeight.w800)),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_rounded, size: 14, color: KomnivoTheme.accent),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _TeamClubhouseScreen extends StatefulWidget {
  const _TeamClubhouseScreen({required this.team, required this.preview, required this.onInvite});
  final Map<String, dynamic> team;
  final bool preview;
  final Future<void> Function(Map<String, dynamic>) onInvite;
  @override
  State<_TeamClubhouseScreen> createState() => _TeamClubhouseScreenState();
}

class _TeamClubhouseScreenState extends State<_TeamClubhouseScreen> {
  Future<_ClubhouseData>? _future;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _future = widget.preview ? Future.value(_sampleData()) : _load();
  }

  Future<void> _reload() async {
    if (widget.preview) return;
    final next = _load();
    setState(() => _future = next);
    try { await next; } catch (_) {}
  }

  Future<_ClubhouseData> _load() async {
    final client = Supabase.instance.client;
    final teamId = widget.team['id']?.toString() ?? '';
    final rawRoster = await client.from('team_members').select(
      'user_id,role,joined_at,profiles(id,display_name,username,avatar_url)')
      .eq('team_id', teamId).order('joined_at', ascending: true);
    final roster = List<Map<String, dynamic>>.from(rawRoster);
    final userId = client.auth.currentUser?.id;
    Map<String, dynamic>? own;
    for (final row in roster) {
      if (row['user_id'] == userId) { own = row; break; }
    }
    final role = own?['role']?.toString() ??
      (widget.team['owner_user_id'] == userId ? 'owner' : null);
    final isMember = own != null;

    final rawStandings = await client.from('event_standings').select(
      'event_id,points,kills,matches_played,first_places,updated_at,events(name,status,starts_at)')
      .eq('team_id', teamId).order('updated_at', ascending: false).limit(12);
    final standings = List<Map<String, dynamic>>.from(rawStandings);

    List<Map<String, dynamic>> results = [];
    List<Map<String, dynamic>> upcoming = [];
    if (isMember) {
      try {
        final rows = await client.from('match_results').select(
          'id,placement,kills,points,status,submitted_at,approved_at,matches(match_number,event_id,events(name))')
          .eq('team_id', teamId).eq('status', 'approved')
          .order('approved_at', ascending: false).limit(6);
        results = List<Map<String, dynamic>>.from(rows);
      } catch (_) {}
      try {
        final rows = await client.from('event_registrations').select(
          'id,status,registered_at,events(id,name,status,starts_at,format)')
          .eq('team_id', teamId)
          .inFilter('status', ['pending', 'approved', 'checked_in'])
          .order('registered_at', ascending: false).limit(5);
        upcoming = List<Map<String, dynamic>>.from(rows);
      } catch (_) {}
    }
    return _ClubhouseData(
      roster: roster, standings: standings, results: results, upcoming: upcoming,
      role: role, isMember: isMember,
    );
  }

  _ClubhouseData _sampleData() {
    Map<String, dynamic> player(String name, String handle, String role) => {
      'user_id': 'preview-' + handle,
      'role': role,
      'joined_at': DateTime.now().toIso8601String(),
      'profiles': {'id': 'preview-' + handle, 'display_name': name, 'username': handle, 'avatar_url': null},
    };
    return _ClubhouseData(
      roster: [
        player('Nova', 'nova_igl', 'owner'),
        player('Raze', 'razeff', 'captain'),
        player('Vex', 'vexx', 'member'),
        player('Kova', 'kova_playz', 'member'),
        player('Blaze', 'blaze_yt', 'member'),
        player('Phantom', 'phantomx', 'substitute'),
      ],
      standings: [
        {'event_id':'p1','points':1850,'kills':94,'matches_played':6,'first_places':2,
         'updated_at':DateTime.now().toIso8601String(),
         'events':{'name':'Invitational Playoffs','status':'completed'}},
        {'event_id':'p2','points':3000,'kills':126,'matches_played':8,'first_places':1,
         'updated_at':DateTime.now().subtract(const Duration(days:2)).toIso8601String(),
         'events':{'name':'National Clash Cup','status':'completed'}},
      ],
      results: const [],
      upcoming: [
        {'id':'next','status':'approved','events':{'name':'KOMNIVO Championship',
          'starts_at':'2026-12-02T18:30:00Z','status':'published','format':'squad'}},
      ],
      role: 'owner', isMember: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    final name = team['name']?.toString() ?? 'Team';
    final tag = team['tag']?.toString() ?? 'TEAM';
    final game = team['games'] is Map ? (team['games'] as Map)['name']?.toString() : null;
    final compact = MediaQuery.sizeOf(context).width < 560;

    return Scaffold(
      backgroundColor: KomnivoTheme.background,
      body: SafeArea(child: FutureBuilder<_ClubhouseData>(
        future: _future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (snapshot.connectionState == ConnectionState.waiting && data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) return _ClubhouseError(
            message: snapshot.error.toString(), onRetry: _reload);
          if (data == null) return _ClubhouseError(
            message: 'Team details could not be loaded.', onRetry: _reload);

          final stats = _ClubhouseMetrics.fromRows(data.standings);
          final starters = data.roster.where((m) => m['role'] != 'substitute').toList();
          final subs = data.roster.where((m) => m['role'] == 'substitute').toList();

          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(compact ? 16 : 28, 8, compact ? 16 : 28, 28),
              children: [
                Row(children: [
                  IconButton(onPressed: () => Navigator.pop(context),
                    tooltip: 'Back to teams', icon: const Icon(Icons.arrow_back_rounded)),
                  const Icon(Icons.shield_moon_rounded, size: 17, color: KomnivoTheme.accent),
                  const SizedBox(width: 7),
                  Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
                  IconButton(onPressed: _reload, tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh_rounded, size: 19)),
                ]),
                if (widget.preview) const PreviewBanner(),
                const SizedBox(height: 10),
                _ClubhouseHero(
                  team: team, name: name, tag: tag, game: game ?? 'Free Fire MAX',
                  memberCount: data.roster.length,
                  canInvite: const {'owner','captain'}.contains(data.role),
                  onInvite: () async {
                    await widget.onInvite(team);
                    if (mounted) await _reload();
                  },
                ),
                const SizedBox(height: 18),
                _ClubhouseTabs(selected: _tab, onSelect: (v) => setState(() => _tab = v)),
                const SizedBox(height: 20),
                if (_tab == 0) ...[
                  const _ClubhouseHeading(title: 'Team Performance',
                    subtitle: 'The numbers behind your journey', trailing: 'SEASON RECORD'),
                  const SizedBox(height: 11),
                  _ClubhouseStats(stats: stats, compact: compact),
                  const SizedBox(height: 24),
                  _FeaturedRoster(
                    members: starters.take(4).toList(), total: data.roster.length,
                    compact: compact, onViewAll: () => setState(() => _tab = 1),
                  ),
                  const SizedBox(height: 24),
                  _TrophyShelf(standings: data.standings, compact: compact),
                  const SizedBox(height: 24),
                  _TeamActivity(results: data.results, standings: data.standings,
                    upcoming: data.upcoming, isMember: data.isMember),
                ] else if (_tab == 1) ...[
                  _ClubhouseHeading(title: 'The Squad',
                    subtitle: 'The players who represent this badge',
                    trailing: data.roster.length.toString() + ' MEMBERS'),
                  const SizedBox(height: 11),
                  _RosterCards(title: 'Starting lineup', subtitle: 'Core team members',
                    members: starters, compact: compact),
                  if (subs.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    _RosterCards(title: 'Substitutes',
                      subtitle: 'Ready when the squad needs them', members: subs, compact: compact),
                  ],
                  if (const {'owner','captain'}.contains(data.role)) ...[
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      onPressed: () async { await widget.onInvite(team); if (mounted) await _reload(); },
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Invite player to squad'),
                    ),
                  ],
                ] else ...[
                  const _ClubhouseHeading(title: 'Competitive Record',
                    subtitle: 'Published standings and approved results',
                    trailing: 'OFFICIAL DATA'),
                  const SizedBox(height: 11),
                  _ClubhouseStats(stats: stats, compact: compact),
                  const SizedBox(height: 24),
                  _TrophyShelf(standings: data.standings, compact: compact),
                  const SizedBox(height: 24),
                  _TeamActivity(results: data.results, standings: data.standings,
                    upcoming: data.upcoming, isMember: data.isMember),
                ],
              ],
            ),
          );
        },
      )),
    );
  }
}

class _ClubhouseData {
  const _ClubhouseData({
    required this.roster, required this.standings, required this.results,
    required this.upcoming, required this.role, required this.isMember,
  });
  final List<Map<String, dynamic>> roster;
  final List<Map<String, dynamic>> standings;
  final List<Map<String, dynamic>> results;
  final List<Map<String, dynamic>> upcoming;
  final String? role;
  final bool isMember;
}

class _ClubhouseMetrics {
  const _ClubhouseMetrics({required this.points, required this.matches,
    required this.kills, required this.firstPlaces});
  factory _ClubhouseMetrics.fromRows(List<Map<String, dynamic>> rows) {
    int sum(String key) => rows.fold<int>(0,
      (n, row) => n + ((row[key] as num?)?.toInt() ?? 0));
    return _ClubhouseMetrics(points: sum('points'), matches: sum('matches_played'),
      kills: sum('kills'), firstPlaces: sum('first_places'));
  }
  final int points, matches, kills, firstPlaces;
}

class _DirectoryHeading extends StatelessWidget {
  const _DirectoryHeading({required this.title, required this.subtitle, required this.count});
  final String title, subtitle; final int count;
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
    ])),
    _ClubhousePill(label: count.toString(), color: KomnivoTheme.cyan),
  ]);
}

class _ClubhouseHero extends StatelessWidget {
  const _ClubhouseHero({required this.team, required this.name, required this.tag,
    required this.game, required this.memberCount, required this.canInvite, required this.onInvite});
  final Map<String, dynamic> team;
  final String name, tag, game;
  final int memberCount;
  final bool canInvite;
  final VoidCallback onInvite;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF211A43), Color(0xFF111A30), Color(0xFF0D111B)]),
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .32)),
      ),
      child: Stack(children: [
        Positioned(right: -55, top: -75, child: Container(width: 220, height: 220,
          decoration: BoxDecoration(shape: BoxShape.circle,
            color: KomnivoTheme.accent.withValues(alpha: .09)))),
        Positioned(right: 35, bottom: -125, child: Container(width: 210, height: 210,
          decoration: BoxDecoration(shape: BoxShape.circle,
            border: Border.all(color: KomnivoTheme.cyan.withValues(alpha: .13), width: 24)))),
        Padding(
          padding: const EdgeInsets.all(22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const _ClubhousePill(label: 'TEAM CLUBHOUSE', color: KomnivoTheme.accent),
              const SizedBox(width: 9),
              Expanded(child: Text(game.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9,
                  fontWeight: FontWeight.w800, letterSpacing: 1))),
            ]),
            const SizedBox(height: 19),
            Row(children: [
              _TeamEmblem(tag: tag, size: 78),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -.8)),
                const SizedBox(height: 5),
                Text('#' + tag, style: const TextStyle(color: KomnivoTheme.cyan,
                  fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                const SizedBox(height: 7),
                Text(memberCount.toString() + ' members  ·  ' +
                  (team['is_public'] == false ? 'Private squad' : 'Public squad'),
                  style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
              ])),
            ]),
            if ((team['description']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(team['description'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFD2D8E6), fontSize: 12, height: 1.4)),
            ] else ...[
              const SizedBox(height: 16),
              const Text('Our identity. Our legacy. Together we rise.',
                style: TextStyle(color: Color(0xFFD2D8E6), fontSize: 12)),
            ],
            if (canInvite) ...[
              const SizedBox(height: 18),
              FilledButton.icon(onPressed: onInvite,
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
                label: const Text('Invite player'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 14))),
            ],
          ]),
        ),
      ]),
    ),
  );
}

class _ClubhouseTabs extends StatelessWidget {
  const _ClubhouseTabs({required this.selected, required this.onSelect});
  final int selected; final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      _ClubhouseTab(label: 'Overview', icon: Icons.grid_view_rounded,
        selected: selected == 0, onTap: () => onSelect(0)),
      _ClubhouseTab(label: 'Roster', icon: Icons.groups_2_rounded,
        selected: selected == 1, onTap: () => onSelect(1)),
      _ClubhouseTab(label: 'Performance', icon: Icons.insights_rounded,
        selected: selected == 2, onTap: () => onSelect(2)),
    ]),
  );
}

class _ClubhouseTab extends StatelessWidget {
  const _ClubhouseTab({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label; final IconData icon; final bool selected; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(child: Material(
    color: selected ? KomnivoTheme.accent.withValues(alpha: .18) : Colors.transparent,
    borderRadius: BorderRadius.circular(11),
    child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(11),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 3),
        child: Column(children: [
          Icon(icon, size: 17, color: selected ? Colors.white : KomnivoTheme.muted),
          const SizedBox(height: 5),
          FittedBox(child: Text(label, style: TextStyle(fontSize: 10,
            fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
            color: selected ? Colors.white : KomnivoTheme.muted))),
        ]),
      ),
    ),
  ));
}

class _ClubhouseHeading extends StatelessWidget {
  const _ClubhouseHeading({required this.title, required this.subtitle, this.trailing});
  final String title, subtitle; final String? trailing;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
    ])),
    if (trailing != null) Text(trailing!, style: const TextStyle(color: KomnivoTheme.cyan,
      fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8)),
  ]);
}

class _ClubhouseStats extends StatelessWidget {
  const _ClubhouseStats({required this.stats, required this.compact});
  final _ClubhouseMetrics stats; final bool compact;
  @override
  Widget build(BuildContext context) {
    final items = [
      _ClubMetric('Team points', stats.points, Icons.bolt_rounded, KomnivoTheme.accent),
      _ClubMetric('Matches', stats.matches, Icons.sports_esports_rounded, KomnivoTheme.cyan),
      _ClubMetric('Total kills', stats.kills, Icons.local_fire_department_rounded, const Color(0xFFFF9D6C)),
      _ClubMetric('1st places', stats.firstPlaces, Icons.emoji_events_rounded, const Color(0xFFFFD27A)),
    ];
    return LayoutBuilder(builder: (context, box) {
      final columns = box.maxWidth < 390 ? 2 : 4;
      const gap = 9.0; final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(spacing: gap, runSpacing: gap,
        children: items.map((item) => SizedBox(width: width,
          child: _MetricCard(metric: item, compact: compact))).toList());
    });
  }
}

class _ClubMetric {
  const _ClubMetric(this.label, this.value, this.icon, this.color);
  final String label; final int value; final IconData icon; final Color color;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric, required this.compact});
  final _ClubMetric metric; final bool compact;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(compact ? 12 : 15),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(17),
      border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 32, height: 32,
        decoration: BoxDecoration(color: metric.color.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(10)),
        child: Icon(metric.icon, size: 17, color: metric.color)),
      const SizedBox(height: 11),
      Text(_formatClubNumber(metric.value), style: TextStyle(
        fontSize: compact ? 19 : 23, fontWeight: FontWeight.w900, letterSpacing: -.5)),
      const SizedBox(height: 3),
      Text(metric.label, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, fontWeight: FontWeight.w600)),
    ]),
  );
}

class _FeaturedRoster extends StatelessWidget {
  const _FeaturedRoster({required this.members, required this.total, required this.compact, required this.onViewAll});
  final List<Map<String, dynamic>> members; final int total; final bool compact; final VoidCallback onViewAll;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      const Expanded(child: _ClubhouseHeading(title: 'Featured Roster',
        subtitle: 'The faces behind the team badge', trailing: 'SQUAD')),
      TextButton(onPressed: onViewAll, child: const Text('View all')),
    ]),
    const SizedBox(height: 11),
    if (members.isEmpty)
      const _ClubhouseEmpty(title: 'Your roster is waiting',
        message: 'Invite players to fill the clubhouse with your squad.', icon: Icons.groups_2_outlined)
    else
      _RosterGrid(members: members, compact: compact),
    if (total > members.length) Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Text('+ ' + (total - members.length).toString() + ' more squad members',
        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
    ),
  ]);
}

class _RosterCards extends StatelessWidget {
  const _RosterCards({required this.title, required this.subtitle, required this.members, required this.compact});
  final String title, subtitle; final List<Map<String, dynamic>> members; final bool compact;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _ClubhouseHeading(title: title, subtitle: subtitle, trailing: members.length.toString() + ' PLAYERS'),
    const SizedBox(height: 11),
    if (members.isEmpty)
      const _ClubhouseEmpty(title: 'No players in this lineup yet',
        message: 'Invite a player to add them to the squad.', icon: Icons.person_add_alt_1_rounded)
    else
      _RosterGrid(members: members, compact: compact),
  ]);
}

class _RosterGrid extends StatelessWidget {
  const _RosterGrid({required this.members, required this.compact});
  final List<Map<String, dynamic>> members; final bool compact;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final columns = box.maxWidth < 430 ? 2 : box.maxWidth < 760 ? 3 : 4;
    const gap = 9.0; final width = (box.maxWidth - gap * (columns - 1)) / columns;
    return Wrap(spacing: gap, runSpacing: gap, children: members.map((member) =>
      SizedBox(width: width, child: _RosterCard(member: member, compact: compact))).toList());
  });
}

class _RosterCard extends StatelessWidget {
  const _RosterCard({required this.member, required this.compact});
  final Map<String, dynamic> member; final bool compact;
  @override
  Widget build(BuildContext context) {
    final profile = member['profiles'] is Map ? member['profiles'] as Map : const {};
    final name = profile['display_name']?.toString() ?? 'Player';
    final username = profile['username']?.toString() ?? '';
    final role = member['role']?.toString() ?? 'member';
    return Container(
      padding: EdgeInsets.all(compact ? 11 : 13),
      decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(17),
        border: Border.all(color: KomnivoTheme.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _ClubhouseAvatar(name: name, url: profile['avatar_url']?.toString(), size: compact ? 42 : 48),
          const Spacer(),
          if (role == 'owner') const Icon(Icons.verified_rounded, size: 17, color: KomnivoTheme.accent),
        ]),
        const SizedBox(height: 11),
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text(username.isEmpty ? 'KOMNIVO player' : '@' + username,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        const SizedBox(height: 10),
        _ClubhousePill(label: _clubRole(role).toUpperCase(),
          color: role == 'owner' || role == 'captain' ? KomnivoTheme.accent :
            role == 'substitute' ? const Color(0xFFFFBE70) : KomnivoTheme.cyan),
      ]),
    );
  }
}

class _TrophyShelf extends StatelessWidget {
  const _TrophyShelf({required this.standings, required this.compact});
  final List<Map<String, dynamic>> standings; final bool compact;
  @override
  Widget build(BuildContext context) {
    final awards = standings.where((row) => ((row['first_places'] as num?)?.toInt() ?? 0) > 0).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _ClubhouseHeading(title: 'Trophy Shelf',
        subtitle: 'Milestones earned in published competitions', trailing: 'HALL OF FAME'),
      const SizedBox(height: 11),
      if (awards.isEmpty)
        const _ClubhouseEmpty(title: 'The first trophy is waiting',
          message: 'Approved first-place finishes will appear here as your team competes.',
          icon: Icons.emoji_events_outlined)
      else
        LayoutBuilder(builder: (context, box) {
          final columns = box.maxWidth < 430 ? 1 : 2;
          const gap = 9.0; final width = (box.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(spacing: gap, runSpacing: gap, children: awards.map((row) {
            final event = row['events'] is Map ? row['events'] as Map : const {};
            return SizedBox(width: width, child: _TrophyCard(
              eventName: event['name']?.toString() ?? 'Competition',
              firstPlaces: (row['first_places'] as num?)?.toInt() ?? 0,
              points: (row['points'] as num?)?.toInt() ?? 0, compact: compact,
            ));
          }).toList());
        }),
    ]);
  }
}

class _TrophyCard extends StatelessWidget {
  const _TrophyCard({required this.eventName, required this.firstPlaces, required this.points, required this.compact});
  final String eventName; final int firstPlaces, points; final bool compact;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFF29233E), Color(0xFF111722)]),
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: const Color(0xFFFFD27A).withValues(alpha: .28)),
    ),
    child: Row(children: [
      Container(width: compact ? 43 : 48, height: compact ? 43 : 48,
        decoration: BoxDecoration(color: const Color(0xFFFFD27A).withValues(alpha: .13),
          borderRadius: BorderRadius.circular(14)),
        child: const Icon(Icons.emoji_events_rounded, color: Color(0xFFFFD27A), size: 25)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(eventName, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(firstPlaces.toString() + ' first-place ' +
          (firstPlaces == 1 ? 'finish' : 'finishes') + '  ·  ' +
          _formatClubNumber(points) + ' pts',
          maxLines: 2, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
      ])),
    ]),
  );
}

class _TeamActivity extends StatelessWidget {
  const _TeamActivity({required this.results, required this.standings, required this.upcoming, required this.isMember});
  final List<Map<String, dynamic>> results, standings, upcoming; final bool isMember;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const _ClubhouseHeading(title: 'Team Activity',
      subtitle: 'Recent competitive moments and what is next', trailing: 'LATEST'),
    const SizedBox(height: 11),
    ...upcoming.take(2).map((row) {
      final event = row['events'] is Map ? row['events'] as Map : const {};
      return Padding(padding: const EdgeInsets.only(bottom: 9), child: _ActivityCard(
        icon: Icons.event_available_rounded, color: KomnivoTheme.cyan,
        title: event['name']?.toString() ?? 'Upcoming event',
        subtitle: 'Registration: ' + _clubHuman(row['status']?.toString() ?? 'pending'),
        trailing: _clubDate(event['starts_at']?.toString()),
      ));
    }),
    ...results.take(4).map((row) {
      final match = row['matches'] is Map ? row['matches'] as Map : const {};
      final event = match['events'] is Map ? match['events'] as Map : const {};
      final place = (row['placement'] as num?)?.toInt();
      final title = place == null ? 'Match result approved' :
        place == 1 ? 'First-place finish' : place.toString() + ' place finish';
      return Padding(padding: const EdgeInsets.only(bottom: 9), child: _ActivityCard(
        icon: place == 1 ? Icons.emoji_events_rounded : Icons.sports_esports_rounded,
        color: place == 1 ? const Color(0xFFFFD27A) : KomnivoTheme.accent,
        title: title,
        subtitle: (event['name']?.toString() ?? 'Competition') + '  ·  ' +
          (row['kills']?.toString() ?? '0') + ' kills  ·  ' + (row['points']?.toString() ?? '0') + ' pts',
        trailing: _clubDate(row['approved_at']?.toString() ?? row['submitted_at']?.toString()),
      ));
    }),
    if (upcoming.isEmpty && results.isEmpty)
      _ClubhouseEmpty(title: 'Your story is just beginning',
        message: isMember
          ? 'Approved match results and published standings will appear here.'
          : 'Join this squad to see member-only match activity and registrations.',
        icon: Icons.auto_awesome_outlined),
  ]);
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.icon, required this.color, required this.title, required this.subtitle, required this.trailing});
  final IconData icon; final Color color; final String title, subtitle, trailing;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(16),
      border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      Container(width: 38, height: 38,
        decoration: BoxDecoration(color: color.withValues(alpha: .13), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: color, size: 19)),
      const SizedBox(width: 11),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
      ])),
      const SizedBox(width: 8),
      Text(trailing, textAlign: TextAlign.end,
        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
    ]),
  );
}

class _TeamEmblem extends StatelessWidget {
  const _TeamEmblem({required this.tag, required this.size});
  final String tag; final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      gradient: KomnivoTheme.brandGradient,
      borderRadius: BorderRadius.circular(size * .28),
      boxShadow: [BoxShadow(color: KomnivoTheme.accent.withValues(alpha: .16), blurRadius: 15)],
    ),
    child: Stack(alignment: Alignment.center, children: [
      Icon(Icons.shield_rounded, color: Colors.white.withValues(alpha: .2), size: size * .8),
      Padding(padding: const EdgeInsets.all(5),
        child: FittedBox(child: Text(tag.isEmpty ? 'TEAM' : tag.toUpperCase(),
          style: TextStyle(color: Colors.white, fontSize: size * .23,
            fontWeight: FontWeight.w900, letterSpacing: .4)))),
    ]),
  );
}

class _ClubhouseAvatar extends StatelessWidget {
  const _ClubhouseAvatar({required this.name, required this.url, required this.size});
  final String name; final String? url; final double size;
  @override
  Widget build(BuildContext context) {
    final image = url?.trim() ?? '';
    final initials = name.trim().split(RegExp(r'\s+')).where((v) => v.isNotEmpty)
      .take(2).map((v) => v[0].toUpperCase()).join();
    return Container(
      width: size, height: size, clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: KomnivoTheme.brandGradient,
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .5), width: 1.5)),
      child: image.isEmpty
        ? Center(child: Text(initials.isEmpty ? 'P' : initials,
            style: TextStyle(color: Colors.white, fontSize: size * .32, fontWeight: FontWeight.w900)))
        : Image.network(image, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Center(child: Text(initials.isEmpty ? 'P' : initials))),
    );
  }
}

class _ClubhousePill extends StatelessWidget {
  const _ClubhousePill({required this.label, required this.color});
  final String label; final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(30),
      border: Border.all(color: color.withValues(alpha: .3))),
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .7)),
  );
}

class _ClubhouseInvites extends StatelessWidget {
  const _ClubhouseInvites({required this.invites, required this.onAccept});
  final List<Map<String, dynamic>> invites; final Future<void> Function(String) onAccept;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: const Color(0xFF17152A), borderRadius: BorderRadius.circular(18),
      border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .4))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.mark_email_unread_outlined, color: KomnivoTheme.accent, size: 19),
        const SizedBox(width: 8),
        const Expanded(child: Text('Squad invitations', style: TextStyle(fontWeight: FontWeight.w900))),
        _ClubhousePill(label: invites.length.toString(), color: KomnivoTheme.cyan),
      ]),
      const SizedBox(height: 10),
      ...invites.map((invite) {
        final team = invite['teams'] is Map ? invite['teams'] as Map : const {};
        return Padding(padding: const EdgeInsets.only(top: 7), child: Row(children: [
          _TeamEmblem(tag: team['tag']?.toString() ?? 'TEAM', size: 38),
          const SizedBox(width: 10),
          Expanded(child: Text(team['name']?.toString() ?? 'A team',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
          FilledButton(
            onPressed: invite['id'] == null ? null : () => onAccept(invite['id'].toString()),
            style: FilledButton.styleFrom(minimumSize: const Size(78, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: const Text('Accept'),
          ),
        ]));
      }),
    ]),
  );
}

class _ClubhouseEmpty extends StatelessWidget {
  const _ClubhouseEmpty({required this.title, required this.message, required this.icon});
  final String title, message; final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18),
      border: Border.all(color: KomnivoTheme.line)),
    child: Column(children: [
      Icon(icon, color: KomnivoTheme.muted, size: 28),
      const SizedBox(height: 9),
      Text(title, textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
      const SizedBox(height: 5),
      Text(message, textAlign: TextAlign.center,
        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.45)),
    ]),
  );
}

class _ClubhouseError extends StatelessWidget {
  const _ClubhouseError({required this.message, required this.onRetry});
  final String message; final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline_rounded, color: KomnivoTheme.danger, size: 34),
      const SizedBox(height: 12),
      const Text('Could not load team details', style: TextStyle(fontWeight: FontWeight.w900)),
      const SizedBox(height: 6),
      Text(message, textAlign: TextAlign.center,
        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
      const SizedBox(height: 14),
      OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded),
        label: const Text('Try again')),
    ]),
  ));
}

String _clubRole(String role) {
  switch (role) {
    case 'owner': return 'Owner';
    case 'captain': return 'Captain';
    case 'substitute': return 'Substitute';
    default: return 'Player';
  }
}

String _formatClubNumber(int value) {
  final s = value.toString(); final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String _clubHuman(String value) => value.split('_').map((part) =>
  part.isEmpty ? part : part[0].toUpperCase() + part.substring(1)).join(' ');

String _clubDate(String? value) {
  if (value == null || value.isEmpty) return '';
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '';
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return date.day.toString() + ' ' + months[date.month - 1];
}
