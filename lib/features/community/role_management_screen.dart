import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class RoleManagementScreen extends StatefulWidget {
  const RoleManagementScreen({super.key, required this.communityId, required this.communityName});
  final String communityId;
  final String communityName;

  @override
  State<RoleManagementScreen> createState() => _RoleManagementScreenState();
}

class _RoleManagementScreenState extends State<RoleManagementScreen> {
  final _db = Supabase.instance.client;
  late Future<_RoleData> _future;
  bool _busy = false;

  static const permissions = <String, String>{
    'community.view': 'View community',
    'community.manage_settings': 'Edit community settings',
    'community.manage_structure': 'Manage channels and categories',
    'community.manage_members': 'Manage members',
    'community.manage_invites': 'Manage invites',
    'community.manage_roles': 'Create and assign roles',
    'community.manage_permissions': 'Manage channel overrides',
    'community.audit.read': 'Read role history',
    'channel.view': 'View channels',
    'channel.read_history': 'Read message history',
    'channel.send_messages': 'Send messages',
    'channel.react': 'React to messages',
    'channel.manage_messages': 'Moderate messages',
  };

  static const staffRoles = <String, String>{
    'competition_manager': 'Competition Manager',
    'tournament_director': 'Tournament Director',
    'match_operator': 'Match Operator',
    'referee': 'Referee',
    'result_reviewer': 'Result Reviewer',
    'dispute_reviewer': 'Dispute Reviewer',
    'support_staff': 'Support Staff',
    'caster': 'Caster',
    'streamer': 'Streamer',
  };

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _refresh() {
    if (mounted) setState(() => _future = _load());
  }

  Future<bool> _has(String key, {String? channelId}) async =>
      await _db.rpc('has_permission', params: {
        'p_permission_key': key,
        'p_scope_type': 'community',
        'p_scope_id': widget.communityId,
        'p_related_id': null,
        'p_resource_id': channelId,
      }) == true;

  int _baseRank(String? role) => switch (role) {
        'owner' => 1000000,
        'admin' => 200,
        'moderator' => 100,
        'organiser' => 90,
        _ => 0,
      };

  Future<_RoleData> _load() async {
    final roles = List<Map<String, dynamic>>.from(await _db.from('community_roles')
        .select('id,name,description,colour,position,is_system,preset_key,archived_at')
        .eq('community_id', widget.communityId).order('position', ascending: false));
    final ids = roles.map((e) => e['id'].toString()).toList();
    final rolePermissions = ids.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(await _db.from('role_permissions')
            .select('role_id,permission_key,allowed').inFilter('role_id', ids));
    final members = List<Map<String, dynamic>>.from(await _db.from('community_members')
        .select('user_id,role,joined_at,profiles(display_name,username)')
        .eq('community_id', widget.communityId).order('joined_at'));
    final assignments = List<Map<String, dynamic>>.from(await _db.from('community_member_roles')
        .select('user_id,role_id').eq('community_id', widget.communityId));
    final channels = List<Map<String, dynamic>>.from(await _db.from('channels')
        .select('id,name,kind,is_private,category_id').eq('community_id', widget.communityId)
        .isFilter('event_id', null).isFilter('archived_at', null).order('name'));
    final userId = _db.auth.currentUser?.id ?? '';
    final mine = members.where((m) => m['user_id'] == userId).firstOrNull;
    var rank = _baseRank(mine?['role']?.toString());
    for (final link in assignments.where((a) => a['user_id'] == userId)) {
      final role = roles.where((r) => r['id'] == link['role_id']).firstOrNull;
      if (role == null || role['archived_at'] != null) continue;
      final canManage = rolePermissions.any((p) => p['role_id'] == role['id'] &&
          p['permission_key'] == 'community.manage_roles' && p['allowed'] == true);
      if (canManage) {
        final position = (role['position'] as num?)?.toInt() ?? 0;
        if (position > rank) rank = position;
      }
    }
    final audit = await _has('community.audit.read');
    final history = audit
        ? List<Map<String, dynamic>>.from(await _db.from('community_role_history')
            .select('id,role_id,subject_user_id,actor_user_id,action,before_state,after_state,created_at')
            .eq('community_id', widget.communityId).order('created_at', ascending: false).limit(60))
        : <Map<String, dynamic>>[];
    return _RoleData(roles, rolePermissions, members, assignments, channels, history, audit, rank, userId);
  }

  Future<void> _perform(Future<void> Function() work, String message) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
      if (!mounted) return;
      _refresh();
      showMessage(context, message);
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editRole(_RoleData data, {Map<String, dynamic>? role}) async {
    if (!await _has('community.manage_roles')) {
      if (mounted) showMessage(context, 'You cannot manage community roles.');
      return;
    }
    if (role?['is_system'] == true) {
      showMessage(context, 'Built-in roles are locked. Create a custom role instead.');
      return;
    }
    final name = TextEditingController(text: role?['name']?.toString() ?? '');
    final description = TextEditingController(text: role?['description']?.toString() ?? '');
    final colour = TextEditingController(text: role?['colour']?.toString() ?? '#4A90E2');
    final position = TextEditingController(text: role?['position']?.toString() ??
        (data.rank - 10).clamp(1, 999999).toString());
    final selected = <String, String>{};
    if (role != null) {
      for (final item in data.permissions.where((p) => p['role_id'] == role['id'])) {
        selected[item['permission_key'].toString()] = item['allowed'] == true ? 'allow' : 'deny';
      }
    }
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text(role == null ? 'Create role' : 'Edit role'),
        content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, maxLength: 40, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: description, maxLength: 300, maxLines: 2, decoration: const InputDecoration(labelText: 'Description')),
            TextField(controller: colour, maxLength: 7, decoration: const InputDecoration(labelText: 'Colour HEX', hintText: '#4A90E2')),
            TextField(controller: position, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Hierarchy position', helperText: 'Your authority rank: ${data.rank}. This role must be lower.')),
            const SizedBox(height: 12),
            const Align(alignment: Alignment.centerLeft, child: Text('Permission rules', style: TextStyle(fontWeight: FontWeight.w900))),
            const Text('Inherit leaves the default/other roles in control. Deny blocks an action. Allow grants only what you already have.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
            const SizedBox(height: 8),
            ...permissions.entries.map((entry) => Row(children: [
              Expanded(child: Text(entry.value, style: const TextStyle(fontSize: 11))),
              SizedBox(width: 112, child: DropdownButton<String>(
                isExpanded: true,
                value: selected[entry.key] ?? 'inherit',
                items: const [
                  DropdownMenuItem(value: 'inherit', child: Text('Inherit')),
                  DropdownMenuItem(value: 'allow', child: Text('Allow')),
                  DropdownMenuItem(value: 'deny', child: Text('Deny')),
                ],
                onChanged: (value) => update(() => selected[entry.key] = value ?? 'inherit'),
              )),
            ])),
          ],
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final pos = int.tryParse(position.text.trim());
            if (name.text.trim().length < 2 ||
                !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(colour.text.trim()) ||
                pos == null || pos < 1 || pos >= data.rank) {
              showMessage(context, 'Check name, HEX colour and hierarchy position (must be lower than your rank).');
              return;
            }
            Navigator.pop(dialogContext, true);
          }, child: const Text('Save role')),
        ],
      )),
    );
    if (save == true && mounted) {
      await _perform(() async {
        final values = <String, dynamic>{
          'community_id': widget.communityId,
          'name': name.text.trim(),
          'description': description.text.trim(),
          'colour': colour.text.trim().toUpperCase(),
          'position': int.parse(position.text.trim()),
        };
        final saved = role == null
            ? await _db.from('community_roles').insert(values).select().single()
            : await _db.from('community_roles').update({
                'name': values['name'], 'description': values['description'],
                'colour': values['colour'], 'position': values['position'],
              }).eq('community_id', widget.communityId).eq('id', role['id']).select().single();
        final id = saved['id'].toString();
        for (final key in permissions.keys) {
          final state = selected[key] ?? 'inherit';
          if (state == 'inherit') {
            await _db.from('role_permissions').delete().eq('role_id', id).eq('permission_key', key);
          } else {
            await _db.from('role_permissions').upsert({
              'role_id': id, 'permission_key': key, 'allowed': state == 'allow',
            }, onConflict: 'role_id,permission_key');
          }
        }
      }, 'Role saved.');
    }
    name.dispose(); description.dispose(); colour.dispose(); position.dispose();
  }

  Future<void> _archive(Map<String, dynamic> role) async {
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Archive role?'),
      content: Text('${role['name']} will be removed from assignments. Its audit record remains.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Archive')),
      ],
    ));
    if (ok == true) {
      await _perform(() async => _db.rpc('archive_community_role', params: {'p_role_id': role['id']}), 'Role archived.');
    }
  }

  String _memberName(Map<String, dynamic> member) {
    final p = member['profiles'] is Map ? Map<String, dynamic>.from(member['profiles']) : <String, dynamic>{};
    return p['display_name']?.toString() ?? p['username']?.toString() ?? 'Member';
  }

  Future<void> _assign(_RoleData data, Map<String, dynamic> member) async {
    if (!await _has('community.manage_roles')) {
      if (mounted) showMessage(context, 'You cannot assign community roles.');
      return;
    }
    final userId = member['user_id'].toString();
    final current = data.assignments.where((a) => a['user_id'] == userId)
        .map((a) => a['role_id'].toString()).toSet();
    final available = data.roles.where((r) => r['archived_at'] == null && r['preset_key'] != 'owner').toList();
    final selected = Set<String>.from(current);
    final save = await showDialog<bool>(context: context, builder: (dialogContext) =>
      StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text('Roles for ${_memberName(member)}'),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: available.map((r) {
            final id = r['id'].toString();
            return CheckboxListTile(
              value: selected.contains(id),
              title: Text(r['name'].toString()),
              subtitle: Text('Position ${r['position']}'),
              onChanged: (yes) => update(() { if (yes == true) { selected.add(id); } else { selected.remove(id); } }),
            );
          }).toList(),
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save')),
        ],
      )));
    if (save != true || !mounted) return;
    await _perform(() async {
      for (final id in current.difference(selected)) {
        await _db.from('community_member_roles').delete()
            .eq('community_id', widget.communityId).eq('user_id', userId).eq('role_id', id);
      }
      for (final id in selected.difference(current)) {
        await _db.from('community_member_roles').insert({
          'community_id': widget.communityId, 'user_id': userId, 'role_id': id,
          'assigned_by': _db.auth.currentUser!.id,
        });
      }
    }, 'Member roles updated.');
  }

  Widget _roles(_RoleData data) {
    final active = data.roles.where((r) => r['archived_at'] == null);
    final archived = data.roles.where((r) => r['archived_at'] != null);
    return ListView(padding: const EdgeInsets.all(14), children: [
      Row(children: [
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Community roles', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          Text('Owner, Admin, Moderator and Organiser presets are locked.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        ])),
        FilledButton.icon(onPressed: _busy ? null : () => _editRole(data), icon: const Icon(Icons.add, size: 16), label: const Text('Create')),
      ]),
      const SizedBox(height: 12),
      ...active.map((r) {
        final system = r['is_system'] == true;
        final list = data.permissions.where((p) => p['role_id'] == r['id']);
        final grants = list.where((p) => p['allowed'] == true).length;
        final count = data.assignments.where((a) => a['role_id'] == r['id']).length;
        return Card(child: ListTile(
          leading: CircleAvatar(backgroundColor: _colour(r['colour']?.toString()), child: Icon(system ? Icons.verified_user_outlined : Icons.shield_outlined)),
          title: Row(children: [
            Expanded(child: Text(r['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w900))),
            if (system) const Chip(label: Text('BUILT-IN', style: TextStyle(fontSize: 8))),
          ]),
          subtitle: Text('Position ${r['position']} · ${count} assigned · ${grants} allowed actions\n${r['description'] ?? ''}', style: const TextStyle(fontSize: 10)),
          trailing: system ? const Icon(Icons.lock_outline) : PopupMenuButton<String>(
            onSelected: (v) { if (v == 'edit') _editRole(data, role: r); if (v == 'archive') _archive(r); },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'archive', child: Text('Archive')),
            ],
          ),
        ));
      }),
      if (archived.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('Archived roles', style: TextStyle(fontWeight: FontWeight.w900)),
        ...archived.map((r) => ListTile(enabled: false, leading: const Icon(Icons.archive_outlined), title: Text(r['name'].toString()), subtitle: const Text('Archived · not assignable'))),
      ],
      const _InfoBox(title: 'Hierarchy protection', body: 'The database blocks editing, assigning or archiving a role at or above the actor’s own authority. Owner cannot be delegated.'),
    ]);
  }

  Color _colour(String? value) {
    try { return Color(int.parse('FF${(value ?? '#4A90E2').replaceFirst('#', '')}', radix: 16)); }
    catch (_) { return KomnivoTheme.cyan; }
  }

  Widget _members(_RoleData data) => ListView(padding: const EdgeInsets.all(14), children: [
    const Text('Member roles', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
    const Text('A member can hold multiple Community roles. These do not replace Team or Event roles.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
    const SizedBox(height: 10),
    ...data.members.map((m) {
      final id = m['user_id'].toString();
      final rows = data.assignments.where((a) => a['user_id'] == id);
      final names = rows.map((a) => data.roles.where((r) => r['id'] == a['role_id']).firstOrNull?['name']?.toString()).whereType<String>();
      return Card(child: ListTile(
        leading: CircleAvatar(child: Text(_memberName(m).isEmpty ? '?' : _memberName(m)[0].toUpperCase())),
        title: Text(_memberName(m), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('Membership: ${m['role']} · ${names.isEmpty ? 'No additional roles' : names.join(' / ')}', style: const TextStyle(fontSize: 10)),
        trailing: IconButton(tooltip: 'Assign roles', onPressed: _busy ? null : () => _assign(data, m), icon: const Icon(Icons.manage_accounts_outlined)),
      ));
    }),
    const _InfoBox(title: 'Team and Event are separate', body: 'Team Captain, Team Member and Substitute remain in team_members. Spectator, registration approval and match check-in remain event participation states; this editor never writes those records.'),
  ]);

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 5,
    child: Scaffold(
      appBar: AppBar(title: Text(widget.communityName), bottom: const TabBar(isScrollable: true, tabs: [
        Tab(text: 'Roles'), Tab(text: 'Members'), Tab(text: 'Preview'), Tab(text: 'Event staff'), Tab(text: 'Trust & history'),
      ])),
      body: FutureBuilder<_RoleData>(
        future: _future,
        builder: (context, s) {
          if (s.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 32), const SizedBox(height: 8),
            const Text('Role management could not be loaded', style: TextStyle(fontWeight: FontWeight.w900)),
            Text(s.error.toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: KomnivoTheme.muted)),
            OutlinedButton(onPressed: _refresh, child: const Text('Retry')),
          ])));
          final d = s.data!;
          return TabBarView(children: [
            _roles(d),
            _members(d),
            _PreviewPanel(communityId: widget.communityId, roles: d.roles.where((r) => r['archived_at'] == null).toList(), members: d.members, channels: d.channels),
            _EventStaffPanel(communityId: widget.communityId, labels: staffRoles),
            _TrustHistoryPanel(userId: d.userId, rows: d.history, canRead: d.canReadHistory),
          ]);
        },
      ),
    ),
  );
}

class _RoleData {
  const _RoleData(this.roles, this.permissions, this.members, this.assignments, this.channels, this.history, this.canReadHistory, this.rank, this.userId);
  final List<Map<String, dynamic>> roles, permissions, members, assignments, channels, history;
  final bool canReadHistory;
  final int rank;
  final String userId;
}

class _PreviewPanel extends StatefulWidget {
  const _PreviewPanel({required this.communityId, required this.roles, required this.members, required this.channels});
  final String communityId;
  final List<Map<String, dynamic>> roles, members, channels;
  @override
  State<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<_PreviewPanel> {
  String _mode = 'role';
  String? _roleId, _userId, _channelId, _error;
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;

  Future<void> _runPreview() async {
    if ((_mode == 'role' && _roleId == null) || (_mode == 'member' && _userId == null)) return;
    setState(() { _loading = true; _error = null; });
    try {
      final value = await Supabase.instance.client.rpc('preview_community_role_permissions', params: {
        'p_community_id': widget.communityId,
        'p_role_id': _mode == 'role' ? _roleId : null,
        'p_user_id': _mode == 'member' ? _userId : null,
        'p_channel_id': _channelId,
      });
      if (mounted) setState(() => _results = List<Map<String, dynamic>>.from(value as List));
    } catch (e) { if (mounted) setState(() => _error = e.toString()); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(14), children: [
    const Text('Permission preview', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
    const Text('Simulate current effective actions before saving a role or assignment.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
    const SizedBox(height: 10),
    SegmentedButton<String>(segments: const [
      ButtonSegment(value: 'role', label: Text('Role')),
      ButtonSegment(value: 'member', label: Text('Member')),
    ], selected: {_mode}, onSelectionChanged: (v) => setState(() { _mode = v.first; _results = []; _error = null; })),
    const SizedBox(height: 8),
    if (_mode == 'role')
      DropdownButtonFormField<String>(value: _roleId, decoration: const InputDecoration(labelText: 'Role'),
        items: widget.roles.map((r) => DropdownMenuItem(value: r['id'].toString(), child: Text(r['name'].toString()))).toList(),
        onChanged: (v) => setState(() => _roleId = v))
    else
      DropdownButtonFormField<String>(value: _userId, decoration: const InputDecoration(labelText: 'Member'),
        items: widget.members.map((m) {
          final p = m['profiles'] is Map ? Map<String, dynamic>.from(m['profiles']) : <String, dynamic>{};
          return DropdownMenuItem(value: m['user_id'].toString(), child: Text(p['display_name']?.toString() ?? p['username']?.toString() ?? 'Member'));
        }).toList(), onChanged: (v) => setState(() => _userId = v)),
    const SizedBox(height: 8),
    DropdownButtonFormField<String?>(value: _channelId, decoration: const InputDecoration(labelText: 'Channel (optional)'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Community-wide')),
        ...widget.channels.map((c) => DropdownMenuItem<String?>(value: c['id'].toString(), child: Text('#${c['name']}'))),
      ], onChanged: (v) => setState(() => _channelId = v)),
    const SizedBox(height: 10),
    FilledButton.icon(onPressed: _loading ? null : _runPreview,
      icon: _loading ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.visibility_outlined),
      label: const Text('Run preview')),
    if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 10))),
    if (_results.isNotEmpty) ...[
      const SizedBox(height: 12),
      Text('${_results.where((r) => r['allowed'] == true).length} / ${_results.length} permissions allowed', style: const TextStyle(fontWeight: FontWeight.w900)),
      ..._results.map((r) {
        final key = r['permission_key'].toString();
        return ListTile(dense: true, contentPadding: EdgeInsets.zero,
          leading: Icon(r['allowed'] == true ? Icons.check_circle : Icons.block, color: r['allowed'] == true ? KomnivoTheme.cyan : KomnivoTheme.muted, size: 17),
          title: Text(_RoleManagementScreenState.permissions[key] ?? key, style: const TextStyle(fontSize: 11)),
          subtitle: Text(r['source']?.toString() ?? '', style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
          trailing: Text(r['allowed'] == true ? 'ALLOW' : 'DENY', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 9)));
      }),
    ],
    const _InfoBox(title: 'Read-only simulation', body: 'This preview does not change database permissions. Saving is still validated by the backend hierarchy and scope guards.'),
  ]);
}

class _EventStaffPanel extends StatefulWidget {
  const _EventStaffPanel({required this.communityId, required this.labels});
  final String communityId;
  final Map<String, String> labels;
  @override
  State<_EventStaffPanel> createState() => _EventStaffPanelState();
}

class _EventStaffPanelState extends State<_EventStaffPanel> {
  final _db = Supabase.instance.client;
  final _username = TextEditingController();
  late Future<void> _initial;
  List<Map<String, dynamic>> _events = [], _rounds = [], _groups = [], _matches = [], _assignments = [], _catalog = [];
  String? _eventId, _scopeId;
  String _role = 'match_operator', _scope = 'event';
  bool _busy = false;

  @override
  void initState() { super.initState(); _initial = _loadEvents(); }

  Future<void> _loadEvents() async {
    final rows = await _db.from('events').select('id,name,status')
        .eq('community_id', widget.communityId).order('starts_at', ascending: false);
    _events = List<Map<String, dynamic>>.from(rows);
    if (_events.isNotEmpty) {
      _eventId ??= _events.first['id'].toString();
      await _loadEvent();
    }
  }

  Future<void> _loadEvent() async {
    if (_eventId == null) return;
    final values = await Future.wait([
      _db.from('event_rounds').select('id,name,round_number').eq('event_id', _eventId!).order('round_number'),
      _db.from('matches').select('id,match_code,round_number,match_number').eq('event_id', _eventId!).order('round_number').order('match_number'),
      _db.from('event_staff_assignments').select('id,user_id,role_key,scope_type,stage_id,group_id,match_id,profiles(display_name,username)')
        .eq('event_id', _eventId!).order('created_at', ascending: false),
      _db.from('event_staff_role_permissions').select('role_key,permission_key'),
    ]);
    _rounds = List<Map<String, dynamic>>.from(values[0] as List);
    _matches = List<Map<String, dynamic>>.from(values[1] as List);
    _assignments = List<Map<String, dynamic>>.from(values[2] as List);
    _catalog = List<Map<String, dynamic>>.from(values[3] as List);
    final roundIds = _rounds.map((r) => r['id'].toString()).toList();
    _groups = roundIds.isEmpty ? [] : List<Map<String, dynamic>>.from(await _db
      .from('event_groups').select('id,label,round_id').inFilter('round_id', roundIds));
    final items = _scope == 'stage' ? _rounds : _scope == 'group' ? _groups : _scope == 'match' ? _matches : [];
    if (_scope == 'event') { _scopeId = null; } else if (_scopeId == null || !items.any((r) => r['id'].toString() == _scopeId)) { _scopeId = items.isEmpty ? null : items.first['id'].toString(); }
  }

  Future<void> _refreshEvent() async {
    setState(() => _busy = true);
    try { await _loadEvent(); }
    catch (e) { if (mounted) showMessage(context, e.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  List<Map<String, dynamic>> get _scopes => _scope == 'stage' ? _rounds : _scope == 'group' ? _groups : _scope == 'match' ? _matches : [];

  String _scopeName(Map<String, dynamic> r) => r['name']?.toString() ?? r['label']?.toString() ??
    r['match_code']?.toString() ?? 'Match ${r['match_number'] ?? ''}';

  Future<void> _assign() async {
    if (_eventId == null || _username.text.trim().length < 2 || (_scope != 'event' && _scopeId == null)) {
      showMessage(context, 'Select a valid event, username and scope.');
      return;
    }
    final allowed = await _db.rpc('has_permission', params: {
      'p_permission_key': 'event.staff.assign', 'p_scope_type': 'event',
      'p_scope_id': _eventId, 'p_related_id': null, 'p_resource_id': null,
    });
    if (allowed != true) { showMessage(context, 'You are not authorised to assign staff for this event.'); return; }
    setState(() => _busy = true);
    try {
      await _db.rpc('assign_scoped_event_staff_by_username', params: {
        'p_event_id': _eventId, 'p_username': _username.text.trim(), 'p_role_key': _role,
        'p_scope_type': _scope, 'p_stage_id': _scope == 'stage' ? _scopeId : null,
        'p_group_id': _scope == 'group' ? _scopeId : null, 'p_match_id': _scope == 'match' ? _scopeId : null,
      });
      _username.clear();
      await _loadEvent();
      if (mounted) showMessage(context, 'Event staff assignment saved.');
    } catch (e) { if (mounted) showMessage(context, e.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    setState(() => _busy = true);
    try {
      await _db.rpc('remove_event_staff_assignment', params: {'p_assignment_id': row['id']});
      await _loadEvent();
      if (mounted) showMessage(context, 'Event staff assignment removed.');
    } catch (e) { if (mounted) showMessage(context, e.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void dispose() { _username.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _initial,
    builder: (context, s) {
      if (s.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Could not load events: ${s.error}', textAlign: TextAlign.center)));
      if (_events.isEmpty) return ListView(padding: const EdgeInsets.all(16), children: [
        _InfoBox(title: 'No community-linked events', body: 'Create or attach a tournament to this community. Community roles do not automatically grant tournament authority.'),
      ]);
      return ListView(padding: const EdgeInsets.all(14), children: [
        const Text('Event staff', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        const Text('Assign staff at event, stage, group or match scope.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(value: _eventId, decoration: const InputDecoration(labelText: 'Event'),
          items: _events.map((e) => DropdownMenuItem(value: e['id'].toString(), child: Text(e['name'].toString()))).toList(),
          onChanged: (v) async { setState(() { _eventId = v; _scopeId = null; }); await _refreshEvent(); }),
        const SizedBox(height: 8),
        TextField(controller: _username, decoration: const InputDecoration(labelText: 'KOMNIVO username', prefixIcon: Icon(Icons.person_search_outlined))),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(value: _role, decoration: const InputDecoration(labelText: 'Staff role'),
          items: widget.labels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) => setState(() => _role = v ?? _role)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(value: _scope, decoration: const InputDecoration(labelText: 'Scope'),
          items: const [
            DropdownMenuItem(value: 'event', child: Text('Whole event')),
            DropdownMenuItem(value: 'stage', child: Text('Stage')),
            DropdownMenuItem(value: 'group', child: Text('Group')),
            DropdownMenuItem(value: 'match', child: Text('Single match')),
          ],
          onChanged: (v) async { setState(() { _scope = v ?? 'event'; _scopeId = null; }); await _refreshEvent(); }),
        if (_scope != 'event') ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(value: _scopeId, decoration: InputDecoration(labelText: _scope),
            items: _scopes.map((r) => DropdownMenuItem(value: r['id'].toString(), child: Text(_scopeName(r)))).toList(),
            onChanged: (v) => setState(() => _scopeId = v)),
        ],
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: _busy ? null : _assign,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.person_add_alt_1),
          label: const Text('Assign staff')),
        const SizedBox(height: 16),
        const Text('Defined role permissions', style: TextStyle(fontWeight: FontWeight.w900)),
        ...widget.labels.entries.map((entry) {
          final keys = _catalog.where((r) => r['role_key'] == entry.key).map((r) => r['permission_key'].toString()).toList();
          return ExpansionTile(tilePadding: EdgeInsets.zero, title: Text(entry.value, style: const TextStyle(fontSize: 11)),
            subtitle: Text('${keys.length} explicit actions', style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
            children: [Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(left: 12, bottom: 8),
              child: Text(keys.isEmpty ? 'Permission catalogue unavailable' : keys.join(' · '), style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted))))]);
        }),
        const Divider(height: 22),
        const Text('Current assignments', style: TextStyle(fontWeight: FontWeight.w900)),
        if (_assignments.isEmpty) const Text('No event staff assignments.', style: TextStyle(fontSize: 10, color: KomnivoTheme.muted)),
        ..._assignments.map((r) {
          final profile = r['profiles'] is Map ? Map<String, dynamic>.from(r['profiles']) : <String, dynamic>{};
          final name = profile['display_name']?.toString() ?? profile['username']?.toString() ?? r['user_id'].toString();
          final scopeId = r['match_id'] ?? r['group_id'] ?? r['stage_id'];
          return Card(child: ListTile(dense: true, title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${widget.labels[r['role_key']] ?? r['role_key']} · ${r['scope_type']}${scopeId == null ? '' : ' · $scopeId'}', style: const TextStyle(fontSize: 9)),
            trailing: IconButton(onPressed: _busy ? null : () => _remove(r), icon: const Icon(Icons.person_remove_alt_1_outlined))));
        }),
        const _InfoBox(title: 'Scope boundaries', body: 'Community role access does not become event operational access. Server-side assignment and hierarchy guards remain authoritative.'),
      ]);
    },
  );
}

class _TrustHistoryPanel extends StatelessWidget {
  const _TrustHistoryPanel({required this.userId, required this.rows, required this.canRead});
  final String userId;
  final List<Map<String, dynamic>> rows;
  final bool canRead;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: Supabase.instance.client.from('my_competition_trust_states')
      .select('game_account_id,ownership_status,is_verified_player,event_id,is_registered_player,match_id,match_checkin_status,is_checked_in_player')
      .eq('user_id', userId),
    builder: (context, s) {
      final list = s.data ?? const <Map<String, dynamic>>[];
      return ListView(padding: const EdgeInsets.all(14), children: [
        const Text('Backend-derived player states', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        const Text('These are read-only state facts, not Community or Team roles.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        const SizedBox(height: 8),
        if (s.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator())
        else if (s.hasError) Text('Trust-state read failed: ${s.error}', style: const TextStyle(fontSize: 10, color: KomnivoTheme.muted))
        else if (list.isEmpty) const _InfoBox(title: 'No trust state yet', body: 'Complete the game-account verification and event registration or check-in workflows.'),
        ...list.map((r) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Game account ${r['game_account_id']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 10)),
          _state('Verified Player', r['is_verified_player'] == true, r['ownership_status']?.toString() ?? 'unverified'),
          _state('Registered Player', r['is_registered_player'] == true, r['event_id']?.toString() ?? 'not registered'),
          _state('Checked-in Player', r['is_checked_in_player'] == true, r['match_checkin_status']?.toString() ?? 'not checked in'),
        ])))),
        const SizedBox(height: 12),
        const Text('Role and assignment history', style: TextStyle(fontWeight: FontWeight.w900)),
        if (!canRead) const Text('Audit history is restricted to authorised community owners.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10))
        else if (rows.isEmpty) const Text('No role changes recorded.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10))
        else ...rows.map((r) => ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.history, size: 16),
          title: Text(r['action'].toString(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          subtitle: Text('Actor ${r['actor_user_id'] ?? 'system'} · Subject ${r['subject_user_id'] ?? 'role'} · ${r['created_at']}', style: const TextStyle(fontSize: 8, color: KomnivoTheme.muted)))),
        const _InfoBox(title: 'Not user-editable', body: 'Verified Player is derived from game ownership verification; Registered Player from approved event registration; Checked-in Player from a ready match check-in. No controls here can self-assign these statuses.'),
      ]);
    },
  );

  Widget _state(String label, bool value, String detail) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Icon(value ? Icons.check_circle : Icons.radio_button_unchecked, size: 15, color: value ? KomnivoTheme.cyan : KomnivoTheme.muted),
      const SizedBox(width: 6),
      Expanded(child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))),
      Text(value ? 'ACTIVE' : 'INACTIVE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: value ? KomnivoTheme.cyan : KomnivoTheme.muted)),
      const SizedBox(width: 5),
      Flexible(child: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 8, color: KomnivoTheme.muted))),
    ]),
  );
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) => Card(color: KomnivoTheme.surfaceRaised, child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      Text(body, style: const TextStyle(fontSize: 10, height: 1.4, color: KomnivoTheme.muted)),
    ]),
  ));
}
