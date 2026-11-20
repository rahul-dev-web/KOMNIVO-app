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
    this.onOpenChannel,
  });

  final Map<String, dynamic> community;
  final CommunityOperationsDataSource? dataSource;
  final Future<void> Function()? onOpenChannelStudio;
  final Future<void> Function(Map<String, dynamic> channel)? onOpenChannel;

  @override
  State<CommunityOperationsScreen> createState() =>
      _CommunityOperationsScreenState();
}

abstract class CommunityOperationsDataSource {
  Future<Set<String>> loadPermissions(String communityId);
  Future<CommunityDirectoryData> loadDirectory(String communityId);
  Future<CommunityIdentityData> loadIdentity(String communityId);
  Future<Map<String, dynamic>> loadOnboardingData(String communityId);
  Future<void> saveOnboardingConfiguration(
    String communityId,
    List<Map<String, dynamic>> questions,
  );
  Future<void> submitOnboardingAnswers(
    String communityId,
    Map<String, dynamic> answers,
  );
  Future<List<Map<String, dynamic>>> loadChannelRecommendations(
    String communityId,
  );
  Future<void> saveChannelOnboardingTags(
    String communityId,
    String channelId,
    List<String> topics,
    List<String> gameModes,
  );
  Future<Map<String, dynamic>> loadCommunityAccessPolicy(String communityId);
  Future<void> saveCommunityAccessPolicy(String communityId, String visibility, bool approvalRequired);
  Future<List<Map<String, dynamic>>> loadInvites(String communityId);
  Future<Map<String, dynamic>> createInvite(String communityId, int? maxUses, int? expiresInHours, bool requiresApproval);
  Future<void> revokeInvite(String inviteId);
  Future<List<Map<String, dynamic>>> loadJoinRequests(String communityId);
  Future<void> reviewJoinRequest(String requestId, String decision, String reason);
  Future<List<Map<String, dynamic>>> loadReports(String communityId);
  Future< String > submitModerationReport(String communityId, String? targetUserId, String? messageId, String reason, String details);
  Future<List<Map<String, dynamic>>> loadModerationActions(String communityId);
  Future<String> applyModerationAction(String communityId, Map<String, dynamic> action);
  Future<List<Map<String, dynamic>>> loadAppeals(String communityId);
  Future<String> submitAppeal(String actionId, String reason, String details, String evidenceReference);
  Future<void> reviewAppeal(String appealId, String decision, String response, int? newDurationMinutes);
  Future<Map<String, dynamic>> loadSafetySettings(String communityId);
  Future<void> saveSafetySettings(String communityId, Map<String, dynamic> settings);
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
      'community.manage_structure',
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
    final rows = await _db.rpc(
      'get_community_member_directory',
      params: {'p_community_id': communityId},
    );
    if (rows is! List) {
      throw Exception('The member directory returned an invalid response.');
    }
    return CommunityDirectoryData(
      members: List<Map<String, dynamic>>.from(rows),
    );
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
  Future<Map<String, dynamic>> loadOnboardingData(String communityId) async {
    final result = await _db.rpc(
      'get_community_onboarding_data',
      params: {'p_community_id': communityId},
    );
    if (result is! Map) {
      throw Exception('Onboarding data returned an invalid response.');
    }
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<void> saveOnboardingConfiguration(
    String communityId,
    List<Map<String, dynamic>> questions,
  ) async {
    await _db.rpc(
      'save_community_onboarding_configuration',
      params: {
        'p_community_id': communityId,
        'p_questions': questions,
      },
    );
  }

  @override
  Future<void> submitOnboardingAnswers(
    String communityId,
    Map<String, dynamic> answers,
  ) async {
    await _db.rpc(
      'submit_community_onboarding_answers',
      params: {
        'p_community_id': communityId,
        'p_answers': answers,
      },
    );
  }

  @override
  Future<List<Map<String, dynamic>>> loadChannelRecommendations(
    String communityId,
  ) async {
    final rows = await _db.rpc(
      'get_community_channel_recommendations',
      params: {'p_community_id': communityId},
    );
    if (rows is! List) {
      throw Exception('Channel recommendations returned an invalid response.');
    }
    return List<Map<String, dynamic>>.from(rows).map((row) {
      final channel = Map<String, dynamic>.from(row);
      channel['id'] = channel['channel_id'];
      return channel;
    }).toList();
  }

  @override
  Future<void> saveChannelOnboardingTags(
    String communityId,
    String channelId,
    List<String> topics,
    List<String> gameModes,
  ) async {
    await _db.rpc(
      'save_community_channel_onboarding_tags',
      params: {
        'p_community_id': communityId,
        'p_channel_id': channelId,
        'p_topics': topics,
        'p_game_modes': gameModes,
      },
    );
  }

  @override
  Future<Map<String, dynamic>> loadCommunityAccessPolicy(String communityId) async {
    final row = await _db.from('communities')
        .select('visibility,join_approval_required')
        .eq('id', communityId)
        .maybeSingle();
    if (row == null) throw Exception('Community access policy is unavailable.');
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<void> saveCommunityAccessPolicy(
    String communityId,
    String visibility,
    bool approvalRequired,
  ) async {
    await _db.rpc('update_community_access_policy', params: {
      'p_community_id': communityId,
      'p_visibility': visibility,
      'p_require_approval': approvalRequired,
    });
  }

  @override
  Future<List<Map<String, dynamic>>> loadInvites(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('community_invites')
          .select('id,created_by,expires_at,max_uses,uses,created_at,revoked_at,requires_approval')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<Map<String, dynamic>> createInvite(
    String communityId,
    int? maxUses,
    int? expiresInHours,
    bool requiresApproval,
  ) async {
    final response = await _db.functions.invoke(
      'create-community-invite',
      body: {
        'community_id': communityId,
        'max_uses': maxUses,
        'expires_in_hours': expiresInHours,
        'requires_approval': requiresApproval,
      },
    );
    if (response.status < 200 || response.status >= 300 || response.data is! Map) {
      throw Exception((response.data is Map
          ? (response.data as Map)['error']
          : null)?.toString() ?? 'Invite creation failed.');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  @override
  Future<void> revokeInvite(String inviteId) async {
    await _db.rpc('revoke_community_invite', params: {'p_invite_id': inviteId});
  }

  @override
  Future<List<Map<String, dynamic>>> loadJoinRequests(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('community_join_requests')
          .select('id,user_id,invite_id,status,applicant_note,review_reason,created_at,reviewed_at,profiles!community_join_requests_user_id_fkey(display_name,username,avatar_url)')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<void> reviewJoinRequest(String requestId, String decision, String reason) async {
    await _db.rpc('review_community_join_request', params: {
      'p_request_id': requestId,
      'p_decision': decision,
      'p_reason': reason,
    });
  }

  @override
  Future<List<Map<String, dynamic>>> loadReports(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('moderation_reports')
          .select('id,reporter_id,target_user_id,message_id,reason,details,status,assigned_to,created_at,resolved_at')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<String> submitModerationReport(
    String communityId,
    String? targetUserId,
    String? messageId,
    String reason,
    String details,
  ) async {
    final result = await _db.rpc('submit_community_moderation_report', params: {
      'p_community_id': communityId,
      'p_target_user_id': targetUserId,
      'p_message_id': messageId,
      'p_reason': reason,
      'p_details': details,
    });
    return result.toString();
  }

  @override
  Future<List<Map<String, dynamic>>> loadModerationActions(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('community_moderation_actions')
          .select('id,action_type,target_user_id,channel_id,message_id,reason,duration_minutes,status,created_by,created_at')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<String> applyModerationAction(
    String communityId,
    Map<String, dynamic> action,
  ) async {
    final result = await _db.rpc('apply_community_moderation_action', params: {
      'p_community_id': communityId,
      'p_action_type': action['action_type'],
      'p_target_user_id': action['target_user_id'],
      'p_reason': action['reason'],
      'p_duration_minutes': action['duration_minutes'],
      'p_channel_id': action['channel_id'],
      'p_message_id': action['message_id'],
    });
    return result.toString();
  }

  @override
  Future<List<Map<String, dynamic>>> loadAppeals(String communityId) async =>
      List<Map<String, dynamic>>.from(await _db.from('community_moderation_appeals')
          .select('id,moderation_action_id,appellant_id,reason,details,evidence_reference,status,reviewer_id,reviewer_response,created_at,reviewed_at')
          .eq('community_id', communityId)
          .order('created_at', ascending: false).limit(100));

  @override
  Future<String> submitAppeal(
    String actionId,
    String reason,
    String details,
    String evidenceReference,
  ) async {
    final result = await _db.rpc('submit_community_moderation_appeal', params: {
      'p_moderation_action_id': actionId,
      'p_reason': reason,
      'p_details': details,
      'p_evidence_reference': evidenceReference,
    });
    return result.toString();
  }

  @override
  Future<void> reviewAppeal(
    String appealId,
    String decision,
    String response,
    int? newDurationMinutes,
  ) async {
    await _db.rpc('review_community_moderation_appeal', params: {
      'p_appeal_id': appealId,
      'p_decision': decision,
      'p_response': response,
      'p_new_duration_minutes': newDurationMinutes,
    });
  }

  @override
  Future<Map<String, dynamic>> loadSafetySettings(String communityId) async {
    final row = await _db.from('community_safety_settings')
        .select()
        .eq('community_id', communityId)
        .maybeSingle();
    return row == null ? <String, dynamic>{} : Map<String, dynamic>.from(row);
  }

  @override
  Future<void> saveSafetySettings(
    String communityId,
    Map<String, dynamic> settings,
  ) async {
    await _db.rpc('save_community_safety_settings', params: {
      'p_community_id': communityId,
      'p_message_burst_limit': settings['message_burst_limit'],
      'p_message_window_seconds': settings['message_window_seconds'],
      'p_mention_burst_limit': settings['mention_burst_limit'],
      'p_mention_window_seconds': settings['mention_window_seconds'],
      'p_restrict_links_for_new_members': settings['restrict_links_for_new_members'],
      'p_new_member_link_restriction_hours': settings['new_member_link_restriction_hours'],
      'p_pause_invites_during_lockdown': settings['pause_invites_during_lockdown'],
      'p_raid_join_threshold': settings['raid_join_threshold'],
      'p_raid_window_seconds': settings['raid_window_seconds'],
      'p_lockdown_minutes': settings['lockdown_minutes'],
      'p_lockdown_reason': settings['lockdown_reason'],
    });
  }


  @override
  Future<List<Map<String, dynamic>>> loadChannelPolicies(String communityId) async {
    final channels = List<Map<String, dynamic>>.from(await _db.from('channels')
        .select('id,name,kind,archived_at,event_id,onboarding_topics,onboarding_game_modes').eq('community_id', communityId)
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
          communityId: _communityId,
          source: _source,
          canManageMembers: access.contains('community.manage_members'),
        )),
        _OperationsSection('Onboarding', Icons.fact_check_outlined, _OnboardingTab(
          communityId: _communityId, source: _source,
          canConfigure: access.contains('community.manage_members'),
          canTagChannels: access.contains('community.manage_structure'),
          onOpenChannel: widget.onOpenChannel,
        )),
        _OperationsSection('Appeals', Icons.balance_outlined, _AppealsTab(
          canReviewAppeals: access.contains('community.manage_members'),
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
  const _MemberDirectoryTab({
    required this.communityId,
    required this.source,
    required this.canManageMembers,
  });
  final String communityId;
  final CommunityOperationsDataSource source;
  final bool canManageMembers;
  @override
  State<_MemberDirectoryTab> createState() => _MemberDirectoryTabState();
}

class _MemberDirectoryTabState extends State<_MemberDirectoryTab> {
  late Future<CommunityDirectoryData> _future;
  final _search = TextEditingController();
  String _filter = 'All';

  static const _filters = [
    'All', 'Staff', 'Verified players', 'Team captains',
    'Event participants', 'Muted / restricted', 'Recent joins',
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
      case 'Muted / restricted': return restricted;
      case 'Recent joins': return recent;
      default: return true;
    }
  }

  Future<void> _openMember(Map<String, dynamic> member) async {
    List<Map<String, dynamic>> channels = [];
    if (widget.canManageMembers) {
      try {
        channels = await widget.source.loadChannelPolicies(widget.communityId);
      } catch (_) {
        channels = [];
      }
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, useSafeArea: true,
      backgroundColor: KomnivoTheme.surface,
      builder: (context) => _MemberDetailsSheet(
        member: member,
        name: _name(member),
        canManageMembers: widget.canManageMembers,
        availableChannels: channels,
      ),
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
              text: 'Member visibility follows community access and profile privacy. Free Fire UIDs and private profile fields are never fetched here. Current game-account RLS exposes ownership status to the owner only; the Verified players directory filter will show only statuses permitted by the current account policy until a safe public classification is added in the Batch 4 backend.',
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
                if (restricted) const _StatusTag(label: 'MUTED', tone: _TagTone.danger),
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
  const _MemberDetailsSheet({
    required this.member,
    required this.name,
    required this.canManageMembers,
    this.availableChannels = const [],
  });
  final Map<String, dynamic> member;
  final String name;
  final bool canManageMembers;
  final List<Map<String, dynamic>> availableChannels;
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
          _DetailRow(label: 'Profile visibility', value: profile['is_public'] == true ? 'Public' : 'Private'),
          _DetailRow(label: 'Team role', value: member['_is_team_captain'] == true ? 'Captain / Owner' : 'No captain assignment'),
          _DetailRow(label: 'Event participation', value: member['_is_event_participant'] == true ? 'Registered in a community event' : 'No current registration found'),
          if (restricted) _DetailRow(label: 'Restriction', value: 'Muted until ' + _dateLabel(muted), danger: true),
          const SizedBox(height: 12),
          const _PrivacyNote(text: 'Moderation controls are available only after the server confirms the acting moderator’s scope and authority.'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final report = await showDialog<Map<String, String>>(
                    context: context,
                    builder: (_) => _ReportDraftDialog(memberName: name),
                  );
                  if (report != null && context.mounted) {
                    showMessage(context, 'Report draft prepared. Nothing has been submitted.');
                  }
                },
                icon: const Icon(Icons.flag_outlined, size: 16),
                label: const Text('Prepare report'),
              ),
            ),
            if (canManageMembers) ...[
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    final action = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => _ModerationActionDialog(
                        memberName: name,
                        targetUserId: member['user_id']?.toString(),
                        availableChannels: availableChannels,
                      ),
                    );
                    if (action != null && context.mounted) {
                      showMessage(context, 'Moderation action drafted for ' + name + '. No member state has changed.');
                    }
                  },
                  icon: const Icon(Icons.shield_outlined, size: 16),
                  label: const Text('Moderate'),
                ),
              ),
            ],
          ]),
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
        isExpanded: true,
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
  const _OnboardingTab({
    required this.communityId,
    required this.source,
    required this.canConfigure,
    this.canTagChannels = false,
    this.onOpenChannel,
  });
  final String communityId;
  final CommunityOperationsDataSource source;
  final bool canConfigure;
  final bool canTagChannels;
  final Future<void> Function(Map<String, dynamic> channel)? onOpenChannel;
  @override
  State<_OnboardingTab> createState() => _OnboardingTabState();
}

class _OnboardingTabState extends State<_OnboardingTab> {
  late Future<CommunityIdentityData> _identity;
  late Future<Map<String, dynamic>> _onboarding;
  late Future<List<Map<String, dynamic>>> _channels;
  Future<List<Map<String, dynamic>>>? _recommendations;
  final Map<String, TextEditingController> _promptControllers = {};
  final Map<String, TextEditingController> _optionControllers = {};
  final Map<String, TextEditingController> _textAnswerControllers = {};
  List<Map<String, dynamic>> _questions = [];
  Map<String, dynamic> _answers = {};
  bool _seeded = false;
  bool _saving = false;
  bool _showRecommendations = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _load() {
    _identity = widget.source.loadIdentity(widget.communityId);
    _onboarding = widget.source.loadOnboardingData(widget.communityId);
    _channels = widget.source.loadChannelPolicies(widget.communityId);
  }

  void _disposeControllers() {
    for (final item in _promptControllers.values) {
      item.dispose();
    }
    for (final item in _optionControllers.values) {
      item.dispose();
    }
    for (final item in _textAnswerControllers.values) {
      item.dispose();
    }
    _promptControllers.clear();
    _optionControllers.clear();
    _textAnswerControllers.clear();
  }

  List<String> _strings(dynamic value) => value is List
      ? value.map((item) => item.toString()).toList()
      : <String>[];

  void _seed(Map<String, dynamic> data) {
    if (_seeded) return;
    _disposeControllers();
    final sourceQuestions = data['questions'];
    _questions = sourceQuestions is List
        ? sourceQuestions.whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item)).toList()
        : <Map<String, dynamic>>[];
    final sourceAnswers = data['answers'];
    _answers = sourceAnswers is Map
        ? Map<String, dynamic>.from(sourceAnswers)
        : <String, dynamic>{};
    for (final question in _questions) {
      final key = question['question_key'].toString();
      _promptControllers[key] = TextEditingController(
        text: question['prompt']?.toString() ?? '',
      );
      _optionControllers[key] = TextEditingController(
        text: _strings(question['options']).join('\n'),
      );
      if (question['question_type'] == 'text') {
        _textAnswerControllers[key] = TextEditingController(
          text: _answers[key]?.toString() ?? '',
        );
      }
    }
    _seeded = true;
  }

  String _title(String key) => switch (key) {
    'game_mode' => 'Game mode',
    'player_interests' => 'Player interests',
    'region' => 'Region',
    _ => 'Preferred activities',
  };

  List<Map<String, dynamic>> _configurationPayload() =>
      _questions.map((question) {
        final key = question['question_key'].toString();
        final type = question['question_type'].toString();
        final options = type == 'text'
            ? <String>[]
            : (_optionControllers[key]?.text ?? '')
                .split('\n')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList();
        return <String, dynamic>{
          'question_key': key,
          'prompt': _promptControllers[key]?.text.trim() ?? '',
          'question_type': type,
          'options': options,
          'is_enabled': question['is_enabled'] == true,
          'is_required': question['is_required'] == true,
        };
      }).toList();

  bool get _answersValid {
    for (final question in _questions) {
      if (question['is_enabled'] != true || question['is_required'] != true) {
        continue;
      }
      final key = question['question_key'].toString();
      final value = _answers[key];
      if (question['question_type'] == 'multi_select') {
        if (value is! List || value.isEmpty) return false;
      } else if (value == null || value.toString().trim().isEmpty) {
        return false;
      }
    }
    return true;
  }

  Future<void> _reloadOnboarding({bool clearRecommendations = false}) async {
    final next = widget.source.loadOnboardingData(widget.communityId);
    setState(() {
      _seeded = false;
      _onboarding = next;
      _channels = widget.source.loadChannelPolicies(widget.communityId);
      if (clearRecommendations) {
        _showRecommendations = false;
        _recommendations = null;
      }
    });
    await next;
  }

  Future<void> _saveConfiguration() async {
    setState(() => _saving = true);
    try {
      await widget.source.saveOnboardingConfiguration(
        widget.communityId,
        _configurationPayload(),
      );
      if (!mounted) return;
      showMessage(context, 'Onboarding questions saved for this community.');
      await _reloadOnboarding(clearRecommendations: true);
    } catch (error) {
      if (mounted) {
        showMessage(context, 'Onboarding settings were not saved: ' + error.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitAnswers() async {
    if (!_answersValid) {
      showMessage(context, 'Complete every required onboarding question first.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.source.submitOnboardingAnswers(
        widget.communityId,
        _answers,
      );
      if (!mounted) return;
      setState(() {
        _recommendations =
            widget.source.loadChannelRecommendations(widget.communityId);
        _showRecommendations = true;
      });
      showMessage(context, 'Your onboarding preferences were saved.');
      await _reloadOnboarding();
    } catch (error) {
      if (mounted) {
        showMessage(context, 'Your onboarding answers were not saved: ' + error.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toggleMultiAnswer(String key, String option, bool selected) {
    final choices = _strings(_answers[key]);
    if (selected && !choices.contains(option)) {
      choices.add(option);
    } else if (!selected) {
      choices.remove(option);
    }
    setState(() => _answers[key] = choices);
  }

  Widget _builder() {
    final enabled = _questions.where((item) => item['is_enabled'] == true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeading(
          title: 'Onboarding questions',
          subtitle: 'Configure the four community questions. Answers may guide channels, never roles or permissions.',
        ),
        const SizedBox(height: 8),
        ..._questions.map((question) {
          final key = question['question_key'].toString();
          final isEnabled = question['is_enabled'] == true;
          final type = question['question_type'].toString();
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        _title(key),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                      ),
                    ),
                    _StatusTag(label: type.toUpperCase()),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _promptControllers[key],
                    enabled: !_saving,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: 'Question shown to members'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Question enabled'),
                    value: isEnabled,
                    onChanged: _saving ? null : (value) => setState(() {
                      question['is_enabled'] = value;
                      if (!value) question['is_required'] = false;
                    }),
                  ),
                  if (isEnabled)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilterChip(
                        label: const Text('Required'),
                        selected: question['is_required'] == true,
                        onSelected: _saving ? null : (value) => setState(
                          () => question['is_required'] = value,
                        ),
                      ),
                    ),
                  if (type != 'text' && isEnabled) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _optionControllers[key],
                      enabled: !_saving,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 1800,
                      decoration: const InputDecoration(
                        labelText: 'Allowed options',
                        helperText: 'One option per line. Up to 30 unique options, maximum 60 characters each.',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
        const _SafetyBoundaryCard(
          title: 'Answers never grant authority',
          body: 'Game mode, player interests, region and preferred activities are profile preferences only. Community roles and event staff access remain separate explicit assignments.',
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _saving || enabled.isEmpty ? null : _saveConfiguration,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving…' : 'Save onboarding configuration'),
        ),
      ],
    );
  }

  Widget _memberQuestion(Map<String, dynamic> question) {
    final key = question['question_key'].toString();
    final prompt = question['prompt']?.toString() ?? _title(key);
    final type = question['question_type'].toString();
    final options = _strings(question['options']);
    final required = question['is_required'] == true;
    final label = required ? prompt + ' *' : prompt;

    if (type == 'single_select') {
      final selected = _answers[key]?.toString();
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          isExpanded: true,
          value: options.contains(selected) ? selected : null,
          decoration: InputDecoration(labelText: label),
          items: options.map((value) => DropdownMenuItem(
            value: value,
            child: Text(value),
          )).toList(),
          onChanged: _saving ? null : (value) => setState(() {
            if (value == null) {
              _answers.remove(key);
            } else {
              _answers[key] = value;
            }
          }),
        ),
      );
    }

    if (type == 'multi_select') {
      final selected = _strings(_answers[key]).toSet();
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: options.map((option) => FilterChip(
                  label: Text(option),
                  selected: selected.contains(option),
                  onSelected: _saving ? null : (value) => _toggleMultiAnswer(key, option, value),
                )).toList(),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _textAnswerControllers[key],
        enabled: !_saving,
        maxLength: 80,
        onChanged: (value) => setState(() => _answers[key] = value),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _questionnaire() {
    final enabled = _questions.where((item) => item['is_enabled'] == true).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeading(
          title: 'Your player preferences',
          subtitle: 'Your answers help discover relevant channels. They do not verify your UID or change your community role.',
        ),
        const SizedBox(height: 10),
        if (enabled.isEmpty)
          const _EmptyState(
            icon: Icons.fact_check_outlined,
            title: 'Onboarding is not configured yet',
            body: 'The community has not enabled any onboarding questions.',
          )
        else
          ...enabled.map(_memberQuestion),
        const SizedBox(height: 12),
        const _SafetyBoundaryCard(
          title: 'Identity and membership are separate',
          body: 'KOMNIVO sign-in, Free Fire UID ownership verification and community membership acceptance are three independent states.',
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _saving || !_answersValid ? null : _submitAnswers,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving…' : 'Save my preferences'),
        ),
        if (_showRecommendations && _recommendations != null) ...[
          const SizedBox(height: 14),
          _OnboardingChannelRecommendations(
            recommendations: _recommendations!,
            onOpenChannel: widget.onOpenChannel,
          ),
        ],
      ],
    );
  }

  Widget _channelTagging() => FutureBuilder<List<Map<String, dynamic>>>(
    future: _channels,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (snapshot.hasError) {
        return _LoadFailure(
          title: 'Community channels could not be loaded',
          details: snapshot.error.toString(),
          onRetry: () => setState(() => _channels = widget.source.loadChannelPolicies(widget.communityId)),
        );
      }
      final channels = snapshot.data ?? const <Map<String, dynamic>>[];
      final topics = <String>{
        for (final question in _questions)
          if ((question['question_key'] == 'player_interests' ||
                  question['question_key'] == 'preferred_activities') &&
              question['is_enabled'] == true)
            ..._strings(question['options']),
      }.toList()..sort();
      final modes = _questions
          .where((question) =>
              question['question_key'] == 'game_mode' &&
              question['is_enabled'] == true)
          .expand((question) => _strings(question['options']))
          .toList();
      final communityChannels = channels.where((channel) => channel['event_id'] == null).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Channel recommendations',
            subtitle: 'Tag real community channels so members with matching interests can discover them.',
          ),
          if (topics.isEmpty && modes.isEmpty)
            const _EmptyState(
              icon: Icons.label_off_outlined,
              title: 'Enable preference options first',
              body: 'At least one game mode, interest or activity option is needed before channels can be tagged.',
            )
          else if (communityChannels.isEmpty)
            const _EmptyState(
              icon: Icons.tag,
              title: 'No community channels',
              body: 'Create a community channel before assigning onboarding tags.',
            )
          else
            ...communityChannels.map((channel) => _OnboardingChannelTagEditor(
              key: ValueKey(channel['id']),
              channel: channel,
              topicOptions: topics,
              gameModeOptions: modes,
              onSave: (selectedTopics, selectedModes) => widget.source.saveChannelOnboardingTags(
                widget.communityId,
                channel['id'].toString(),
                selectedTopics,
                selectedModes,
              ),
              onSaved: () {
                if (mounted) setState(() => _channels = widget.source.loadChannelPolicies(widget.communityId));
              },
            )),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<CommunityIdentityData>(
    future: _identity,
    builder: (context, identitySnapshot) {
      if (identitySnapshot.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      if (identitySnapshot.hasError) {
        return _LoadFailure(
          title: 'Account and membership states could not be loaded',
          details: identitySnapshot.error.toString(),
          onRetry: () => setState(_load),
        );
      }
      return FutureBuilder<Map<String, dynamic>>(
        future: _onboarding,
        builder: (context, onboardingSnapshot) {
          if (onboardingSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (onboardingSnapshot.hasError) {
            return _LoadFailure(
              title: 'Community onboarding could not be loaded',
              details: onboardingSnapshot.error.toString(),
              onRetry: () => setState(() {
                _seeded = false;
                _onboarding = widget.source.loadOnboardingData(widget.communityId);
              }),
            );
          }
          final data = onboardingSnapshot.data!;
          _seed(data);
          final canConfigure = widget.canConfigure && data['can_configure'] == true;
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
            children: [
              const _PageHeading(
                title: 'Member onboarding',
                subtitle: 'Configure player questions, save preferences and recommend channels without changing roles.',
              ),
              const SizedBox(height: 12),
              _IdentityStateCard(identity: identitySnapshot.data!),
              const SizedBox(height: 14),
              if (canConfigure) ...[
                _builder(),
                const SizedBox(height: 18),
                _questionnaire(),
              ] else
                _questionnaire(),
              if (widget.canTagChannels) ...[
                const SizedBox(height: 18),
                _channelTagging(),
              ],
            ],
          );
        },
      );
    },
  );
}

class _OnboardingChannelTagEditor extends StatefulWidget {
  const _OnboardingChannelTagEditor({
    super.key,
    required this.channel,
    required this.topicOptions,
    required this.gameModeOptions,
    required this.onSave,
    required this.onSaved,
  });

  final Map<String, dynamic> channel;
  final List<String> topicOptions;
  final List<String> gameModeOptions;
  final Future<void> Function(List<String>, List<String>) onSave;
  final VoidCallback onSaved;

  @override
  State<_OnboardingChannelTagEditor> createState() => _OnboardingChannelTagEditorState();
}

class _OnboardingChannelTagEditorState extends State<_OnboardingChannelTagEditor> {
  late Set<String> _topics;
  late Set<String> _modes;
  bool _saving = false;

  List<String> _values(dynamic value) => value is List
      ? value.map((item) => item.toString()).toList()
      : <String>[];

  @override
  void initState() {
    super.initState();
    _topics = _values(widget.channel['onboarding_topics']).toSet();
    _modes = _values(widget.channel['onboarding_game_modes']).toSet();
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(widget.channel['kind'] == 'voice' ? Icons.volume_up_outlined : Icons.tag,
              color: KomnivoTheme.cyan, size: 16),
            const SizedBox(width: 7),
            Expanded(child: Text(
              '#' + widget.channel['name'].toString(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
            )),
          ]),
          if (widget.topicOptions.isNotEmpty) ...[
            const SizedBox(height: 9),
            const Text('Interests & activities', style: TextStyle(
              color: KomnivoTheme.muted, fontSize: 9, fontWeight: FontWeight.w700,
            )),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: widget.topicOptions.map((option) => FilterChip(
                label: Text(option),
                selected: _topics.contains(option),
                onSelected: _saving ? null : (selected) => setState(() {
                  if (selected) {
                    _topics.add(option);
                  } else {
                    _topics.remove(option);
                  }
                }),
              )).toList(),
            ),
          ],
          if (widget.gameModeOptions.isNotEmpty) ...[
            const SizedBox(height: 9),
            const Text('Game modes', style: TextStyle(
              color: KomnivoTheme.muted, fontSize: 9, fontWeight: FontWeight.w700,
            )),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: widget.gameModeOptions.map((option) => FilterChip(
                label: Text(option),
                selected: _modes.contains(option),
                onSelected: _saving ? null : (selected) => setState(() {
                  if (selected) {
                    _modes.add(option);
                  } else {
                    _modes.remove(option);
                  }
                }),
              )).toList(),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: _saving ? null : () async {
                setState(() => _saving = true);
                try {
                  await widget.onSave(_topics.toList(), _modes.toList());
                  if (!mounted) return;
                  showMessage(context, 'Channel recommendation tags saved.');
                  widget.onSaved();
                } catch (error) {
                  if (mounted) showMessage(context, 'Channel tags were not saved: ' + error.toString());
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined, size: 15),
              label: Text(_saving ? 'Saving…' : 'Save channel tags'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _OnboardingChannelRecommendations extends StatelessWidget {
  const _OnboardingChannelRecommendations({
    required this.recommendations,
    this.onOpenChannel,
  });

  final Future<List<Map<String, dynamic>>> recommendations;
  final Future<void> Function(Map<String, dynamic> channel)? onOpenChannel;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: recommendations,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Row(children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 9),
              Expanded(child: Text(
                'Finding channels that match your saved preferences…',
                style: TextStyle(color: KomnivoTheme.muted, fontSize: 10),
              )),
            ]),
          ),
        );
      }
      if (snapshot.hasError) {
        return _PrivacyNote(
          text: 'Channel recommendations could not be loaded: ' + snapshot.error.toString(),
        );
      }
      final channels = snapshot.data ?? const <Map<String, dynamic>>[];
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.explore_outlined, color: KomnivoTheme.cyan, size: 17),
                SizedBox(width: 7),
                Expanded(child: Text(
                  'Suggested community channels',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                )),
              ]),
              const SizedBox(height: 4),
              const Text(
                'Suggestions use saved preferences and channels you are allowed to view. They never grant membership or access.',
                style: TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4),
              ),
              const SizedBox(height: 8),
              if (channels.isEmpty)
                const Text(
                  'No matching channel has been tagged yet. A community manager can add interest and game-mode tags to channels.',
                  style: TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                )
              else
                ...channels.map((channel) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Icon(
                      channel['kind'] == 'voice' ? Icons.volume_up_outlined : Icons.tag,
                      color: KomnivoTheme.muted,
                      size: 15,
                    ),
                    const SizedBox(width: 7),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel['name'].toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          [
                            ..._values(channel['matched_topics']),
                            ..._values(channel['matched_game_modes']),
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8),
                        ),
                      ],
                    )),
                    if (onOpenChannel != null)
                      TextButton(
                        onPressed: () => onOpenChannel!(channel),
                        child: const Text('Open'),
                      ),
                  ]),
                )),
            ],
          ),
        ),
      );
    },
  );

  List<String> _values(dynamic value) => value is List
      ? value.map((item) => item.toString()).toList()
      : <String>[];
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
  late bool _inviteOnlyDraft;
  Map<String, dynamic>? _draft;
  Map<String, dynamic>? _revokeDraft;
  bool _joinApprovalRequired = false;
  bool _approvalPolicyDraftReady = false;

  String get _communityId => widget.community['id'].toString();

  @override
  void initState() {
    super.initState();
    _future = widget.source.loadInvites(_communityId);
    _inviteOnlyDraft = widget.community['visibility']?.toString() == 'private';
  }

  void _refresh() => setState(() => _future = widget.source.loadInvites(_communityId));

  Future<void> _createDraft() async {
    final draft = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _InviteSettingsDialog(initialInviteOnly: _inviteOnlyDraft),
    );
    if (draft != null && mounted) {
      setState(() {
        _draft = draft;
        _inviteOnlyDraft = draft['invite_only'] == true;
      });
    }
  }

  Future<void> _prepareRevoke(Map<String, dynamic> invite) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke invite?'),
        content: const Text(
          'This review will invalidate the selected link for future use. Existing members will not be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep invite'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Review revoke'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) setState(() => _revokeDraft = invite);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _LoadFailure(
          title: 'Invites could not be loaded',
          details: snapshot.error.toString(),
          onRetry: _refresh,
        );
      }
      final invites = snapshot.data ?? const <Map<String, dynamic>>[];
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          Row(children: [
            const Expanded(child: _PageHeading(
              title: 'Invite controls',
              subtitle: 'Manage expiry, usage limits, invite-only access and join approval.',
            )),
            FilledButton.icon(
              onPressed: _createDraft,
              icon: const Icon(Icons.add_link_rounded, size: 17),
              label: const Text('Create'),
            ),
          ]),
          const SizedBox(height: 12),
          _InvitePolicyCard(
            inviteOnly: _inviteOnlyDraft,
            onChanged: (value) => setState(() {
              _inviteOnlyDraft = value;
              _draft = null;
            }),
          ),
          if (_inviteOnlyDraft != (widget.community['visibility']?.toString() == 'private'))
            const _WritePendingNote(
              text: 'Invite-only visibility is a local policy draft. Community visibility has not been updated.',
            ),
          if (_draft != null) ...[
            const SizedBox(height: 9),
            _InviteDraftCard(
              draft: _draft!,
              onDiscard: () => setState(() => _draft = null),
            ),
          ],
          if (_revokeDraft != null) ...[
            const SizedBox(height: 9),
            _InviteRevokeDraftCard(
              invite: _revokeDraft!,
              onDiscard: () => setState(() => _revokeDraft = null),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Existing invite links',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 7),
          if (invites.isEmpty)
            const _EmptyState(
              icon: Icons.link_off_outlined,
              title: 'No invite records',
              body: 'There are no invite records visible for this community. Link issuance and revoke operations will be connected with the Batch 4 backend.',
            )
          else
            ...invites.map((row) => _InviteCard(
              invite: row,
              onRevoke: () => _prepareRevoke(row),
            )),
          const SizedBox(height: 18),
          const _SectionHeader(
            title: 'Join approval policy',
            subtitle: 'Decide whether applications must be reviewed by an authorised moderator.',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Require moderator approval'),
                  subtitle: const Text(
                    'New applications remain pending until an authorised reviewer accepts or rejects them.',
                    style: TextStyle(color: KomnivoTheme.muted, fontSize: 9),
                  ),
                  value: _joinApprovalRequired,
                  onChanged: (value) => setState(() {
                    _joinApprovalRequired = value;
                    _approvalPolicyDraftReady = false;
                  }),
                ),
                FilledButton.icon(
                  onPressed: () => setState(() => _approvalPolicyDraftReady = true),
                  icon: const Icon(Icons.rule_folder_outlined, size: 16),
                  label: const Text('Review approval policy'),
                ),
                if (_approvalPolicyDraftReady)
                  const _WritePendingNote(
                    text: 'Approval policy is ready for review. It has not changed community join behaviour.',
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          const _PendingFeatureCard(
            title: 'Pending application queue',
            detail: 'The approve / reject queue UI is defined. The current database has no community join-request record, so no applications can be listed or decided yet.',
            icon: Icons.fact_check_outlined,
          ),
        ],
      );
    },
  );
}

class _InviteSettingsDialog extends StatefulWidget {
  const _InviteSettingsDialog({required this.initialInviteOnly});
  final bool initialInviteOnly;
  @override
  State<_InviteSettingsDialog> createState() => _InviteSettingsDialogState();
}

class _InviteSettingsDialogState extends State<_InviteSettingsDialog> {
  String _expiry = '7 days';
  String _limit = '25 uses';
  bool _approval = false;
  bool _singleUse = false;
  late bool _inviteOnly;

  @override
  void initState() {
    super.initState();
    _inviteOnly = widget.initialInviteOnly;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invite settings'),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
        isExpanded: true,
          value: _expiry,
          decoration: const InputDecoration(labelText: 'Link expiry'),
          items: const ['1 day', '7 days', '30 days', 'Never']
              .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: (v) => setState(() => _expiry = v ?? _expiry),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
        isExpanded: true,
          value: _limit,
          decoration: const InputDecoration(labelText: 'Usage limit'),
          items: const ['1 use', '5 uses', '25 uses', '100 uses', 'Unlimited']
              .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: (v) => setState(() => _limit = v ?? _limit),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Require join approval'),
          subtitle: const Text('New applicants wait for an authorised moderator.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
          value: _approval,
          onChanged: (v) => setState(() => _approval = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Single-use invite'),
          value: _singleUse,
          onChanged: (v) => setState(() {
            _singleUse = v;
            if (v) _limit = '1 use';
          }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Invite-only community'),
          subtitle: const Text('Only accepted invites or approved applications can join.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
          value: _inviteOnly,
          onChanged: (v) => setState(() => _inviteOnly = v),
        ),
        const _WritePendingNote(
          text: 'These settings configure the invite UX only. A server-issued secret link is not generated in this UI pass.',
        ),
      ],
    ))),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'expiry': _expiry,
          'limit': _limit,
          'approval': _approval,
          'single_use': _singleUse,
          'invite_only': _inviteOnly,
        }),
        child: const Text('Review settings'),
      ),
    ],
  );
}

class _InvitePolicyCard extends StatelessWidget {
  const _InvitePolicyCard({required this.inviteOnly, required this.onChanged});
  final bool inviteOnly;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(13),
      child: Row(children: [
        Icon(inviteOnly ? Icons.lock_outline : Icons.public_outlined, color: KomnivoTheme.cyan),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(inviteOnly ? 'Invite-only community' : 'Public community', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          Text(inviteOnly ? 'Membership is restricted by current invite-only policy.' : 'Public discovery is enabled; invite links may still apply limits.',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        ])),
        Switch(value: inviteOnly, onChanged: onChanged),
      ]),
    ),
  );
}

class _InviteDraftCard extends StatelessWidget {
  const _InviteDraftCard({required this.draft, required this.onDiscard});
  final Map<String, dynamic> draft;
  final VoidCallback onDiscard;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.edit_note_rounded, color: KomnivoTheme.cyan),
          SizedBox(width: 7),
          Expanded(child: Text('Invite configuration draft', style: TextStyle(fontWeight: FontWeight.w900))),
          _StatusTag(label: 'UNSAVED', tone: _TagTone.warning),
        ]),
        const SizedBox(height: 8),
        _DetailRow(label: 'Expiry', value: draft['expiry'].toString()),
        _DetailRow(label: 'Usage', value: draft['limit'].toString()),
        _DetailRow(label: 'Approval', value: draft['approval'] == true ? 'Required' : 'Not required'),
        _DetailRow(label: 'Single use', value: draft['single_use'] == true ? 'Yes' : 'No'),
        _DetailRow(label: 'Invite-only', value: draft['invite_only'] == true ? 'On' : 'Off'),
        const _WritePendingNote(text: 'The invite is not issued. No token or shareable URL exists for this draft.'),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onDiscard, child: const Text('Discard draft')),
        ),
      ]),
    ),
  );
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.invite, required this.onRevoke});
  final Map<String, dynamic> invite;
  final VoidCallback onRevoke;
  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(invite['created_at']?.toString() ?? '');
    final expiry = DateTime.tryParse(invite['expires_at']?.toString() ?? '');
    final uses = (invite['uses'] as num?)?.toInt() ?? 0;
    final maxUses = (invite['max_uses'] as num?)?.toInt();
    final expired = expiry != null && expiry.isBefore(DateTime.now());
    final exhausted = maxUses != null && uses >= maxUses;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.link_rounded, color: KomnivoTheme.cyan),
            const SizedBox(width: 8),
            const Expanded(child: Text('Community invite', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11))),
            _StatusTag(label: expired ? 'EXPIRED' : exhausted ? 'USED UP' : 'NOT EXPIRED', tone: expired || exhausted ? _TagTone.warning : _TagTone.neutral),
          ]),
          const SizedBox(height: 8),
          _DetailRow(label: 'Usage', value: maxUses == null ? '$uses · unlimited' : '$uses / $maxUses'),
          _DetailRow(label: 'Created', value: created == null ? 'Unavailable' : _dateLabel(created)),
          _DetailRow(label: 'Expires', value: expiry == null ? 'Never' : _dateLabel(expiry)),
          const _PrivacyNote(text: 'Invite secrets are not displayed from their stored hash. This status reflects expiry and usage only; the current schema does not expose revoke state. Revoke and rotation require a privileged server operation.'),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onRevoke,
              icon: const Icon(Icons.link_off_outlined, size: 14),
              label: const Text('Prepare revoke'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _InviteRevokeDraftCard extends StatelessWidget {
  const _InviteRevokeDraftCard({required this.invite, required this.onDiscard});
  final Map<String, dynamic> invite;
  final VoidCallback onDiscard;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.link_off_outlined, color: KomnivoTheme.danger),
          SizedBox(width: 7),
          Expanded(child: Text('Invite revoke review', style: TextStyle(fontWeight: FontWeight.w900))),
          _StatusTag(label: 'NOT REVOKED', tone: _TagTone.warning),
        ]),
        const SizedBox(height: 8),
        _DetailRow(label: 'Invite', value: invite['id'].toString().substring(0, 8)),
        _DetailRow(label: 'Used', value: (invite['uses'] ?? 0).toString()),
        const _WritePendingNote(text: 'Revoke confirmation is prepared. The invite remains usable until a privileged server revoke operation is connected.'),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onDiscard, child: const Text('Discard review')),
        ),
      ]),
    ),
  );
}

class _AppealsTab extends StatefulWidget {
  const _AppealsTab({required this.canReviewAppeals});
  final bool canReviewAppeals;
  @override
  State<_AppealsTab> createState() => _AppealsTabState();
}

class _AppealsTabState extends State<_AppealsTab> {
  final _reference = TextEditingController();
  final _details = TextEditingController();
  final _evidence = TextEditingController();
  String _reason = 'Incorrect or disproportionate action';
  Map<String, String>? _draft;

  @override
  void dispose() {
    _reference.dispose();
    _details.dispose();
    _evidence.dispose();
    super.dispose();
  }

  void _prepareAppeal() {
    if (_reference.text.trim().isEmpty || _details.text.trim().length < 10) {
      showMessage(context, 'Add the decision reference and at least 10 characters of context.');
      return;
    }
    setState(() => _draft = {
      'reference': _reference.text.trim(),
      'reason': _reason,
      'details': _details.text.trim(),
      'evidence': _evidence.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
    children: [
      const _PageHeading(
        title: 'Appeals',
        subtitle: 'Request a review of a moderation decision with context and evidence.',
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Prepare an appeal', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            TextField(
              controller: _reference,
              decoration: const InputDecoration(
                labelText: 'Moderation decision reference',
                hintText: 'Enter the decision ID shown in your notice',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _reason,
              decoration: const InputDecoration(labelText: 'Appeal reason'),
              items: const [
                'Incorrect or disproportionate action',
                'New evidence',
                'Context was not considered',
                'Identity or account mix-up',
                'Other',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) => setState(() => _reason = v ?? _reason),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _details,
              onChanged: (_) => setState(() {}),
              minLines: 4,
              maxLines: 6,
              maxLength: 1500,
              decoration: const InputDecoration(
                labelText: 'Explain why the decision should be reviewed',
                hintText: 'Describe the context and what outcome you are requesting.',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _evidence,
              decoration: const InputDecoration(
                labelText: 'Evidence reference (optional)',
                hintText: 'Evidence ID or approved evidence link',
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _reference.text.trim().isNotEmpty && _details.text.trim().length >= 10
                  ? _prepareAppeal
                  : null,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Review appeal'),
            ),
          ]),
        ),
      ),
      if (_draft != null) ...[
        const SizedBox(height: 10),
        _AppealDraftCard(
          draft: _draft!,
          onDiscard: () => setState(() => _draft = null),
        ),
      ],
      const SizedBox(height: 16),
      const _SectionHeader(
        title: 'My appeal history',
        subtitle: 'Only submitted records will appear here. Drafts are not treated as lodged appeals.',
      ),
      const _PendingFeatureCard(
        title: 'No appeal records available',
        detail: 'The current database has no appeal submission table. Your review draft stays on this screen until the Batch 4 appeal API and persistence model are connected.',
        icon: Icons.history_outlined,
      ),
      if (widget.canReviewAppeals) ...[
        const SizedBox(height: 16),
        const _SectionHeader(
          title: 'Moderator review queue',
          subtitle: 'Reviewer decisions must include scope, evidence and a reasoned outcome.',
        ),
        const _PendingFeatureCard(
          title: 'Appeal queue not connected',
          detail: 'No appeal records are fabricated. Assigned reviewer, uphold / modify / revoke decision, response and audit trail will be connected to the Batch 4 appeal model.',
          icon: Icons.balance_outlined,
        ),
      ],
    ],
  );
}

class _AppealDraftCard extends StatelessWidget {
  const _AppealDraftCard({required this.draft, required this.onDiscard});
  final Map<String, String> draft;
  final VoidCallback onDiscard;
  @override
  Widget build(BuildContext context) => Card(
    color: KomnivoTheme.surfaceRaised,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.balance_outlined, color: KomnivoTheme.cyan),
          SizedBox(width: 7),
          Expanded(child: Text('Appeal review draft', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11))),
          _StatusTag(label: 'NOT SUBMITTED', tone: _TagTone.warning),
        ]),
        const SizedBox(height: 8),
        _DetailRow(label: 'Decision', value: draft['reference'] ?? ''),
        _DetailRow(label: 'Reason', value: draft['reason'] ?? ''),
        _DetailRow(label: 'Evidence', value: (draft['evidence'] ?? '').isEmpty ? 'Not attached' : draft['evidence']!),
        const SizedBox(height: 5),
        Text(draft['details'] ?? '', style: const TextStyle(fontSize: 10, height: 1.4)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onDiscard, child: const Text('Discard draft')),
        ),
        const _WritePendingNote(text: 'This appeal is prepared locally only. It has not been submitted or added to moderation history.'),
      ]),
    ),
  );
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

  Future<void> _prepareAction({
    String? memberName,
    String? targetUserId,
    String? messageId,
  }) async {
    List<Map<String, dynamic>> channels = [];
    try {
      channels = await widget.source.loadChannelPolicies(widget.communityId);
    } catch (_) {
      channels = [];
    }
    if (!mounted) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ModerationActionDialog(
        memberName: memberName,
        targetUserId: targetUserId,
        messageId: messageId,
        availableChannels: channels,
      ),
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
      final shown = _view == 'Open' ? open : resolved;
      return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
        Row(children: [
          const Expanded(child: _PageHeading(title: 'Moderation centre', subtitle: 'Review reports and prepare scoped, reasoned actions.')),
          FilledButton.icon(onPressed: _prepareAction, icon: const Icon(Icons.gavel_outlined, size: 16), label: const Text('New action')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 7, children: [
          ChoiceChip(label: Text('Open (' + open.length.toString() + ')'), selected: _view == 'Open', onSelected: (_) => setState(() => _view = 'Open')),
          ChoiceChip(label: Text('Resolved (' + resolved.length.toString() + ')'), selected: _view == 'Resolved', onSelected: (_) => setState(() => _view = 'Resolved')),

        ]),
        const SizedBox(height: 10),
        if (_draft != null) ...[
          _ModerationDraftCard(draft: _draft!, onDiscard: () => setState(() => _draft = null)),
          const SizedBox(height: 10),
        ],
        if (shown.isEmpty)
          _EmptyState(
            icon: _view == 'Open' ? Icons.inbox_outlined : Icons.task_alt_outlined,
            title: _view == 'Open' ? 'No open reports' : 'No resolved reports',
            body: reports.isEmpty ? 'No report records are visible for this community.' : 'There are no reports in this view.',
          )
        else
          ...shown.map((report) => _ModerationReportCard(
            report: report,
            onReview: () => _prepareAction(
              memberName: report['target_user_id'] == null ? null : 'reported member',
              targetUserId: report['target_user_id']?.toString(),
              messageId: report['message_id']?.toString(),
            ),
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
  const _ModerationActionDialog({
    this.memberName,
    this.targetUserId,
    this.messageId,
    this.availableChannels = const [],
  });
  final String? memberName;
  final String? targetUserId;
  final String? messageId;
  final List<Map<String, dynamic>> availableChannels;
  @override
  State<_ModerationActionDialog> createState() => _ModerationActionDialogState();
}

class _ModerationActionDialogState extends State<_ModerationActionDialog> {
  final _reason = TextEditingController();
  final _target = TextEditingController();
  final _message = TextEditingController();
  String _action = 'Warn';
  String _scope = 'Community';
  String _duration = '24 hours';
  String _channel = '';
  static const _actions = ['Warn', 'Delete message', 'Timeout', 'Mute', 'Channel restriction', 'Kick', 'Ban', 'Unban'];
  bool get _needsDuration => const {'Timeout', 'Mute', 'Ban'}.contains(_action);
  bool get _needsChannel => _action == 'Channel restriction' || _scope == 'Selected channel';
  bool get _needsMessage => _action == 'Delete message' || _scope == 'Specific message';
  bool get _hasTarget => (widget.targetUserId ?? _target.text.trim()).isNotEmpty;
  @override
  void dispose() {
    _reason.dispose();
    _target.dispose();
    _message.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Moderation action'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (widget.memberName != null)
        Align(alignment: Alignment.centerLeft, child: Text('Target: ' + widget.memberName!, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)))
      else ...[
        TextField(
          controller: _target,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Target member ID / reference (required)',
            hintText: 'Select a member from the directory or enter the member reference',
          ),
        ),
        const SizedBox(height: 10),
      ],
      DropdownButtonFormField<String>(
        isExpanded: true,
        value: _action, decoration: const InputDecoration(labelText: 'Action'),
        items: _actions.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _action = v ?? _action),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        isExpanded: true,
        value: _scope, decoration: const InputDecoration(labelText: 'Scope'),
        items: const ['Community', 'Selected channel', 'Specific message'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() => _scope = v ?? _scope),
      ),
      if (_needsChannel) ...[
        const SizedBox(height: 10),
        if (widget.availableChannels.isEmpty)
          const _PrivacyNote(text: 'No channel list is available to this moderator. Select a channel from the community list before preparing a channel-scoped action.')
        else
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: _channel.isEmpty ? null : _channel,
            decoration: const InputDecoration(labelText: 'Target channel (required)'),
            items: widget.availableChannels.map((channel) {
              final id = channel['id']?.toString() ?? '';
              final name = channel['name']?.toString() ?? 'Channel';
              return DropdownMenuItem(value: id, child: Text('#$name'));
            }).toList(),
            onChanged: (value) => setState(() => _channel = value ?? ''),
          ),
      ],
      if (_needsMessage) ...[
        const SizedBox(height: 10),
        TextField(
          controller: _message,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Message ID (required)',
            hintText: 'Reference the exact message to review or delete',
          ),
        ),
      ],
      if (_needsDuration) ...[
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
        isExpanded: true,
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
        onPressed: !_hasTarget ||
            _reason.text.trim().length < 8 ||
            (_needsChannel && _channel.trim().isEmpty) ||
            (_needsMessage && (widget.messageId ?? _message.text.trim()).isEmpty)
            ? null
            : () => Navigator.pop(context, {
                'action': _action,
                'scope': _scope,
                'target_user_id': widget.targetUserId ?? _target.text.trim(),
                'message_id': widget.messageId ?? (_needsMessage ? _message.text.trim() : null),
                'duration': _needsDuration ? _duration : null,
                'channel_id': _needsChannel ? _channel.trim() : null,
                'reason': _reason.text.trim(),
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
      _DetailRow(label: 'Target', value: draft['target_user_id'] == null ? 'Not selected' : 'Member selected'),
       if (draft['channel_id'] != null) _DetailRow(label: 'Channel', value: 'Channel selected'),
       if (draft['message_id'] != null) _DetailRow(label: 'Message', value: 'Message selected'),
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
  String _messageWindow = '10 seconds';
  String _mentionWindow = '1 minute';
  String _duration = '30 minutes';
  String _scope = 'All text channels';
  String _raidTrigger = 'Message flood';
  bool _pauseInvites = true;
  bool _restrictLinks = true;
  bool _lockdown = false;
  Map<String, dynamic>? _safetyDraft;

  @override
  void initState() {
    super.initState();
    _future = widget.source.loadChannelPolicies(widget.communityId);
  }

  @override
  void dispose() {
    _messageRate.dispose();
    _mentionRate.dispose();
    super.dispose();
  }

  void _refresh() => setState(
    () => _future = widget.source.loadChannelPolicies(widget.communityId),
  );

  void _invalidateDraft() {
    if (_safetyDraft != null) setState(() => _safetyDraft = null);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _LoadFailure(
          title: 'Channel safety settings could not be loaded',
          details: snapshot.error.toString(),
          onRetry: _refresh,
        );
      }
      final channels = snapshot.data ?? const <Map<String, dynamic>>[];
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          const _PageHeading(
            title: 'Community safety',
            subtitle: 'Deterministic anti-spam controls and temporary raid response.',
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Message and mention limits', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 9),
                  TextField(
                    controller: _messageRate,
                    onChanged: (_) => _invalidateDraft(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Message burst limit',
                      hintText: 'Messages per time window',
                      helperText: 'Maximum messages allowed before server rate limiting.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: _messageWindow,
                    decoration: const InputDecoration(labelText: 'Message rate window'),
                    items: const ['5 seconds', '10 seconds', '30 seconds', '1 minute', '5 minutes']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                    onChanged: (v) => setState(() {
                      _messageWindow = v ?? _messageWindow;
                      _safetyDraft = null;
                    }),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _mentionRate,
                    onChanged: (_) => _invalidateDraft(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Mention burst limit',
                      hintText: 'Mentions per time window',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: _mentionWindow,
                    decoration: const InputDecoration(labelText: 'Mention rate window'),
                    items: const ['10 seconds', '30 seconds', '1 minute', '5 minutes', '15 minutes']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                    onChanged: (v) => setState(() {
                      _mentionWindow = v ?? _mentionWindow;
                      _safetyDraft = null;
                    }),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Restrict links for new members'),
                    value: _restrictLinks,
                    onChanged: (v) => setState(() {
                      _restrictLinks = v;
                      _safetyDraft = null;
                    }),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Pause new invite creation during lockdown'),
                    value: _pauseInvites,
                    onChanged: (v) => setState(() {
                      _pauseInvites = v;
                      _safetyDraft = null;
                    }),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Expanded(child: Text('Temporary raid lockdown', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
                    _StatusTag(
                      label: _lockdown ? 'DRAFT ON' : 'INACTIVE',
                      tone: _lockdown ? _TagTone.warning : _TagTone.neutral,
                    ),
                  ]),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Prepare lockdown'),
                    subtitle: const Text(
                      'Time-bound response to unusual join or message activity.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 9),
                    ),
                    value: _lockdown,
                    onChanged: (v) => setState(() {
                      _lockdown = v;
                      _safetyDraft = null;
                    }),
                  ),
                  if (_lockdown) ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _raidTrigger,
                      decoration: const InputDecoration(labelText: 'Lockdown trigger'),
                      items: const ['Join spike', 'Message flood', 'Mention flood', 'Manual response']
                          .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                      onChanged: (v) => setState(() {
                        _raidTrigger = v ?? _raidTrigger;
                        _safetyDraft = null;
                      }),
                    ),
                    const SizedBox(height: 9),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _scope,
                      decoration: const InputDecoration(labelText: 'Scope'),
                      items: const ['All text channels', 'Selected channels', 'New members only']
                          .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                      onChanged: (v) => setState(() {
                        _scope = v ?? _scope;
                        _safetyDraft = null;
                      }),
                    ),
                    const SizedBox(height: 9),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _duration,
                      decoration: const InputDecoration(labelText: 'Duration'),
                      items: const ['15 minutes', '30 minutes', '1 hour', '6 hours']
                          .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                      onChanged: (v) => setState(() {
                        _duration = v ?? _duration;
                        _safetyDraft = null;
                      }),
                    ),
                  ],
                  const SizedBox(height: 9),
                  FilledButton.icon(
                    onPressed: _prepareSafetyDraft,
                    icon: const Icon(Icons.security_outlined),
                    label: const Text('Review safety policy'),
                  ),
                  if (_safetyDraft != null) ...[
                    const SizedBox(height: 10),
                    _SafetyPolicyDraftCard(draft: _safetyDraft!),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _SectionHeader(
            title: 'Current channel safeguards',
            subtitle: 'Read-only status from saved channel settings. Edit them in Channel Studio.',
          ),
          if (channels.isEmpty)
            const _EmptyState(
              icon: Icons.tune_outlined,
              title: 'No channel settings found',
              body: 'Saved channel safety rules will appear here.',
            )
          else
            ...channels.map((channel) => _ChannelPolicyCard(
              channel: channel,
              onOpen: widget.onOpenChannelStudio,
            )),
        ],
      );
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
    setState(() => _safetyDraft = {
      'message_limit': _messageRate.text.trim().isEmpty ? 'Disabled' : _messageRate.text.trim(),
      'message_window': _messageWindow,
      'mention_limit': _mentionRate.text.trim().isEmpty ? 'Disabled' : _mentionRate.text.trim(),
      'mention_window': _mentionWindow,
      'restrict_links': _restrictLinks,
      'pause_invites': _pauseInvites,
      'lockdown': _lockdown,
      'raid_trigger': _lockdown ? _raidTrigger : 'Not set',
      'scope': _lockdown ? _scope : 'Not set',
      'duration': _lockdown ? _duration : 'Not set',
    });
  }
}

class _SafetyPolicyDraftCard extends StatelessWidget {
  const _SafetyPolicyDraftCard({required this.draft});
  final Map<String, dynamic> draft;
  @override
  Widget build(BuildContext context) => Card(
    color: KomnivoTheme.surfaceRaised,
    child: Padding(
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.fact_check_outlined, color: KomnivoTheme.cyan, size: 17),
            SizedBox(width: 7),
            Expanded(child: Text('Safety policy review', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900))),
            _StatusTag(label: 'NOT APPLIED', tone: _TagTone.warning),
          ]),
          const SizedBox(height: 8),
          _DetailRow(label: 'Message rate', value: draft['message_limit'].toString() + ' / ' + draft['message_window'].toString()),
          _DetailRow(label: 'Mention rate', value: draft['mention_limit'].toString() + ' / ' + draft['mention_window'].toString()),
          _DetailRow(label: 'New-member links', value: draft['restrict_links'] == true ? 'Restricted' : 'Allowed'),
          _DetailRow(label: 'Pause invites', value: draft['pause_invites'] == true ? 'During lockdown' : 'No'),
          _DetailRow(label: 'Raid response', value: draft['lockdown'] == true ? draft['raid_trigger'].toString() : 'Off'),
          if (draft['lockdown'] == true) ...[
            _DetailRow(label: 'Scope', value: draft['scope'].toString()),
            _DetailRow(label: 'Duration', value: draft['duration'].toString()),
          ],
          const _WritePendingNote(
            text: 'This policy is ready for backend review. No rate limit, link restriction or lockdown has been activated.',
          ),
        ],
      ),
    ),
  );
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
