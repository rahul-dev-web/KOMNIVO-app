import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

/// Batch 4 operations UI. Read paths use current records and RLS. Write
/// actions remain explicit drafts until the Batch 4 server/database contract
/// is implemented; the UI never reports a local draft as a saved action.
class CommunityOperationsScreen extends StatefulWidget {
  const CommunityOperationsScreen({
    super.key,
    required this.community,
    this.dataSource,
    this.onOpenChannelStudio,
  });

  final Map<String, dynamic> community;
  final CommunityOperationsDataSource? dataSource;
  final Future<void> Function()? onOpenChannelStudio;

  @override
  State<CommunityOperationsScreen> createState() =>
      _CommunityOperationsScreenState();
}

abstract class CommunityOperationsDataSource {
  Future<Set<String>> loadPermissions(String communityId);
  Future<CommunityDirectoryData> loadDirectory(String communityId);
  Future<CommunityIdentityData> loadIdentity(String communityId);
  Future<List<Map<String, dynamic>>> loadInvites(String communityId);
  Future<List<Map<String, dynamic>>> loadReports(String communityId);
  Future<List<Map<String, dynamic>>> loadChannelPolicies(String communityId);
  Future<List<Map<String, dynamic>>> loadAudit(String communityId);
}

class SupabaseCommunityOperationsDataSource
    implements CommunityOperationsDataSource {
  SupabaseCommunityOperationsDataSource({SupabaseClient? client})
      : _db = client ?? Supabase.instance.client;

  final SupabaseClient _db;

  Future<List<Map<String, dynamic>>> _optionalRows(
    Future<dynamic> request,
  ) async {
    try {
      final rows = await request;
      return rows is List
          ? List<Map<String, dynamic>>.from(rows)
          : <Map<String, dynamic>>[];
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  @override
  Future<Set<String>> loadPermissions(String communityId) async {
    const keys = [
      'community.manage_members',
      'community.manage_invites',
      'community.manage_settings',
      'community.audit.read',
    ];
    final granted = <String>{};
    for (final key in keys) {
      try {
        final value = await _db.rpc('has_permission', params: {
          'p_permission_key': key,
          'p_scope_type': 'community',
          'p_scope_id': communityId,
          'p_related_id': null,
          'p_resource_id': null,
        });
        if (value == true) granted.add(key);
      } catch (_) {
        // Permission lookup failures fail closed.
      }
    }
    return granted;
  }

  @override
  Future<CommunityDirectoryData> loadDirectory(String communityId) async {
    final base = List<Map<String, dynamic>>.from(
      await _db.from('community_members').select(
        'user_id,role,joined_at,muted_until,profiles(display_name,username,avatar_url,region,is_public)',
      ).eq('community_id', communityId).order('joined_at', ascending: false).limit(500),
    );
    if (base.isEmpty) return const CommunityDirectoryData(members: []);
    final ids = base.map((row) => row['user_id'].toString()).toSet().toList();

    final roleRows = await _optionalRows(
      _db.from('community_member_roles')
          .select('user_id,community_roles(name,preset_key,colour)')
          .eq('community_id', communityId).inFilter('user_id', ids),
    );
    final accounts = await _optionalRows(
      _db.from('game_accounts')
          .select('user_id,ownership_status,nickname,region')
          .inFilter('user_id', ids),
    );
    final captains = await _optionalRows(
      _db.from('team_members').select('user_id,role')
          .inFilter('user_id', ids).inFilter('role', ['owner', 'captain']),
    );
    final events = await _optionalRows(
      _db.from('events').select('id').eq('community_id', communityId),
    );
    final eventIds = events.map((row) => row['id'].toString()).toList();
    var participantIds = <String>{};
    var staffIds = <String>{};
    if (eventIds.isNotEmpty) {
      final registrations = await _optionalRows(
        _db.from('event_registrations').select('id').inFilter('event_id', eventIds),
      );
      final registrationIds =
          registrations.map((row) => row['id'].toString()).toList();
      if (registrationIds.isNotEmpty) {
        final players = await _optionalRows(
          _db.from('registration_players').select('user_id')
              .inFilter('registration_id', registrationIds),
        );
        participantIds = players.map((row) => row['user_id'].toString()).toSet();
      }
      final staff = await _optionalRows(
        _db.from('event_staff_assignments').select('user_id')
            .inFilter('event_id', eventIds),
      );
      staffIds = staff.map((row) => row['user_id'].toString()).toSet();
    }

    final rolesByUser = <String, List<Map<String, dynamic>>>{};
    for (final row in roleRows) {
      final role = row['community_roles'];
      if (role is! Map) continue;
      rolesByUser.putIfAbsent(row['user_id'].toString(), () => [])
          .add(Map<String, dynamic>.from(role));
    }
    final accountsByUser = <String, List<Map<String, dynamic>>>{};
    for (final row in accounts) {
      accountsByUser.putIfAbsent(row['user_id'].toString(), () => []).add(row);
    }
    final captainIds = captains.map((row) => row['user_id'].toString()).toSet();

    final enriched = base.map((row) {
      final userId = row['user_id'].toString();
      return <String, dynamic>{
        ...row,
        '_community_roles': rolesByUser[userId] ?? [],
        '_game_accounts': accountsByUser[userId] ?? [],
        '_is_team_captain': captainIds.contains(userId),
        '_is_event_participant': participantIds.contains(userId),
        '_is_event_staff': staffIds.contains(userId),
      };
    }).toList();
    return CommunityDirectoryData(members: enriched);
  }

  @override
  Future<CommunityIdentityData> loadIdentity(String communityId) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) {
      return const CommunityIdentityData(
        signedIn: false,
        member: false,
        membershipRole: null,
        ownershipStatus: 'not_linked',
      );
    }
    final membership = await _db.from('community_members').select('role')
        .eq('community_id', communityId).eq('user_id', userId).maybeSingle();
    final account = await _db.from('game_accounts').select('ownership_status')
        .eq('user_id', userId).order('updated_at', ascending: false)
        .limit(1).maybeSingle();
    return CommunityIdentityData(
      signedIn: true,
      member: membership != null,
      membershipRole: membership?['role']?.toString(),
      ownershipStatus: account?['ownership_status']?.toString() ?? 'not_linked',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> loadInvites(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('community_invites')
          .select('id,created_by,expires_at,max_uses,uses,created_at')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<List<Map<String, dynamic>>> loadReports(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('moderation_reports')
          .select('id,reporter_id,target_user_id,message_id,reason,details,status,assigned_to,created_at,resolved_at')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<List<Map<String, dynamic>>> loadChannelPolicies(String communityId) async {
    final channels = List<Map<String, dynamic>>.from(await _db.from('channels')
        .select('id,name,kind,archived_at').eq('community_id', communityId)
        .isFilter('archived_at', null).order('name'));
    if (channels.isEmpty) return [];
    final ids = channels.map((row) => row['id'].toString()).toList();
    final settings = await _optionalRows(
      _db.from('channel_settings')
          .select('channel_id,read_only,slow_mode_seconds,allow_attachments,allow_links,allow_everyone_mention,allow_role_mentions,allow_user_mentions')
          .inFilter('channel_id', ids),
    );
    final byId = {for (final row in settings) row['channel_id'].toString(): row};
    return channels.map((row) => <String, dynamic>{
      ...row,
      'settings': byId[row['id'].toString()] ?? <String, dynamic>{},
    }).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> loadAudit(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('audit_logs')
          .select('id,actor_id,entity_type,entity_id,action,reason,created_at')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(150));
}

class CommunityDirectoryData {
  const CommunityDirectoryData({required this.members});
  final List<Map<String, dynamic>> members;
}

class CommunityIdentityData {
  const CommunityIdentityData({
    required this.signedIn,
    required this.member,
    required this.membershipRole,
    required this.ownershipStatus,
  });
  final bool signedIn;
  final bool member;
  final String? membershipRole;
  final String ownershipStatus;
}

class _CommunityOperationsScreenState extends State<CommunityOperationsScreen> {
  late final CommunityOperationsDataSource _source =
      widget.dataSource ?? SupabaseCommunityOperationsDataSource();
  late Future<Set<String>> _permissions;

  String get _communityId => widget.community['id']?.toString() ?? '';
  String get _communityName => widget.community['name']?.toString() ?? 'Community';

  @override
  void initState() {
    super.initState();
    _permissions = _source.loadPermissions(_communityId);
  }

  void _retry() => setState(() => _permissions = _source.loadPermissions(_communityId));

  @override
  Widget build(BuildContext context) => FutureBuilder<Set<String>>(
    future: _permissions,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return Scaffold(
          appBar: AppBar(title: Text(_communityName)),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: Text(_communityName)),
          body: _LoadFailure(
            title: 'Community access could not be checked',
            details: snapshot.error.toString(),
            onRetry: _retry,
          ),
        );
      }
      final access = snapshot.data ?? <String>{};
      final sections = <_OperationsSection>[
        _OperationsSection('Members', Icons.groups_outlined, _MemberDirectoryTab(
          communityId: _communityId, source: _source,
        )),
        _OperationsSection('Onboarding', Icons.fact_check_outlined, _OnboardingTab(
          communityId: _communityId, source: _source,
          canConfigure: access.contains('community.manage_members'),
        )),
        if (access.contains('community.manage_invites'))
          _OperationsSection('Invites', Icons.link_outlined, _InvitesTab(
            community: widget.community, source: _source,
          )),
        if (access.contains('community.manage_members'))
          _OperationsSection('Moderation', Icons.shield_outlined, _ModerationTab(
            communityId: _communityId, source: _source,
          )),
        if (access.contains('community.manage_settings'))
          _OperationsSection('Safety', Icons.security_outlined, _SafetyTab(
            communityId: _communityId, source: _source,
            onOpenChannelStudio: widget.onOpenChannelStudio,
          )),
        if (access.contains('community.audit.read'))
          _OperationsSection('Audit', Icons.history_outlined, _AuditTab(
            communityId: _communityId, source: _source,
          )),
      ];
      return DefaultTabController(
        length: sections.length,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_communityName),
                const Text('MEMBERS & SAFETY CENTRE', style: TextStyle(
                  color: KomnivoTheme.muted, fontSize: 8, letterSpacing: 1.1,
                  fontWeight: FontWeight.w800,
                )),
              ],
            ),
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: sections.map((s) => Tab(
                icon: Icon(s.icon, size: 17), text: s.label, height: 56,
              )).toList(),
            ),
          ),
          body: Column(children: [
            const _WriteBoundaryNotice(),
            Expanded(child: TabBarView(
              children: sections.map((s) => s.child).toList(),
            )),
          ]),
        ),
      );
    },
  );
}

class _OperationsSection {
  const _OperationsSection(this.label, this.icon, this.child);
  final String label;
  final IconData icon;
  final Widget child;
}

class _WriteBoundaryNotice extends StatelessWidget {
  const _WriteBoundaryNotice();
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    color: KomnivoTheme.surfaceRaised,
    child: const Row(children: [
      Icon(Icons.lock_outline, color: KomnivoTheme.cyan, size: 14),
      SizedBox(width: 8),
      Expanded(child: Text(
        'UI / UX implementation · server-side changes are not submitted from this screen',
        style: TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.3),
      )),
    ]),
  );
}

class _MemberDirectoryTab extends StatefulWidget {
  const _MemberDirectoryTab({required this.communityId, required this.source});
  final String communityId;
  final CommunityOperationsDataSource source;
  @override
  State<_MemberDirectoryTab> createState() => _MemberDirectoryTabState();
}

class _MemberDirectoryTabState extends State<_MemberDirectoryTab> {
  late Future<CommunityDirectoryData> _future;
  final _search = TextEditingController();
  String _filter = 'All';

  static const _filters = [
    'All', 'Staff', 'Verified players', 'Team captains',
    'Event participants', 'Restricted', 'Recent joins',
  ];

  @override
  void initState() {
    super.initState();
    _future = widget.source.loadDirectory(widget.communityId);
    _search.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() => setState(() => _future = widget.source.loadDirectory(widget.communityId));

  String _name(Map<String, dynamic> member) {
    final profile = member['profiles'] is Map
        ? Map<String, dynamic>.from(member['profiles'] as Map)
        : <String, dynamic>{};
    return (profile['display_name'] ?? profile['username'] ?? 'KOMNIVO member').toString();
  }

  bool _matches(Map<String, dynamic> member) {
    final profile = member['profiles'] is Map
        ? Map<String, dynamic>.from(member['profiles'] as Map)
        : <String, dynamic>{};
    final search = _search.text.trim().toLowerCase();
    final name = (profile['display_name'] ?? profile['username'] ?? '').toString().toLowerCase();
    final roles = (member['_community_roles'] as List? ?? const [])
        .whereType<Map>().map((r) => (r['name'] ?? '').toString().toLowerCase()).toList();
    if (search.isNotEmpty && !name.contains(search) && !roles.any((r) => r.contains(search))) {
      return false;
    }
    final base = member['role']?.toString().toLowerCase() ?? '';
    final staff = const {'owner', 'admin', 'moderator', 'organiser'}.contains(base) ||
        roles.any((r) => const {'owner', 'admin', 'moderator', 'organiser', 'community manager'}.contains(r)) ||
        member['_is_event_staff'] == true;
    final accounts = (member['_game_accounts'] as List? ?? const []).whereType<Map>();
    final verified = accounts.any((a) => a['ownership_status'] == 'verified');
    final mute = DateTime.tryParse(member['muted_until']?.toString() ?? '');
    final restricted = mute != null && mute.isAfter(DateTime.now());
    final joined = DateTime.tryParse(member['joined_at']?.toString() ?? '');
    final recent = joined != null && joined.isAfter(DateTime.now().subtract(const Duration(days: 7)));
    switch (_filter) {
      case 'Staff': return staff;
      case 'Verified players': return verified;
      case 'Team captains': return member['_is_team_captain'] == true;
      case 'Event participants': return member['_is_event_participant'] == true;
      case 'Restricted': return restricted;
      case 'Recent joins': return recent;
      default: return true;
    }
  }

  Future<void> _openMember(Map<String, dynamic> member) async {
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, useSafeArea: true,
      backgroundColor: KomnivoTheme.surface,
      builder: (context) => _MemberDetailsSheet(member: member, name: _name(member)),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CommunityDirectoryData>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _LoadFailure(
          title: 'Member directory could not be loaded',
          details: snapshot.error.toString(),
          onRetry: _refresh,
        );
      }
      final members = snapshot.data?.members ?? const <Map<String, dynamic>>[];
      final filtered = members.where(_matches).toList();
      return RefreshIndicator(
        onRefresh: () async { final next = widget.source.loadDirectory(widget.communityId); setState(() => _future = next); await next; },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
          children: [
            Row(children: [
              const Expanded(child: _PageHeading(
                title: 'Member directory',
                subtitle: 'Find people by community role, verified game identity and activity scope.',
              )),
              _CountPill(label: members.length.toString() + ' members', icon: Icons.people_outline),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search members or community roles',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.text.isEmpty ? null : IconButton(
                  tooltip: 'Clear search', onPressed: _search.clear,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: _filters.map((filter) => Padding(
                padding: const EdgeInsets.only(right: 7),
                child: ChoiceChip(
                  label: Text(filter), selected: _filter == filter,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
              )).toList()),
            ),
            const SizedBox(height: 9),
            Text(filtered.length.toString() + ' results',
              style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            if (members.isEmpty)
              const _EmptyState(
                icon: Icons.group_outlined, title: 'No members to display',
                body: 'No member records are visible for this community and account.',
              )
            else if (filtered.isEmpty)
              _EmptyState(
                icon: Icons.filter_alt_off_outlined, title: 'No matching members',
                body: 'Try another filter or clear your search.',
                action: TextButton(onPressed: () { _search.clear(); setState(() => _filter = 'All'); }, child: const Text('Clear filters')),
              )
            else
              ...filtered.map((member) => _MemberCard(
                member: member, name: _name(member), onTap: () => _openMember(member),
              )),
            const SizedBox(height: 8),
            const _PrivacyNote(
              text: 'Member visibility follows community access and profile privacy. Free Fire UID values and private profile fields are not exposed in this directory.',
            ),
          ],
        ),
      );
    },
  );
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.name, required this.onTap});
  final Map<String, dynamic> member;
  final String name;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final profile = member['profiles'] is Map ? Map<String, dynamic>.from(member['profiles'] as Map) : <String, dynamic>{};
    final base = member['role']?.toString() ?? 'member';
    final roles = (member['_community_roles'] as List? ?? const []).whereType<Map>()
        .map((row) => row['name']?.toString() ?? '').where((r) => r.isNotEmpty).toList();
    final accounts = (member['_game_accounts'] as List? ?? const []).whereType<Map>();
    final verified = accounts.any((row) => row['ownership_status'] == 'verified');
    final region = profile['is_public'] == true ? profile['region']?.toString() : null;
    final muted = DateTime.tryParse(member['muted_until']?.toString() ?? '');
    final restricted = muted != null && muted.isAfter(DateTime.now());
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(15), onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(children: [
            CircleAvatar(
              radius: 21, backgroundColor: KomnivoTheme.surfaceRaised,
              backgroundImage: profile['avatar_url']?.toString().isNotEmpty == true
                  ? NetworkImage(profile['avatar_url'].toString()) : null,
              child: profile['avatar_url']?.toString().isNotEmpty == true
                  ? null : Text(name.isEmpty ? '?' : name[0].toUpperCase()),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              const SizedBox(height: 3),
              Text(
                '@' + (profile['username']?.toString() ?? 'member') +
                    (region != null && region.isNotEmpty ? ' · ' + region : ''),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 5, runSpacing: 4, children: [
                _StatusTag(label: base.toUpperCase()),
                ...roles.take(2).map((role) => _StatusTag(label: role.toUpperCase())),
                if (verified) const _StatusTag(label: 'UID VERIFIED', tone: _TagTone.success),
                if (member['_is_team_captain'] == true) const _StatusTag(label: 'TEAM CAPTAIN'),
                if (member['_is_event_participant'] == true) const _StatusTag(label: 'EVENT PLAYER'),
                if (restricted) const _StatusTag(label: 'RESTRICTED', tone: _TagTone.danger),
              ]),
            ])),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded, color: KomnivoTheme.muted),
          ]),
        ),
      ),
    );
  }
}

class _MemberDetailsSheet extends StatelessWidget {
  const _MemberDetailsSheet({required this.member, required this.name});
  final Map<String, dynamic> member;
  final String name;
  @override
  Widget build(BuildContext context) {
    final profile = member['profiles'] is Map ? Map<String, dynamic>.from(member['profiles'] as Map) : <String, dynamic>{};
    final roles = (member['_community_roles'] as List? ?? const []).whereType<Map>()
        .map((r) => r['name']?.toString() ?? '').where((r) => r.isNotEmpty).toList();
    final accounts = (member['_game_accounts'] as List? ?? const []).whereType<Map>();
    final verified = accounts.any((r) => r['ownership_status'] == 'verified');
    final joined = DateTime.tryParse(member['joined_at']?.toString() ?? '');
    final muted = DateTime.tryParse(member['muted_until']?.toString() ?? '');
    final restricted = muted != null && muted.isAfter(DateTime.now());
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 12, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
          Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: KomnivoTheme.line, borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 16),
          Row(children: [
            CircleAvatar(radius: 25,
              backgroundImage: profile['avatar_url']?.toString().isNotEmpty == true ? NetworkImage(profile['avatar_url'].toString()) : null,
              child: profile['avatar_url']?.toString().isNotEmpty == true ? null : Text(name.isEmpty ? '?' : name[0].toUpperCase())),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              Text('@' + (profile['username']?.toString() ?? 'member'),
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
            ])),
            if (verified) const _StatusTag(label: 'VERIFIED', tone: _TagTone.success),
          ]),
          const SizedBox(height: 16),
          _DetailRow(label: 'Community role', value: member['role']?.toString() ?? 'Member'),
          _DetailRow(label: 'Additional roles', value: roles.isEmpty ? 'None assigned' : roles.join(', ')),
          _DetailRow(label: 'Member since', value: joined == null ? 'Unavailable' : _dateLabel(joined)),
          _DetailRow(label: 'Region', value: profile['is_public'] == true ? (profile['region']?.toString().isNotEmpty == true ? profile['region'].toString() : 'Not provided') : 'Hidden by profile privacy'),
          _DetailRow(label: 'Team role', value: member['_is_team_captain'] == true ? 'Captain / Owner' : 'No captain assignment'),
          _DetailRow(label: 'Event participation', value: member['_is_event_participant'] == true ? 'Registered in a community event' : 'No current registration found'),
          if (restricted) _DetailRow(label: 'Restriction', value: 'Muted until ' + _dateLabel(muted), danger: true),
          const SizedBox(height: 12),
          const _PrivacyNote(text: 'Moderation controls are available only after the server confirms the acting moderator’s scope and authority.'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final report = await showDialog<Map<String, String>>(
                context: context, builder: (_) => _ReportDraftDialog(memberName: name),
              );
              if (report != null && context.mounted) {
                showMessage(context, 'Report draft prepared. Nothing has been submitted.');
              }
            },
            icon: const Icon(Icons.flag_outlined, size: 16), label: const Text('Prepare report'),
          ),
        ],
      )),
    );
  }
}

class _ReportDraftDialog extends StatefulWidget {
  const _ReportDraftDialog({required this.memberName});
  final String memberName;
  @override
  State<_ReportDraftDialog> createState() => _ReportDraftDialogState();
}

class _ReportDraftDialogState extends State<_ReportDraftDialog> {
  final _details = TextEditingController();
  String _reason = 'Harassment or abuse';
  @override
  void dispose() { _details.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Report member'),
    content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Align(alignment: Alignment.centerLeft, child: Text('Report about ' + widget.memberName,
        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10))),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        value: _reason, decoration: const InputDecoration(labelText: 'Reason'),
        items: const ['Harassment or abuse', 'Spam or scam', 'Impersonation', 'Cheating or unfair play', 'Unsafe content', 'Other']
            .map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
        onChanged: (value) => setState(() => _reason = value ?? _reason),
      ),
      const SizedBox(height: 10),
      TextField(controller: _details, onChanged: (_) => setState(() {}), minLines: 3, maxLines: 5, maxLength: 1000,
        decoration: const InputDecoration(labelText: 'What happened?', hintText: 'Add relevant context without unrelated personal data.')),
      const _WritePendingNote(text: 'The report submission endpoint will be connected with the Batch 4 backend. This form does not send a report yet.'),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: _details.text.trim().length < 8 ? null : () => Navigator.pop(context, {'reason': _reason, 'details': _details.text.trim()}),
        child: const Text('Prepare report'),
      ),
    ],
  );
}

class _OnboardingTab extends StatefulWidget {
  const _OnboardingTab({required this.communityId, required this.source, required this.canConfigure});
  final String communityId;
  final CommunityOperationsDataSource source;
  final bool canConfigure;
  @override
  State<_OnboardingTab> createState() => _OnboardingTabState();
}

class _OnboardingTabState extends State<_OnboardingTab> {
  late Future<CommunityIdentityData> _identity;
  final _region = TextEditingController();
  String? _gameMode;
  final Set<String> _interests = {};
  final Set<String> _activities = {};
  bool _draftReady = false;
  final Map<String, bool> _enabled = {
    'Game mode': true, 'Player interests': true, 'Region': true, 'Preferred activities': true,
  };
  final Map<String, bool> _required = {
    'Game mode': true, 'Player interests': false, 'Region': false, 'Preferred activities': false,
  };
  static const _interestOptions = ['Rank push', 'Competitive scrims', 'Casual matches', 'Content creation', 'Coaching', 'Team building'];
  static const _activityOptions = ['Find a team', 'Join tournaments', 'Play scrims', 'Learn strategies', 'Join voice sessions', 'Help organise events'];

  @override
  void initState() { super.initState(); _identity = widget.source.loadIdentity(widget.communityId); }
  @override
  void dispose() { _region.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FutureBuilder<CommunityIdentityData>(
    future: _identity,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return _LoadFailure(
        title: 'Account and membership states could not be loaded',
        details: snapshot.error.toString(),
        onRetry: () => setState(() => _identity = widget.source.loadIdentity(widget.communityId)),
      );
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          const _PageHeading(title: 'Member onboarding', subtitle: 'Collect player context without turning answers into roles or permissions.'),
          const SizedBox(height: 12),
          _IdentityStateCard(identity: snapshot.data!),
          const SizedBox(height: 14),
          if (widget.canConfigure) _builder() else _questionnaire(),
        ],
      );
    },
  );

  Widget _builder() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const _PageHeading(title: 'Onboarding questions', subtitle: 'Choose what new members answer. Answers can guide channel recommendations only.'),
    const SizedBox(height: 8),
    ..._enabled.keys.map((question) => Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Column(children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero, title: Text(question, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
            subtitle: Text(_description(question), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
            value: _enabled[question]!,
            onChanged: (value) => setState(() { _enabled[question] = value; if (!value) _required[question] = false; }),
          ),
          if (_enabled[question]!)
            Align(alignment: Alignment.centerLeft, child: FilterChip(
              label: const Text('Required question'), selected: _required[question]!,
              onSelected: (value) => setState(() => _required[question] = value),
            )),
        ]),
      ),
    )),
    const _SafetyBoundaryCard(
      title: 'Answers never grant authority',
      body: 'Game mode, interests, region and preferred activities may recommend channels. Owner, Admin, Moderator, Organiser and event staff access remain explicit assignments.',
    ),
    const SizedBox(height: 10),
    FilledButton.icon(onPressed: () => setState(() => _draftReady = true),
      icon: const Icon(Icons.tune_rounded), label: const Text('Review onboarding configuration')),
    if (_draftReady) const _WritePendingNote(text: 'Configuration is ready for review. It has not been saved; onboarding schema and server validation are part of the Batch 4 backend.'),
  ]);

  String _description(String question) => switch (question) {
    'Game mode' => 'Battle Royale, Clash Squad or another supported mode.',
    'Player interests' => 'Competitive, casual, coaching and creator interests.',
    'Region' => 'A broad region for discovery and matchmaking.',
    _ => 'Activities the member wants to join inside this community.',
  };

  Widget _questionnaire() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const _PageHeading(title: 'Your player preferences', subtitle: 'Answers help sort channels. They do not verify your UID or change your membership role.'),
    const SizedBox(height: 10),
    if (_enabled['Game mode'] == true)
      DropdownButtonFormField<String>(
        value: _gameMode, decoration: const InputDecoration(labelText: 'Game mode'),
        items: const ['Battle Royale', 'Clash Squad', 'Both', 'Not decided']
            .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _gameMode = v),
      ),
    if (_enabled['Region'] == true) ...[
      const SizedBox(height: 10),
      TextField(controller: _region, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Region', hintText: 'e.g. Central India')),
    ],
    if (_enabled['Player interests'] == true) ...[
      const SizedBox(height: 14),
      const Text('Player interests', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
      const SizedBox(height: 6),
      Wrap(spacing: 7, runSpacing: 6, children: _interestOptions.map((v) => FilterChip(
        label: Text(v), selected: _interests.contains(v),
        onSelected: (yes) => setState(() { if (yes) { _interests.add(v); } else { _interests.remove(v); } }),
      )).toList()),
    ],
    if (_enabled['Preferred activities'] == true) ...[
      const SizedBox(height: 14),
      const Text('Preferred activities', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
      const SizedBox(height: 6),
      Wrap(spacing: 7, runSpacing: 6, children: _activityOptions.map((v) => FilterChip(
        label: Text(v), selected: _activities.contains(v),
        onSelected: (yes) => setState(() { if (yes) { _activities.add(v); } else { _activities.remove(v); } }),
      )).toList()),
    ],
    const SizedBox(height: 14),
    const _SafetyBoundaryCard(
      title: 'Identity and membership are separate',
      body: 'KOMNIVO sign-in, Free Fire UID ownership verification and community membership acceptance are three independent states.',
    ),
    const SizedBox(height: 10),
    FilledButton.icon(
      onPressed: _canPrepareAnswers ? () => setState(() => _draftReady = true) : null,
      icon: const Icon(Icons.check_circle_outline), label: const Text('Review my answers'),
    ),
    if (_draftReady) const _WritePendingNote(text: 'Your answers are ready for review but have not been submitted. The onboarding answer endpoint will be connected with the Batch 4 backend.'),
  ]);

  bool get _canPrepareAnswers {
    if (_enabled['Game mode'] == true && _required['Game mode'] == true && _gameMode == null) return false;
    if (_enabled['Region'] == true && _required['Region'] == true && _region.text.trim().isEmpty) return false;
    if (_enabled['Player interests'] == true && _required['Player interests'] == true && _interests.isEmpty) return false;
    if (_enabled['Preferred activities'] == true && _required['Preferred activities'] == true && _activities.isEmpty) return false;
    return true;
  }
}

class _IdentityStateCard extends StatelessWidget {
  const _IdentityStateCard({required this.identity});
  final CommunityIdentityData identity;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ACCOUNT & MEMBERSHIP STATES', style: TextStyle(
          color: KomnivoTheme.muted, fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w900,
        )),
        const SizedBox(height: 10),
        _IdentityStateRow(title: 'Platform sign-in',
          detail: identity.signedIn ? 'KOMNIVO account session active' : 'Sign-in required',
          complete: identity.signedIn),
        const Divider(height: 17),
        _IdentityStateRow(title: 'Free Fire UID ownership',
          detail: switch (identity.ownershipStatus) {
            'verified' => 'UID ownership verified',
            'proof_pending' => 'Verification proof pending',
            'verifying' => 'Ownership check in progress',
            'locked' => 'Verification attempts locked',
            'not_linked' => 'No verified game account linked',
            _ => 'Status: ' + identity.ownershipStatus,
          },
          complete: identity.ownershipStatus == 'verified',
          pending: identity.ownershipStatus != 'verified' && identity.ownershipStatus != 'not_linked'),
        const Divider(height: 17),
        _IdentityStateRow(title: 'Community membership',
          detail: identity.member ? 'Accepted · ' + (identity.membershipRole ?? 'Member') : 'Not accepted in this community',
          complete: identity.member),
        const SizedBox(height: 8),
        const _PrivacyNote(text: 'UID verification does not automatically accept membership or grant a community role.'),
      ]),
    ),
  );
}

class _IdentityStateRow extends StatelessWidget {
  const _IdentityStateRow({required this.title, required this.detail, required this.complete, this.pending = false});
  final String title;
  final String detail;
  final bool complete;
  final bool pending;
  @override
  Widget build(BuildContext context) {
    final color = complete ? const Color(0xFF54C9A5) : pending ? const Color(0xFFFFC66D) : KomnivoTheme.muted;
    return Row(children: [
      Icon(complete ? Icons.check_circle : pending ? Icons.hourglass_top_rounded : Icons.radio_button_unchecked, color: color, size: 19),
      const SizedBox(width: 9),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
        Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
      ])),
      _StatusTag(label: complete ? 'COMPLETE' : pending ? 'PENDING' : 'SEPARATE',
        tone: complete ? _TagTone.success : pending ? _TagTone.warning : _TagTone.neutral),
    ]);
  }
}

class _InvitesTab extends StatefulWidget {
  const _InvitesTab({required this.community, required this.source});
  final Map<String, dynamic> community;
  final CommunityOperationsDataSource source;
  @override
  State<_InvitesTab> createState() => _InvitesTabState();
}

class _InvitesTabState extends State<_InvitesTab> {
  late Future<List<Map<String, dynamic>>> _future;
  Map<String, dynamic>? _draft;
  @override
  void initState() { super.initState(); _future = widget.source.loadInvites(widget.community['id'].toString()); }
  void _refresh() => setState(() => _future = widget.source.loadInvites(widget.community['id'].toString()));

  Future<void> _createDraft() async {
    final draft = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _InviteSettingsDialog());
    if (draft != null && mounted) setState(() => _draft = draft);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return _LoadFailure(title: 'Invites could not be loaded', details: snapshot.error.toString(), onRetry: _refresh);
      final invites = snapshot.data ?? const <Map<String, dynamic>>[];
      return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
        Row(children: [
          const Expanded(child: _PageHeading(title: 'Invite controls', subtitle: 'Manage expiry, usage limits, invite-only access and join approval.')),
          FilledButton.icon(onPressed: _createDraft, icon: const Icon(Icons.add_link_rounded, size: 17), label: const Text('Create')),
        ]),
        const SizedBox(height: 12),
        _InvitePolicyCard(visibility: widget.community['visibility']?.toString() ?? 'public'),
        if (_draft != null) ...[
          const SizedBox(height: 9),
          _InviteDraftCard(draft: _draft!, onDiscard: () => setState(() => _draft = null)),
        ],
        const SizedBox(height: 16),
        const Text('Existing invite links', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
        const SizedBox(height: 7),
        if (invites.isEmpty) const _EmptyState(
          icon: Icons.link_off_outlined, title: 'No invite records',
          body: 'There are no invite records visible for this community. Link issuance and revoke operations will be connected with the Batch 4 backend.',
        ) else ...invites.map((row) => _InviteCard(invite: row)),
        const SizedBox(height: 18),
        const _SectionHeader(title: 'Join approval queue', subtitle: 'Applications are reviewed separately from invite redemption.'),
        const _PendingFeatureCard(
          title: 'Application approvals',
          detail: 'The approval queue UI is defined. A community join-request record and approve / reject operation are not available in the current schema; no application is fabricated here.',
          icon: Icons.fact_check_outlined,
        ),
      ]);
    },
  );
}

class _InviteSettingsDialog extends StatefulWidget {
  const _InviteSettingsDialog();
  @override
  State<_InviteSettingsDialog> createState() => _InviteSettingsDialogState();
}

class _InviteSettingsDialogState extends State<_InviteSettingsDialog> {
  String _expiry = '7 days';
  String _limit = '25 uses';
  bool _approval = false;
  bool _singleUse = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invite settings'),
    content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(
        value: _expiry, decoration: const InputDecoration(labelText: 'Link expiry'),
        items: const ['1 day', '7 days', '30 days', 'Never'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _expiry = v ?? _expiry),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        value: _limit, decoration: const InputDecoration(labelText: 'Usage limit'),
        items: const ['1 use', '5 uses', '25 uses', '100 uses', 'Unlimited'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _limit = v ?? _limit),
      ),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Require join approval'),
        subtitle: const Text('New applicants wait for an authorised moderator.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        value: _approval, onChanged: (v) => setState(() => _approval = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Single-use invite'),
        value: _singleUse, onChanged: (v) => setState(() { _singleUse = v; if (v) _limit = '1 use'; })),
      const _WritePendingNote(text: 'These settings configure the invite UX only. A server-issued secret link is not generated in this UI pass.'),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, {
        'expiry': _expiry, 'limit': _limit, 'approval': _approval, 'single_use': _singleUse,
      }), child: const Text('Review settings')),
    ],
  );
}

class _InvitePolicyCard extends StatelessWidget {
  const _InvitePolicyCard({required this.visibility});
  final String visibility;
  @override
  Widget build(BuildContext context) {
    final inviteOnly = visibility == 'private';
    return Card(child: Padding(
      padding: const EdgeInsets.all(13),
      child: Row(children: [
        Icon(inviteOnly ? Icons.lock_outline : Icons.public_outlined, color: KomnivoTheme.cyan),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(inviteOnly ? 'Invite-only community' : 'Public community', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          Text(inviteOnly ? 'Membership is restricted by current community visibility.' : 'Public discovery is enabled; invite links may still apply limits.',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        ])),
        _StatusTag(label: inviteOnly ? 'PRIVATE' : 'PUBLIC', tone: inviteOnly ? _TagTone.warning : _TagTone.success),
      ]),
    ));
  }
}

class _InviteDraftCard extends StatelessWidget {
  const _InviteDraftCard({required this.draft, required this.onDiscard});
  final Map<String, dynamic> draft;
  final VoidCallback onDiscard;
  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.edit_note_rounded, color: KomnivoTheme.cyan), SizedBox(width: 7),
        Expanded(child: Text('Invite configuration draft', style: TextStyle(fontWeight: FontWeight.w900))),
        _StatusTag(label: 'UNSAVED', tone: _TagTone.warning),
      ]),
      const SizedBox(height: 8),
      _DetailRow(label: 'Expiry', value: draft['expiry'].toString()),
      _DetailRow(label: 'Usage', value: draft['limit'].toString()),
      _DetailRow(label: 'Approval', value: draft['approval'] == true ? 'Required' : 'Not required'),
      _DetailRow(label: 'Single use', value: draft['single_use'] == true ? 'Yes' : 'No'),
      const _WritePendingNote(text: 'The invite is not issued. No token or shareable URL exists for this draft.'),
      Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onDiscard, child: const Text('Discard draft'))),
    ]),
  ));
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.invite});
  final Map<String, dynamic> invite;
  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(invite['created_at']?.toString() ?? '');
    final expiry = DateTime.tryParse(invite['expires_at']?.toString() ?? '');
    final uses = (invite['uses'] as num?)?.toInt() ?? 0;
    final maxUses = (invite['max_uses'] as num?)?.toInt();
    final expired = expiry != null && expiry.isBefore(DateTime.now());
    final exhausted = maxUses != null && uses >= maxUses;
    final status = expired ? 'EXPIRED' : exhausted ? 'USED UP' : 'ACTIVE';
    return Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.link_rounded, color: KomnivoTheme.cyan), const SizedBox(width: 8),
          const Expanded(child: Text('Community invite', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11))),
          _StatusTag(label: status, tone: expired || exhausted ? _TagTone.warning : _TagTone.success),
        ]),
        const SizedBox(height: 8),
        _DetailRow(label: 'Usage', value: maxUses == null ? '$uses · unlimited' : '$uses / $maxUses'),
        _DetailRow(label: 'Created', value: created == null ? 'Unavailable' : _dateLabel(created)),
        _DetailRow(label: 'Expires', value: expiry == null ? 'Never' : _dateLabel(expiry)),
        const _PrivacyNote(text: 'Invite secrets are not displayed from their stored hash. Revoke and rotation will use a privileged server operation.'),
      ]),
    ));
  }
}

class _ModerationTab extends StatefulWidget {
  const _ModerationTab({required this.communityId, required this.source});
  final String communityId;
  final CommunityOperationsDataSource source;
  @override
  State<_ModerationTab> createState() => _ModerationTabState();
}

class _ModerationTabState extends State<_ModerationTab> {
  late Future<List<Map<String, dynamic>>> _future;
  String _view = 'Open';
  Map<String, dynamic>? _draft;
  @override
  void initState() { super.initState(); _future = widget.source.loadReports(widget.communityId); }
  void _refresh() => setState(() => _future = widget.source.loadReports(widget.communityId));

  Future<void> _prepareAction({String? memberName}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context, builder: (_) => _ModerationActionDialog(memberName: memberName),
    );
    if (result != null && mounted) setState(() => _draft = result);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return _LoadFailure(title: 'Moderation queue could not be loaded', details: snapshot.error.toString(), onRetry: _refresh);
      final reports = snapshot.data ?? const <Map<String, dynamic>>[];
      final open = reports.where((r) => !const {'resolved', 'dismissed'}.contains((r['status'] ?? '').toString().toLowerCase())).toList();
      final resolved = reports.where((r) => const {'resolved', 'dismissed'}.contains((r['status'] ?? '').toString().toLowerCase())).toList();
      final shown = _view == 'Open' ? open : _view == 'Resolved' ? resolved : const <Map<String, dynamic>>[];
      return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
        Row(children: [
          const Expanded(child: _PageHeading(title: 'Moderation centre', subtitle: 'Review reports and prepare scoped, reasoned actions.')),
          FilledButton.icon(onPressed: _prepareAction, icon: const Icon(Icons.gavel_outlined, size: 16), label: const Text('New action')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 7, children: [
          ChoiceChip(label: Text('Open (' + open.length.toString() + ')'), selected: _view == 'Open', onSelected: (_) => setState(() => _view = 'Open')),
          ChoiceChip(label: Text('Resolved (' + resolved.length.toString() + ')'), selected: _view == 'Resolved', onSelected: (_) => setState(() => _view = 'Resolved')),
          ChoiceChip(label: const Text('Appeals'), selected: _view == 'Appeals', onSelected: (_) => setState(() => _view = 'Appeals')),
        ]),
        const SizedBox(height: 10),
        if (_draft != null) ...[
          _ModerationDraftCard(draft: _draft!, onDiscard: () => setState(() => _draft = null)),
          const SizedBox(height: 10),
        ],
        if (_view == 'Appeals')
          const _PendingFeatureCard(
            title: 'Appeal workflow',
            detail: 'Appeal submission, reviewer assignment, evidence and decision history need the Batch 4 appeal endpoint and persistence model. No placeholder appeals are shown as real cases.',
            icon: Icons.balance_outlined,
          )
        else if (shown.isEmpty)
          _EmptyState(
            icon: _view == 'Open' ? Icons.inbox_outlined : Icons.task_alt_outlined,
            title: _view == 'Open' ? 'No open reports' : 'No resolved reports',
            body: reports.isEmpty ? 'No report records are visible for this community.' : 'There are no reports in this view.',
          )
        else
          ...shown.map((report) => _ModerationReportCard(
            report: report, onReview: () => _prepareAction(memberName: report['target_user_id'] == null ? null : 'reported member'),
          )),
        const SizedBox(height: 14),
        const _SafetyBoundaryCard(
          title: 'Permission and scope checks',
          body: 'Warn, delete, timeout, mute, channel restriction, kick, ban and unban require server-side authority checks on every operation. This UI does not perform or simulate those writes.',
        ),
      ]);
    },
  );
}

class _ModerationReportCard extends StatelessWidget {
  const _ModerationReportCard({required this.report, required this.onReview});
  final Map<String, dynamic> report;
  final VoidCallback onReview;
  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(report['created_at']?.toString() ?? '');
    return Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.flag_outlined, color: KomnivoTheme.danger), const SizedBox(width: 8),
          Expanded(child: Text(report['reason']?.toString() ?? 'Unspecified report',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
          _StatusTag(label: (report['status'] ?? 'open').toString().toUpperCase()),
        ]),
        const SizedBox(height: 6),
        Text(report['details']?.toString() ?? '', maxLines: 4, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4)),
        const SizedBox(height: 7),
        Text('Report ' + report['id'].toString().substring(0, 8) + ' · ' +
          (created == null ? 'Time unavailable' : _dateLabel(created)),
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        Align(alignment: Alignment.centerRight, child: OutlinedButton.icon(
          onPressed: onReview, icon: const Icon(Icons.fact_check_outlined, size: 15), label: const Text('Prepare review'),
        )),
      ]),
    ));
  }
}

class _ModerationActionDialog extends StatefulWidget {
  const _ModerationActionDialog({this.memberName});
  final String? memberName;
  @override
  State<_ModerationActionDialog> createState() => _ModerationActionDialogState();
}

class _ModerationActionDialogState extends State<_ModerationActionDialog> {
  final _reason = TextEditingController();
  String _action = 'Warn';
  String _scope = 'Community';
  String _duration = '24 hours';
  String _channel = '';
  static const _actions = ['Warn', 'Delete message', 'Timeout', 'Mute', 'Channel restriction', 'Kick', 'Ban', 'Unban'];
  bool get _needsDuration => const {'Timeout', 'Mute', 'Ban'}.contains(_action);
  bool get _needsChannel => _action == 'Channel restriction';
  @override
  void dispose() { _reason.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Moderation action'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (widget.memberName != null) Align(alignment: Alignment.centerLeft, child: Text('Target: ' + widget.memberName!, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10))),
      DropdownButtonFormField<String>(
        value: _action, decoration: const InputDecoration(labelText: 'Action'),
        items: _actions.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _action = v ?? _action),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        value: _scope, decoration: const InputDecoration(labelText: 'Scope'),
        items: const ['Community', 'Selected channel', 'Specific message'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _scope = v ?? _scope),
      ),
      if (_needsChannel) ...[
        const SizedBox(height: 10),
        TextField(onChanged: (v) => _channel = v, decoration: const InputDecoration(labelText: 'Channel target', hintText: 'Select a channel in the connected action flow')),
      ],
      if (_needsDuration) ...[
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _duration, decoration: const InputDecoration(labelText: 'Duration'),
          items: const ['1 hour', '6 hours', '24 hours', '3 days', '7 days', 'Permanent'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: (v) => setState(() => _duration = v ?? _duration),
        ),
      ],
      const SizedBox(height: 10),
      TextField(controller: _reason, onChanged: (_) => setState(() {}), minLines: 3, maxLines: 5, maxLength: 600,
        decoration: const InputDecoration(labelText: 'Reason (required)', hintText: 'Record the rule or evidence that supports this action.')),
      const _WritePendingNote(text: 'This is an action review draft. It does not warn, remove, mute, restrict or ban anyone until the scoped server operation is connected.'),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: _reason.text.trim().length < 8 || (_needsChannel && _channel.trim().isEmpty) ? null :
          () => Navigator.pop(context, {
            'action': _action, 'scope': _scope, 'duration': _needsDuration ? _duration : null,
            'channel': _needsChannel ? _channel.trim() : null, 'reason': _reason.text.trim(),
          }),
        child: const Text('Prepare action'),
      ),
    ],
  );
}

class _ModerationDraftCard extends StatelessWidget {
  const _ModerationDraftCard({required this.draft, required this.onDiscard});
  final Map<String, dynamic> draft;
  final VoidCallback onDiscard;
  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.pending_actions, color: KomnivoTheme.cyan), SizedBox(width: 7),
        Expanded(child: Text('Action ready for backend review', style: TextStyle(fontWeight: FontWeight.w900))),
        _StatusTag(label: 'NOT SENT', tone: _TagTone.warning),
      ]),
      const SizedBox(height: 8),
      _DetailRow(label: 'Action', value: draft['action'].toString()),
      _DetailRow(label: 'Scope', value: draft['scope'].toString()),
      if (draft['duration'] != null) _DetailRow(label: 'Duration', value: draft['duration'].toString()),
      _DetailRow(label: 'Reason', value: draft['reason'].toString()),
      Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onDiscard, child: const Text('Discard draft'))),
    ]),
  ));
}

class _SafetyTab extends StatefulWidget {
  const _SafetyTab({required this.communityId, required this.source, this.onOpenChannelStudio});
  final String communityId;
  final CommunityOperationsDataSource source;
  final Future<void> Function()? onOpenChannelStudio;
  @override
  State<_SafetyTab> createState() => _SafetyTabState();
}

class _SafetyTabState extends State<_SafetyTab> {
  late Future<List<Map<String, dynamic>>> _future;
  final _messageRate = TextEditingController();
  final _mentionRate = TextEditingController();
  String _duration = '30 minutes';
  String _scope = 'All text channels';
  bool _pauseInvites = true;
  bool _restrictLinks = true;
  bool _lockdown = false;
  bool _draftReady = false;
  @override
  void initState() { super.initState(); _future = widget.source.loadChannelPolicies(widget.communityId); }
  @override
  void dispose() { _messageRate.dispose(); _mentionRate.dispose(); super.dispose(); }
  void _refresh() => setState(() => _future = widget.source.loadChannelPolicies(widget.communityId));

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return _LoadFailure(title: 'Channel safety settings could not be loaded', details: snapshot.error.toString(), onRetry: _refresh);
      final channels = snapshot.data ?? const <Map<String, dynamic>>[];
      return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
        const _PageHeading(title: 'Community safety', subtitle: 'Deterministic anti-spam controls and temporary raid response.'),
        const SizedBox(height: 12),
        Card(child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Message and mention limits', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
            const SizedBox(height: 9),
            TextField(controller: _messageRate, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Message burst limit', hintText: 'Messages per time window', helperText: 'Maximum messages allowed before server rate limiting.')),
            const SizedBox(height: 10),
            TextField(controller: _mentionRate, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Mention burst limit', hintText: 'Mentions per time window')),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Restrict links for new members'),
              value: _restrictLinks, onChanged: (v) => setState(() => _restrictLinks = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pause new invite creation during lockdown'),
              value: _pauseInvites, onChanged: (v) => setState(() => _pauseInvites = v)),
          ]),
        )),
        const SizedBox(height: 10),
        Card(child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Temporary raid lockdown', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
              _StatusTag(label: _lockdown ? 'DRAFT ON' : 'INACTIVE', tone: _lockdown ? _TagTone.warning : _TagTone.neutral),
            ]),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Prepare lockdown'),
              subtitle: const Text('Time-bound response to unusual join or message activity.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
              value: _lockdown, onChanged: (v) => setState(() => _lockdown = v)),
            if (_lockdown) ...[
              DropdownButtonFormField<String>(
                value: _scope, decoration: const InputDecoration(labelText: 'Scope'),
                items: const ['All text channels', 'Selected channels', 'New members only'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                onChanged: (v) => setState(() => _scope = v ?? _scope),
              ),
              const SizedBox(height: 9),
              DropdownButtonFormField<String>(
                value: _duration, decoration: const InputDecoration(labelText: 'Duration'),
                items: const ['15 minutes', '30 minutes', '1 hour', '6 hours'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                onChanged: (v) => setState(() => _duration = v ?? _duration),
              ),
            ],
            const SizedBox(height: 9),
            FilledButton.icon(onPressed: _prepareSafetyDraft, icon: const Icon(Icons.security_outlined), label: const Text('Review safety policy')),
            if (_draftReady) const _WritePendingNote(text: 'Safety policy is ready for review. No rate limit or lockdown has been activated on the server.'),
          ]),
        )),
        const SizedBox(height: 16),
        const _SectionHeader(title: 'Current channel safeguards', subtitle: 'Read-only status from saved channel settings. Edit them in Channel Studio.'),
        if (channels.isEmpty) const _EmptyState(
          icon: Icons.tune_outlined, title: 'No channel settings found',
          body: 'Saved channel safety rules will appear here.',
        ) else ...channels.map((channel) => _ChannelPolicyCard(
          channel: channel,
          onOpen: widget.onOpenChannelStudio,
        )),
      ]);
    },
  );

  void _prepareSafetyDraft() {
    final messages = int.tryParse(_messageRate.text.trim());
    final mentions = int.tryParse(_mentionRate.text.trim());
    if ((_messageRate.text.trim().isNotEmpty && (messages == null || messages < 1)) ||
        (_mentionRate.text.trim().isNotEmpty && (mentions == null || mentions < 1))) {
      showMessage(context, 'Rate limits must be positive whole numbers.');
      return;
    }
    setState(() => _draftReady = true);
  }
}

class _ChannelPolicyCard extends StatelessWidget {
  const _ChannelPolicyCard({required this.channel, this.onOpen});
  final Map<String, dynamic> channel;
  final Future<void> Function()? onOpen;
  @override
  Widget build(BuildContext context) {
    final settings = channel['settings'] is Map ? Map<String, dynamic>.from(channel['settings'] as Map) : <String, dynamic>{};
    final saved = settings.isNotEmpty;
    final slow = (settings['slow_mode_seconds'] as num?)?.toInt() ?? 0;
    final readOnly = settings['read_only'] == true;
    final links = settings['allow_links'] != false;
    final mentions = settings['allow_everyone_mention'] != false;
    return Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(
      padding: const EdgeInsets.all(11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(channel['kind'] == 'announcement' ? Icons.campaign_outlined : Icons.tag, color: KomnivoTheme.cyan, size: 17),
          const SizedBox(width: 7),
          Expanded(child: Text('#' + channel['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11))),
          _StatusTag(label: saved ? 'SAVED RULES' : 'DEFAULTS', tone: saved ? _TagTone.success : _TagTone.neutral),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 5, children: [
          _StatusTag(label: readOnly ? 'READ ONLY' : 'POSTING'),
          _StatusTag(label: 'SLOW MODE ' + slow.toString() + 's'),
          _StatusTag(label: links ? 'LINKS ALLOWED' : 'LINKS BLOCKED'),
          _StatusTag(label: mentions ? 'BROAD MENTIONS' : 'MENTIONS RESTRICTED'),
        ]),
        if (onOpen != null) Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: () => onOpen!(), icon: const Icon(Icons.open_in_new, size: 14), label: const Text('Open Channel Studio'),
        )),
      ]),
    ));
  }
}

class _AuditTab extends StatefulWidget {
  const _AuditTab({required this.communityId, required this.source});
  final String communityId;
  final CommunityOperationsDataSource source;
  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  late Future<List<Map<String, dynamic>>> _future;
  final _search = TextEditingController();
  @override
  void initState() {
    super.initState();
    _future = widget.source.loadAudit(widget.communityId);
    _search.addListener(() { if (mounted) setState(() {}); });
  }
  @override
  void dispose() { _search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return _LoadFailure(
        title: 'Audit history could not be loaded', details: snapshot.error.toString(),
        onRetry: () => setState(() => _future = widget.source.loadAudit(widget.communityId)),
      );
      final records = snapshot.data ?? const <Map<String, dynamic>>[];
      final query = _search.text.trim().toLowerCase();
      final filtered = records.where((row) {
        final action = row['action']?.toString().toLowerCase() ?? '';
        final entity = row['entity_type']?.toString().toLowerCase() ?? '';
        final reason = row['reason']?.toString().toLowerCase() ?? '';
        return query.isEmpty || action.contains(query) || entity.contains(query) || reason.contains(query);
      }).toList();
      return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
        const _PageHeading(title: 'Audit history', subtitle: 'Review recorded community decisions with role-restricted access.'),
        const SizedBox(height: 12),
        TextField(controller: _search, decoration: InputDecoration(
          hintText: 'Search action, entity or reason', prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _search.text.isEmpty ? null : IconButton(onPressed: _search.clear, icon: const Icon(Icons.close_rounded)),
        )),
        const SizedBox(height: 9),
        Text(filtered.length.toString() + ' records', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        const SizedBox(height: 5),
        if (records.isEmpty) const _EmptyState(
          icon: Icons.history_toggle_off_outlined, title: 'No audit records',
          body: 'No community audit records are visible to your role. This view never invents moderation history.',
        ) else if (filtered.isEmpty) const _EmptyState(
          icon: Icons.search_off_outlined, title: 'No matching history', body: 'Try another action or reason.',
        ) else ...filtered.map((row) => _AuditRecordCard(row: row)),
        const SizedBox(height: 14),
        const _PrivacyNote(text: 'Audit access is permission-gated. Member histories and personal data must be revealed only for an authorised purpose and only to roles with need-to-know access.'),
      ]);
    },
  );
}

class _AuditRecordCard extends StatelessWidget {
  const _AuditRecordCard({required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(row['created_at']?.toString() ?? '');
    return Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(
      padding: const EdgeInsets.all(11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.receipt_long_outlined, color: KomnivoTheme.cyan, size: 18),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(row['action']?.toString() ?? 'Community action', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(height: 3),
          Text((row['entity_type'] ?? 'Record').toString() + ' · ' + (created == null ? 'Time unavailable' : _dateLabel(created)),
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
          if (row['reason']?.toString().trim().isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(row['reason'].toString(), style: const TextStyle(fontSize: 10, height: 1.35)),
          ],
        ])),
      ]),
    ));
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.title, required this.subtitle});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
    const SizedBox(height: 3),
    Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4)),
  ]);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.35)),
    ]),
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.label, required this.icon});
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: KomnivoTheme.cyan), const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800)),
    ]),
  );
}

enum _TagTone { neutral, success, warning, danger }

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, this.tone = _TagTone.neutral});
  final String label;
  final _TagTone tone;
  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _TagTone.success => const Color(0xFF54C9A5),
      _TagTone.warning => const Color(0xFFFFC66D),
      _TagTone.danger => KomnivoTheme.danger,
      _TagTone.neutral => KomnivoTheme.muted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(7), border: Border.all(color: color.withValues(alpha: .28))),
      child: Text(label, style: TextStyle(fontSize: 8, letterSpacing: .25, fontWeight: FontWeight.w900, color: color)),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.danger = false});
  final String label;
  final String value;
  final bool danger;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 112, child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9))),
      Expanded(child: Text(value, style: TextStyle(color: danger ? KomnivoTheme.danger : Colors.white, fontSize: 10, fontWeight: FontWeight.w700))),
    ]),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(11), border: Border.all(color: KomnivoTheme.line)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.privacy_tip_outlined, color: KomnivoTheme.muted, size: 15), const SizedBox(width: 7),
      Expanded(child: Text(text, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4))),
    ]),
  );
}

class _SafetyBoundaryCard extends StatelessWidget {
  const _SafetyBoundaryCard({required this.title, required this.body});
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Card(
    color: KomnivoTheme.surfaceRaised,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.verified_user_outlined, color: KomnivoTheme.cyan), const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
          const SizedBox(height: 4),
          Text(body, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4)),
        ])),
      ]),
    ),
  );
}

class _WritePendingNote extends StatelessWidget {
  const _WritePendingNote({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(9), border: Border.all(color: KomnivoTheme.line)),
    child: Text(text, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4)),
  );
}

class _PendingFeatureCard extends StatelessWidget {
  const _PendingFeatureCard({required this.title, required this.detail, required this.icon});
  final String title;
  final String detail;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(12),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: KomnivoTheme.cyan), const SizedBox(width: 9),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
        const SizedBox(height: 4),
        Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4)),
      ])),
    ]),
  ));
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 10),
    child: Column(children: [
      Icon(icon, color: KomnivoTheme.muted, size: 31), const SizedBox(height: 9),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      Text(body, textAlign: TextAlign.center, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4)),
      if (action != null) action!,
    ]),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.title, required this.details, required this.onRetry});
  final String title;
  final String details;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(22),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.cloud_off_outlined, color: KomnivoTheme.muted, size: 31), const SizedBox(height: 9),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      Text(details, maxLines: 4, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
      const SizedBox(height: 10),
      OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
    ]),
  ));
}

String _dateLabel(DateTime value) {
  final local = value.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return day + '/' + month + '/' + local.year.toString() + ' · ' + hour + ':' + minute;
}
