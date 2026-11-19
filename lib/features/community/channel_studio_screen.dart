import 'package:flutter/material.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class ChannelStudioScreen extends StatefulWidget {
  const ChannelStudioScreen({
    super.key,
    required this.communityId,
    required this.communityName,
    this.channels = const [],
  });

  final String communityId;
  final String communityName;
  final List<Map<String, dynamic>> channels;

  @override
  State<ChannelStudioScreen> createState() => _ChannelStudioScreenState();
}

class _ChannelStudioScreenState extends State<ChannelStudioScreen> {
  final _search = TextEditingController();
  final _permissionKeys = const <String, String>{
    'View channel': 'channel.view',
    'Read history': 'channel.read_history',
    'Send messages': 'channel.send_messages',
    'Add reactions': 'channel.react',
    'Attach files': 'channel.attachments',
    'Create threads': 'channel.create_threads',
    'Pin messages': 'channel.pin_messages',
    'Manage messages': 'channel.manage_messages',
  };

  late final List<Map<String, dynamic>> _categories;
  late final List<Map<String, dynamic>> _channels;
  late final List<Map<String, dynamic>> _posts;
  late final List<Map<String, dynamic>> _threads;
  late final List<Map<String, dynamic>> _polls;
  late final List<Map<String, dynamic>> _scheduled;
  late final List<Map<String, dynamic>> _templates;

  final Set<String> _collapsed = {};
  final Set<String> _archived = {};
  final Map<String, String> _permissionStates = {};
  String _selectedRole = 'Moderator';
  String _permissionScope = 'Category';
  String _permissionCategory = 'Community';
  String _permissionChannel = 'general';
  String _textChannel = 'general';
  String _forumQuery = '';
  String _forumStatus = 'All';
  String _forumTag = 'All tags';
  String _textType = 'Text';
  String _mentionPolicy = 'Role mentions only';
  String _voiceMode = 'Voice channel';
  String _speakerPolicy = 'Members with speaker access';
  String _audience = 'All permitted members';
  String _roomPrivacy = 'Community members';
  String _roomExpiry = 'When the host ends it';
  String _templateName = 'Match room';
  String _lifecycleScope = 'Match';
  String _closeRule = 'Archive after event completion';

  bool _readOnly = false;
  bool _slowMode = false;
  double _slowSeconds = 10;
  bool _attachments = true;
  bool _links = true;
  bool _threadsAllowed = true;
  bool _pins = true;
  bool _history = true;
  bool _restrictBroadMentions = true;
  bool _showArchived = false;
  bool _lockAtStart = true;
  bool _archiveOnComplete = true;
  bool _temporaryOnly = true;
  bool _generatedPreview = false;
  bool _preserveRecords = true;
  bool _preserveEvidence = true;

  @override
  void initState() {
    super.initState();
    _categories = [
      {'id': 'cat-announcements', 'name': 'Announcements'},
      {'id': 'cat-community', 'name': 'Community'},
      {'id': 'cat-competitive', 'name': 'Competitive'},
      {'id': 'cat-voice', 'name': 'Voice rooms'},
    ];
    _channels = [
      {'id': 'ch-announcements', 'name': 'announcements', 'description': 'Official news and organiser updates', 'kind': 'announcement', 'category': 'cat-announcements', 'private': false, 'temporary': false},
      {'id': 'ch-general', 'name': 'general', 'description': 'Everyday community conversation', 'kind': 'text', 'category': 'cat-community', 'private': false, 'temporary': false},
      {'id': 'ch-help', 'name': 'help-and-support', 'description': 'Ask questions and get help', 'kind': 'forum', 'category': 'cat-community', 'private': false, 'temporary': false},
      {'id': 'ch-lfg', 'name': 'looking-for-team', 'description': 'Find teammates and substitutes', 'kind': 'forum', 'category': 'cat-competitive', 'private': false, 'temporary': false},
      {'id': 'ch-match', 'name': 'match-room-01', 'description': 'Temporary communication for one scheduled match', 'kind': 'text', 'category': 'cat-competitive', 'private': true, 'temporary': true},
      {'id': 'ch-voice', 'name': 'squad-lounge', 'description': 'Community voice conversation', 'kind': 'voice', 'category': 'cat-voice', 'private': false, 'temporary': false},
    ];
    _posts = [
      {'title': 'Looking for two players for tonight', 'body': 'Need two reliable players for a squad. Share your role and availability.', 'tag': 'Recruitment', 'status': 'Open', 'author': 'RDX_Ace', 'replies': 8, 'time': '12 min ago'},
      {'title': 'Scrim schedule discussion', 'body': 'Can we agree on a practice window for this weekend?', 'tag': 'Scrims', 'status': 'In discussion', 'author': 'Nova', 'replies': 14, 'time': '38 min ago'},
      {'title': 'Support with voice setup', 'body': 'Microphone permissions are not appearing on my device.', 'tag': 'Support', 'status': 'Filled', 'author': 'Kairo', 'replies': 3, 'time': 'Yesterday'},
      {'title': 'Team recruitment closed', 'body': 'The roster is complete. Thanks to everyone who responded.', 'tag': 'Recruitment', 'status': 'Closed', 'author': 'IGL_Lead', 'replies': 6, 'time': 'Yesterday'},
    ];
    _threads = [
      {'title': 'Tournament starts at 7 PM', 'channel': '#announcements', 'replies': 12, 'last': 'RDX_Ace · 4 min ago'},
      {'title': 'Which map should we practise?', 'channel': '#general', 'replies': 6, 'last': 'Nova · 18 min ago'},
    ];
    _polls = [
      {'question': 'Preferred scrim start time?', 'options': ['6 PM', '7 PM', '8 PM'], 'votes': [4, 9, 3], 'ends': 'Today · 5 PM'},
    ];
    _scheduled = [
      {'title': 'Weekend scrim reminder', 'channel': '#announcements', 'when': 'Tomorrow · 5:30 PM', 'status': 'Scheduled'},
    ];
    _templates = [
      {'name': 'Match room', 'scope': 'Match', 'channels': ['match-chat', 'match-voice'], 'audience': 'Assigned teams + match staff', 'detail': 'Temporary, private and match-scoped'},
      {'name': 'Stage briefing', 'scope': 'Stage', 'channels': ['stage-announcements', 'stage-questions'], 'audience': 'Stage participants + stage staff', 'detail': 'Briefing and questions for one stage'},
      {'name': 'Group coordination', 'scope': 'Group', 'channels': ['group-chat'], 'audience': 'Teams assigned to the group', 'detail': 'Only the selected group can access it'},
      {'name': 'Results & disputes', 'scope': 'Event', 'channels': ['results-updates', 'dispute-help'], 'audience': 'Event participants + authorised reviewers', 'detail': 'Communication only; official results remain in tournament records'},
    ];
    if (widget.channels.isNotEmpty) {
      // Keep existing server category IDs visible in the studio even before
      // the category-name query is wired in the backend pass.
      for (final row in widget.channels) {
        final categoryId = row['category_id']?.toString();
        if (categoryId != null &&
            categoryId.isNotEmpty &&
            !_categories.any((category) => category['id'] == categoryId)) {
          _categories.add({'id': categoryId, 'name': 'Existing category'});
        }
      }
      _channels
        ..clear()
        ..addAll(widget.channels.map((row) => {
          'id': row['id']?.toString() ?? 'existing-' + row.hashCode.toString(),
          'name': row['name']?.toString() ?? 'channel',
          'description': row['description']?.toString() ?? '',
          'kind': row['kind']?.toString() ?? 'text',
          'category': row['category_id']?.toString() ?? 'cat-community',
          'private': row['is_private'] == true,
          'temporary': row['is_temporary'] == true,
        }));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _previewNotice() => showMessage(context, 'UI preview updated. Persistent saving is part of the next backend phase.');

  Widget _banner() => Container(
    margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(13), border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .26))),
    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.design_services_outlined, color: KomnivoTheme.accent, size: 18),
      SizedBox(width: 9),
      Expanded(child: Text('UI/UX preview · Controls are interactive. Persistent configuration will be connected after the frontend pass.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4))),
    ]),
  );

  Widget _section(String title, String subtitle, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35)),
      ])),
      if (trailing != null) trailing,
    ]),
  );

  Widget _surface({required Widget child, EdgeInsets padding = const EdgeInsets.all(14), Color? color}) => Container(
    padding: padding,
    decoration: BoxDecoration(color: color ?? KomnivoTheme.surface, borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
    child: child,
  );

  Widget _pill(String label, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(color: (color ?? KomnivoTheme.accent).withValues(alpha: .12), borderRadius: BorderRadius.circular(30), border: Border.all(color: (color ?? KomnivoTheme.accent).withValues(alpha: .24))),
    child: Text(label, style: TextStyle(color: color ?? KomnivoTheme.accent, fontSize: 9, fontWeight: FontWeight.w800)),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 7,
    child: Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Channel Studio', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          Text(widget.communityName, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        ]),
        bottom: const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(icon: Icon(Icons.dashboard_customize_outlined), text: 'Structure'),
            Tab(icon: Icon(Icons.security_outlined), text: 'Permissions'),
            Tab(icon: Icon(Icons.forum_outlined), text: 'Text'),
            Tab(icon: Icon(Icons.view_list_outlined), text: 'Forum'),
            Tab(icon: Icon(Icons.mark_chat_unread_outlined), text: 'Engage'),
            Tab(icon: Icon(Icons.headset_mic_outlined), text: 'Voice / Stage'),
            Tab(icon: Icon(Icons.event_available_outlined), text: 'Event flow'),
          ],
        ),
      ),
      body: Column(children: [
        _banner(),
        Expanded(child: TabBarView(children: [
          _structureTab(),
          _permissionsTab(),
          _textTab(),
          _forumTab(),
          _engagementTab(),
          _voiceStageTab(),
          _eventFlowTab(),
        ])),
      ]),
    ),
  );

  Widget _structureTab() {
    final active = _categories.where((row) => _showArchived || !_archived.contains(row['id'])).toList();
    final activeCount = _categories.length - _archived.length;
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      _section('Channel structure', 'Arrange categories, choose channel types and keep temporary spaces separate.',
        trailing: FilledButton.tonalIcon(onPressed: _createCategory, icon: const Icon(Icons.create_new_folder_outlined, size: 17), label: const Text('Category'))),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(child: Text(activeCount.toString() + ' active categories · ' + _channels.length.toString() + ' channels', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10))),
          TextButton.icon(onPressed: () => setState(() => _showArchived = !_showArchived), icon: Icon(_showArchived ? Icons.visibility_off_outlined : Icons.archive_outlined, size: 15), label: Text(_showArchived ? 'Hide archived' : 'Show archived')),
        ]),
      ),
      ...active.map(_categoryCard),
      _section('Channel types', 'Each surface has a different purpose and permission model.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Wrap(spacing: 7, runSpacing: 7, children: [
        _typeGuide(Icons.tag, 'Text', 'Conversation', KomnivoTheme.muted),
        _typeGuide(Icons.campaign_outlined, 'Announcement', 'Controlled publishing', KomnivoTheme.cyan),
        _typeGuide(Icons.forum_outlined, 'Forum', 'Tagged discussions', KomnivoTheme.accent),
        _typeGuide(Icons.graphic_eq, 'Voice', 'Live audio room', const Color(0xFF54C9A5)),
      ])),
    ]);
  }

  Widget _typeGuide(IconData icon, String title, String detail, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: KomnivoTheme.line)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 7),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
        Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
      ]),
    ]),
  );

  Widget _categoryCard(Map<String, dynamic> category) {
    final id = category['id'].toString();
    final archived = _archived.contains(id);
    final collapsed = _collapsed.contains(id);
    final channelRows = _channels.where((row) => row['category'] == id).toList();
    final index = _categories.indexOf(category);
    return Container(
      key: ValueKey(id),
      margin: const EdgeInsets.fromLTRB(14, 5, 14, 7),
      decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 5, 8),
          child: Row(children: [
            const Icon(Icons.drag_indicator, color: KomnivoTheme.muted, size: 18),
            const SizedBox(width: 5),
            Expanded(child: InkWell(
              onTap: () => setState(() { if (collapsed) { _collapsed.remove(id); } else { _collapsed.add(id); } }),
              child: Row(children: [
                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 19, color: KomnivoTheme.muted),
                const SizedBox(width: 3),
                Expanded(child: Text(category['name'].toString().toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1))),
                _pill(channelRows.length.toString(), color: KomnivoTheme.muted),
              ]),
            )),
            IconButton(tooltip: 'Move up', onPressed: index == 0 ? null : () => _moveCategory(index, index - 1), icon: const Icon(Icons.keyboard_arrow_up, size: 18)),
            IconButton(tooltip: 'Move down', onPressed: index == _categories.length - 1 ? null : () => _moveCategory(index, index + 1), icon: const Icon(Icons.keyboard_arrow_down, size: 18)),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'rename') _renameCategory(category);
                if (value == 'archive') _archiveCategory(category);
                if (value == 'channel') _createChannel(categoryId: id);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename category')),
                const PopupMenuItem(value: 'channel', child: Text('Add channel here')),
                PopupMenuItem(value: 'archive', child: Text(archived ? 'Restore category' : 'Archive category')),
              ],
            ),
          ]),
        ),
        if (!collapsed) ...[
          const Divider(height: 1),
          if (channelRows.isEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 14), child: Row(children: [
              const Expanded(child: Text('No channels in this category yet.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10))),
              TextButton.icon(onPressed: () => _createChannel(categoryId: id), icon: const Icon(Icons.add, size: 15), label: const Text('Add channel')),
            ]))
          else
            ...channelRows.map(_channelRow),
        ],
        if (archived)
          const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 10), child: Align(alignment: Alignment.centerLeft, child: Text('ARCHIVED · hidden from the active channel list', style: TextStyle(color: KomnivoTheme.muted, fontSize: 8, letterSpacing: .6)))),
      ]),
    );
  }

  Widget _channelRow(Map<String, dynamic> channel) {
    final type = channel['kind']?.toString() ?? 'text';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
      leading: Icon(_typeIcon(type), size: 17, color: _typeColor(type)),
      title: Text(channel['name'].toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      subtitle: Text(channel['description'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (channel['private'] == true) const Icon(Icons.lock_outline, size: 14, color: KomnivoTheme.muted),
        if (channel['temporary'] == true) const Padding(padding: EdgeInsets.only(left: 5), child: Icon(Icons.timer_outlined, size: 14, color: KomnivoTheme.cyan)),
        IconButton(tooltip: 'Edit channel', onPressed: () => _editChannel(channel), icon: const Icon(Icons.tune, size: 17)),
      ]),
      onTap: () => _editChannel(channel),
    );
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case 'announcement': return Icons.campaign_outlined;
      case 'forum': return Icons.forum_outlined;
      case 'voice': return Icons.graphic_eq;
      default: return Icons.tag;
    }
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'announcement': return KomnivoTheme.cyan;
      case 'forum': return KomnivoTheme.accent;
      case 'voice': return const Color(0xFF54C9A5);
      default: return KomnivoTheme.muted;
    }
  }

  void _moveCategory(int from, int to) {
    setState(() {
      final row = _categories.removeAt(from);
      _categories.insert(to, row);
    });
    _previewNotice();
  }

  Future<void> _createCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create category'),
        content: TextField(controller: controller, autofocus: true, maxLength: 50, decoration: const InputDecoration(labelText: 'Category name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.length < 2) return;
    setState(() => _categories.add({'id': 'cat-' + DateTime.now().microsecondsSinceEpoch.toString(), 'name': name}));
    _previewNotice();
  }

  Future<void> _renameCategory(Map<String, dynamic> category) async {
    final controller = TextEditingController(text: category['name'].toString());
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename category'),
        content: TextField(controller: controller, autofocus: true, maxLength: 50, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.length < 2) return;
    setState(() => category['name'] = name);
    _previewNotice();
  }

  Future<void> _archiveCategory(Map<String, dynamic> category) async {
    final id = category['id'].toString();
    final isArchived = _archived.contains(id);
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isArchived ? 'Restore category?' : 'Archive category?'),
        content: Text(isArchived ? 'The category returns to the active structure.' : 'The category is hidden from the normal channel list. Its channels and history are not deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(isArchived ? 'Restore' : 'Archive')),
        ],
      ),
    );
    if (approved != true) return;
    setState(() { if (isArchived) { _archived.remove(id); } else { _archived.add(id); } });
    _previewNotice();
  }

  Future<void> _createChannel({String? categoryId}) async {
    final draft = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ChannelDraftDialog(categories: _categories, initialCategoryId: categoryId),
    );
    if (draft == null) return;
    setState(() => _channels.add({
      'id': 'ch-' + DateTime.now().microsecondsSinceEpoch.toString(),
      'name': draft['name']!, 'description': draft['description'] ?? '',
      'kind': draft['kind'] ?? 'text', 'category': draft['category'] ?? _categories.first['id'],
      'private': draft['private'] == 'true', 'temporary': draft['temporary'] == 'true',
    }));
    _previewNotice();
  }

  Future<void> _editChannel(Map<String, dynamic> channel) async {
    final draft = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ChannelDraftDialog(categories: _categories, channel: channel),
    );
    if (draft == null) return;
    setState(() {
      channel
        ..['name'] = draft['name']!
        ..['description'] = draft['description'] ?? ''
        ..['kind'] = draft['kind'] ?? 'text'
        ..['category'] = draft['category'] ?? channel['category']
        ..['private'] = draft['private'] == 'true'
        ..['temporary'] = draft['temporary'] == 'true';
    });
    _previewNotice();
  }

  Widget _permissionsTab() {
    final targets = _permissionScope == 'Category'
      ? _categories.map((row) => row['name'].toString()).toList()
      : _channels.map((row) => row['name'].toString()).toList();
    final selected = _permissionScope == 'Category' ? _permissionCategory : _permissionChannel;
    final safeTarget = targets.contains(selected) ? selected : (targets.isEmpty ? '' : targets.first);
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      _section('Permission inheritance', 'Choose a role and target, then set Inherit, Allow or Deny for each action.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ROLE', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: _selectedRole,
          decoration: const InputDecoration(isDense: true),
          items: const ['Owner', 'Admin', 'Moderator', 'Organiser', 'Member'].map((role) => DropdownMenuItem(value: role, child: Text(role))).toList(),
          onChanged: (value) => setState(() => _selectedRole = value ?? _selectedRole),
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'Category', label: Text('Category defaults'), icon: Icon(Icons.folder_outlined)),
            ButtonSegment(value: 'Channel', label: Text('Channel override'), icon: Icon(Icons.tag)),
          ],
          selected: {_permissionScope},
          onSelectionChanged: (value) => setState(() => _permissionScope = value.first),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: safeTarget.isEmpty ? null : safeTarget,
          decoration: InputDecoration(labelText: _permissionScope),
          items: targets.map((name) => DropdownMenuItem(value: name, child: Text(name))).toList(),
          onChanged: (value) => setState(() {
            if (_permissionScope == 'Category') { _permissionCategory = value ?? _permissionCategory; }
            else { _permissionChannel = value ?? _permissionChannel; }
          }),
        ),
        if (_permissionScope == 'Channel') ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _syncWithCategory, icon: const Icon(Icons.sync, size: 16), label: const Text('Sync with category')),
        ],
      ]))),
      _section('Permission states', 'A channel inherits the category value unless a channel override is set.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(children: _permissionKeys.entries.map((entry) {
        final stateKey = _selectedRole + '|' + _permissionScope + '|' + safeTarget + '|' + entry.value;
        final state = _permissionStates[stateKey] ?? 'Inherit';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.key, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
              Text(entry.value, style: const TextStyle(fontSize: 8, color: KomnivoTheme.muted)),
            ])),
            const SizedBox(width: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact, padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 7, vertical: 7))),
              segments: const [
                ButtonSegment(value: 'Inherit', label: Text('Inherit')),
                ButtonSegment(value: 'Allow', label: Text('Allow')),
                ButtonSegment(value: 'Deny', label: Text('Deny')),
              ],
              selected: {state},
              onSelectionChanged: (value) => setState(() => _permissionStates[stateKey] = value.first),
            ),
          ]),
        );
      }).toList()))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: _surface(color: KomnivoTheme.surfaceRaised, child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, color: KomnivoTheme.cyan, size: 17),
        SizedBox(width: 9),
        Expanded(child: Text('An explicit channel setting wins over the category default for that permission. Inherit remains linked; it is not copied. Deny is a deliberate override.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.45))),
      ]))),
    ]);
  }

  void _syncWithCategory() {
    for (final permission in _permissionKeys.values) {
      final key = _selectedRole + '|Channel|' + _permissionChannel + '|' + permission;
      _permissionStates[key] = 'Inherit';
    }
    setState(() {});
    _previewNotice();
  }

  Widget _textTab() {
    final rows = _channels.where((row) => row['kind'] == 'text' || row['kind'] == 'announcement').toList();
    final names = rows.map((row) => row['name'].toString()).toList();
    final selectedRow = rows.where((row) => row['name'] == _textChannel).toList();
    if (names.isNotEmpty && !names.contains(_textChannel)) {
      _textChannel = names.first;
    }
    final selectedType = selectedRow.isEmpty ? _textType : (selectedRow.first['kind'] == 'announcement' ? 'Announcement' : 'Text');
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      _section('Text & Announcement behaviour', 'Configure read-only mode, slow mode, attachments, pins, history and mention controls.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(children: [
        DropdownButtonFormField<String>(
          value: names.contains(_textChannel) ? _textChannel : null,
          decoration: const InputDecoration(labelText: 'Channel'),
          items: names.map((name) => DropdownMenuItem(value: name, child: Text('#' + name))).toList(),
          onChanged: (value) => setState(() => _textChannel = value ?? _textChannel),
        ),
        const SizedBox(height: 10),
        Row(children: [
          _pill(selectedType.toUpperCase(), color: selectedType == 'Announcement' ? KomnivoTheme.cyan : KomnivoTheme.muted),
          const SizedBox(width: 8),
          const Expanded(child: Text('Announcement publishing can be restricted independently from normal chat.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9))),
        ]),
      ]))),
      _section('Posting controls', 'Choose what members can do in this channel.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(children: [
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Read-only channel', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)), subtitle: const Text('Only users with publish permission can send messages.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _readOnly, onChanged: (value) => setState(() => _readOnly = value)),
        const Divider(height: 1),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Slow mode', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)), subtitle: Text(_slowMode ? 'One message every ' + _slowSeconds.round().toString() + ' seconds' : 'No per-member delay', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _slowMode, onChanged: (value) => setState(() => _slowMode = value)),
        if (_slowMode) Slider(min: 5, max: 120, divisions: 23, value: _slowSeconds, label: _slowSeconds.round().toString() + ' sec', onChanged: (value) => setState(() => _slowSeconds = value)),
        const Divider(height: 1),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allow image and file attachments', style: TextStyle(fontSize: 11)), value: _attachments, onChanged: (value) => setState(() => _attachments = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allow links and embeds', style: TextStyle(fontSize: 11)), value: _links, onChanged: (value) => setState(() => _links = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allow message threads', style: TextStyle(fontSize: 11)), value: _threadsAllowed, onChanged: (value) => setState(() => _threadsAllowed = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allow pinned messages', style: TextStyle(fontSize: 11)), value: _pins, onChanged: (value) => setState(() => _pins = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Keep message history visible', style: TextStyle(fontSize: 11)), value: _history, onChanged: (value) => setState(() => _history = value)),
      ]))),
      _section('Controlled mentions', 'Prevent broad mentions from being used as a spam shortcut.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(children: [
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Restrict @everyone and @here', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)), value: _restrictBroadMentions, onChanged: (value) => setState(() => _restrictBroadMentions = value)),
        DropdownButtonFormField<String>(
          value: _mentionPolicy,
          decoration: const InputDecoration(labelText: 'Allowed mentions'),
          items: const [
            DropdownMenuItem(value: 'No broad mentions', child: Text('No broad mentions')),
            DropdownMenuItem(value: 'Role mentions only', child: Text('Role mentions only')),
            DropdownMenuItem(value: 'Members and roles', child: Text('Members and roles')),
            DropdownMenuItem(value: 'Channel moderators only', child: Text('Channel moderators only')),
          ],
          onChanged: (value) => setState(() => _mentionPolicy = value ?? _mentionPolicy),
        ),
        const SizedBox(height: 8),
        const Text('Mention permission is separate from permission to send a normal message.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
      ]))),
      _section('Channel behaviour preview', 'See how the selected settings affect the composer.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(selectedType == 'Announcement' ? Icons.campaign_outlined : Icons.tag, color: KomnivoTheme.cyan, size: 18),
          const SizedBox(width: 7),
          Expanded(child: Text('#' + _textChannel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
          _pill(_readOnly ? 'READ ONLY' : 'POSTING ENABLED', color: _readOnly ? KomnivoTheme.danger : const Color(0xFF54C9A5)),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(11)),
          child: Row(children: [
            const Expanded(child: Text('Write a message…', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11))),
            Icon(Icons.attach_file, size: 16, color: _attachments ? KomnivoTheme.cyan : KomnivoTheme.muted.withValues(alpha: .35)),
            const SizedBox(width: 10),
            Icon(Icons.send_rounded, size: 16, color: _readOnly ? KomnivoTheme.muted.withValues(alpha: .35) : KomnivoTheme.accent),
          ]),
        ),
        const SizedBox(height: 8),
        Text(
          (_readOnly ? 'Posting restricted to publishers. ' : 'Members may post subject to channel permissions. ') +
          (_slowMode ? 'Slow mode: ' + _slowSeconds.round().toString() + 's. ' : '') +
          (_pins ? 'Pins enabled. ' : 'Pins disabled. ') +
          (_restrictBroadMentions ? 'Broad mentions restricted.' : 'Broad mentions follow role permission.'),
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.45),
        ),
      ]))),
    ]);
  }

  Widget _forumTab() {
    final filtered = _posts.where((post) {
      final q = _forumQuery.trim().toLowerCase();
      final matchQuery = q.isEmpty || post['title'].toString().toLowerCase().contains(q) || post['body'].toString().toLowerCase().contains(q);
      final matchStatus = _forumStatus == 'All' || post['status'] == _forumStatus;
      final matchTag = _forumTag == 'All tags' || post['tag'] == _forumTag;
      return matchQuery && matchStatus && matchTag;
    }).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      _section('Forum channels', 'Topic-first discussions for recruitment, LFG, support and suggestions.',
        trailing: FilledButton.icon(onPressed: _newForumPost, icon: const Icon(Icons.add, size: 17), label: const Text('New post'))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search posts and topics…'), onChanged: (value) => setState(() => _forumQuery = value))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 9, 16, 0), child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final status in ['All', 'Open', 'In discussion', 'Filled', 'Closed'])
          ChoiceChip(label: Text(status), selected: _forumStatus == status, onSelected: (_) => setState(() => _forumStatus = status)),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(16, 5, 16, 0), child: DropdownButtonFormField<String>(
        value: _forumTag,
        decoration: const InputDecoration(labelText: 'Filter by tag', isDense: true),
        items: const ['All tags', 'Recruitment', 'Scrims', 'Support', 'Suggestions', 'LFG'].map((tag) => DropdownMenuItem(value: tag, child: Text(tag))).toList(),
        onChanged: (value) => setState(() => _forumTag = value ?? 'All tags'),
      )),
      if (filtered.isEmpty)
        const Padding(padding: EdgeInsets.all(26), child: EmptyState(title: 'No matching topics', message: 'Try another filter or start a new post.', icon: Icons.forum_outlined))
      else
        ...filtered.map(_forumCard),
      _section('Forum behaviour', 'Tags and topic lifecycle are independent from channel membership.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Bullet(text: 'Tags group topics without creating a channel for every subject.'),
        _Bullet(text: 'Open, In discussion, Filled and Closed express the topic lifecycle.'),
        _Bullet(text: 'Moderators can lock or close a topic while preserving its reply history.'),
        _Bullet(text: 'Search and status filters apply inside the selected Forum channel.'),
      ]))),
    ]);
  }

  Widget _forumCard(Map<String, dynamic> post) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
    child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _pill(post['status'].toString(), color: post['status'] == 'Closed' ? KomnivoTheme.muted : post['status'] == 'Filled' ? const Color(0xFF54C9A5) : KomnivoTheme.accent),
        const SizedBox(width: 6),
        _pill(post['tag'].toString(), color: KomnivoTheme.cyan),
        const Spacer(),
        PopupMenuButton<String>(
          onSelected: (value) { setState(() => post['status'] = value); _previewNotice(); },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'Open', child: Text('Reopen')),
            PopupMenuItem(value: 'In discussion', child: Text('Move to discussion')),
            PopupMenuItem(value: 'Filled', child: Text('Mark filled')),
            PopupMenuItem(value: 'Closed', child: Text('Close topic')),
          ],
        ),
      ]),
      const SizedBox(height: 5),
      Text(post['title'].toString(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      Text(post['body'].toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4)),
      const SizedBox(height: 9),
      Row(children: [
        const Icon(Icons.person_outline, size: 14, color: KomnivoTheme.muted),
        const SizedBox(width: 4),
        Text(post['author'].toString(), style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
        const SizedBox(width: 12),
        const Icon(Icons.chat_bubble_outline, size: 14, color: KomnivoTheme.muted),
        const SizedBox(width: 4),
        Text(post['replies'].toString() + ' replies', style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
        const Spacer(),
        Text(post['time'].toString(), style: const TextStyle(fontSize: 8, color: KomnivoTheme.muted)),
      ]),
    ])),
  );

  Future<void> _newForumPost() async {
    final title = TextEditingController();
    final body = TextEditingController();
    String tag = 'LFG';
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: const Text('Create Forum post'),
        content: SizedBox(width: 430, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, maxLength: 100, decoration: const InputDecoration(labelText: 'Title')),
          TextField(controller: body, maxLines: 4, maxLength: 1200, decoration: const InputDecoration(labelText: 'Details')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: tag,
            decoration: const InputDecoration(labelText: 'Topic tag'),
            items: const ['LFG', 'Recruitment', 'Scrims', 'Support', 'Suggestions'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
            onChanged: (value) => setDialogState(() => tag = value ?? tag),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, {'title': title.text.trim(), 'body': body.text.trim(), 'tag': tag}), child: const Text('Preview post')),
        ],
      )),
    );
    title.dispose();
    body.dispose();
    if (result == null || (result['title'] ?? '').length < 3) return;
    setState(() => _posts.insert(0, {'title': result['title']!, 'body': result['body'] ?? '', 'tag': result['tag'] ?? 'LFG', 'status': 'Open', 'author': 'You', 'replies': 0, 'time': 'Just now'}));
    _previewNotice();
  }

  Widget _engagementTab() => ListView(padding: const EdgeInsets.only(bottom: 28), children: [
    _section('Threads & replies', 'Keep deeper conversations attached to the original channel message.'),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
      ..._threads.map((thread) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _surface(child: Row(children: [
          const Icon(Icons.forum_outlined, color: KomnivoTheme.cyan, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(thread['title'].toString(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
            Text(thread['channel'].toString() + ' · ' + thread['replies'].toString() + ' replies · ' + thread['last'].toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
          ])),
          IconButton(onPressed: () => _openThread(thread), icon: const Icon(Icons.arrow_forward_ios, size: 15)),
        ])),
      )),
      Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: _newThread, icon: const Icon(Icons.add_comment_outlined), label: const Text('Preview new thread'))),
    ])),
    _section('Reactions', 'Lightweight reactions do not create a separate conversation.'),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Quick reactions', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Wrap(spacing: 7, children: ['👍', '❤️', '🔥', '😂', '👀', '🎯'].map((emoji) => ActionChip(label: Text(emoji), onPressed: () => showMessage(context, 'Reaction preview: ' + emoji))).toList()),
      const SizedBox(height: 5),
      const Text('Reaction permissions can be set per role and channel in the Access tab.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
    ]))),
    _section('Polls', 'Community opinions stay separate from official tournament scoring.'),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
      ..._polls.map(_pollCard),
      Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: _newPoll, icon: const Icon(Icons.poll_outlined, size: 16), label: const Text('Create poll'))),
    ])),
    _section('Scheduled announcements', 'Prepare a message and choose its publish time.'),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
      ..._scheduled.map((row) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _surface(child: Row(children: [
          const Icon(Icons.schedule, color: KomnivoTheme.cyan, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(row['title'].toString(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
            Text(row['channel'].toString() + ' · ' + row['when'].toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
          ])),
          _pill(row['status'].toString(), color: const Color(0xFF54C9A5)),
        ])),
      )),
      Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: _schedule, icon: const Icon(Icons.calendar_month_outlined, size: 16), label: const Text('Schedule announcement'))),
    ])),
  ]);

  Widget _pollCard(Map<String, dynamic> poll) {
    final votes = (poll['votes'] as List).cast<int>();
    final total = votes.fold<int>(0, (sum, value) => sum + value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.poll_outlined, size: 17, color: KomnivoTheme.accent), const SizedBox(width: 7), Expanded(child: Text(poll['question'].toString(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11)))]),
        const SizedBox(height: 9),
        ...List.generate((poll['options'] as List).length, (index) {
          final option = (poll['options'] as List)[index].toString();
          final count = votes[index];
          final ratio = total == 0 ? 0.0 : count / total;
          return Padding(padding: const EdgeInsets.only(bottom: 7), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(option, style: const TextStyle(fontSize: 10))), Text(count.toString() + ' votes', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9))]),
            const SizedBox(height: 4),
            ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: ratio, minHeight: 6, backgroundColor: KomnivoTheme.surfaceRaised)),
          ]));
        }),
        Text('Closes ' + poll['ends'].toString() + ' · ' + total.toString() + ' votes', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
      ])),
    );
  }

  Future<void> _openThread(Map<String, dynamic> thread) async {
    final reply = TextEditingController();
    final preview = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KomnivoTheme.surface,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(16, 18, 16, MediaQuery.viewInsetsOf(sheetContext).bottom + 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(thread['title'].toString(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          Text(thread['channel'].toString() + ' · ' + thread['replies'].toString() + ' replies', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
          const SizedBox(height: 14),
          const _ThreadReply(author: 'Nova', body: 'I can make that time.'),
          const _ThreadReply(author: 'RDX_Ace', body: 'Let us confirm the roster first.'),
          const SizedBox(height: 12),
          TextField(controller: reply, minLines: 1, maxLines: 3, decoration: const InputDecoration(hintText: 'Reply in thread…')),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(sheetContext, reply.text.trim().isNotEmpty), child: const Text('Preview reply'))),
        ]),
      ),
    );
    reply.dispose();
    if (preview == true) _previewNotice();
  }

  Future<void> _newThread() async {
    final title = TextEditingController();
    final preview = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start a thread'),
        content: TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Thread topic')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, title.text.trim().isNotEmpty), child: const Text('Preview')),
        ],
      ),
    );
    title.dispose();
    if (preview == true) _previewNotice();
  }

  Future<void> _newPoll() async {
    final question = TextEditingController();
    final first = TextEditingController();
    final second = TextEditingController();
    final preview = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create poll'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: question, decoration: const InputDecoration(labelText: 'Question')),
          TextField(controller: first, decoration: const InputDecoration(labelText: 'Option 1')),
          TextField(controller: second, decoration: const InputDecoration(labelText: 'Option 2')),
          const SizedBox(height: 5),
          const Text('Polls are community opinions, not official tournament results.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, question.text.trim().isNotEmpty && first.text.trim().isNotEmpty && second.text.trim().isNotEmpty), child: const Text('Preview poll')),
        ],
      ),
    );
    question.dispose(); first.dispose(); second.dispose();
    if (preview == true) _previewNotice();
  }

  Future<void> _schedule() async {
    final message = TextEditingController();
    String time = 'Tomorrow · 9:00 AM';
    final preview = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: const Text('Schedule announcement'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: message, maxLines: 4, decoration: const InputDecoration(labelText: 'Announcement text')),
          const SizedBox(height: 9),
          DropdownButtonFormField<String>(
            value: time,
            decoration: const InputDecoration(labelText: 'Publish time · preview'),
            items: const ['Today · 6:00 PM', 'Tomorrow · 9:00 AM', 'Tomorrow · 5:30 PM'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
            onChanged: (value) => setDialogState(() => time = value ?? time),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, message.text.trim().isNotEmpty), child: const Text('Preview schedule')),
        ],
      )),
    );
    message.dispose();
    if (preview == true) _previewNotice();
  }

  Widget _voiceStageTab() {
    final stage = _voiceMode == 'Stage broadcast';
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      _section('Voice and Stage are different surfaces', 'Voice is a room for two-way audio. Stage is a moderated broadcast with speakers and listeners.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'Voice channel', label: Text('Voice channel'), icon: Icon(Icons.headset_mic_outlined)),
          ButtonSegment(value: 'Stage broadcast', label: Text('Stage broadcast'), icon: Icon(Icons.mic_external_on_outlined)),
        ],
        selected: {_voiceMode},
        onSelectionChanged: (value) => setState(() => _voiceMode = value.first),
      )),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(stage ? Icons.mic_external_on_outlined : Icons.headset_mic_outlined, color: stage ? KomnivoTheme.accent : const Color(0xFF54C9A5), size: 22),
          const SizedBox(width: 9),
          Expanded(child: Text(stage ? 'Stage broadcast configuration' : 'Voice room configuration', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900))),
          _pill(stage ? 'ONE-TO-MANY' : 'TWO-WAY AUDIO', color: stage ? KomnivoTheme.accent : const Color(0xFF54C9A5)),
        ]),
        const SizedBox(height: 8),
        Text(stage ? 'A host and approved speakers broadcast to an audience. Listeners do not transmit unless promoted.' : 'Permitted members can join the room and speak subject to room permissions.', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.45)),
      ]))),
      _section('Speaker access', 'Choose who may transmit audio or receive speaker status.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(children: [
        DropdownButtonFormField<String>(
          value: _speakerPolicy,
          decoration: const InputDecoration(labelText: 'Who can speak'),
          items: const [
            DropdownMenuItem(value: 'Members with speaker access', child: Text('Members with speaker access')),
            DropdownMenuItem(value: 'Hosts and moderators', child: Text('Hosts and moderators')),
            DropdownMenuItem(value: 'Assigned speakers only', child: Text('Assigned speakers only')),
          ],
          onChanged: (value) => setState(() => _speakerPolicy = value ?? _speakerPolicy),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _audience,
          decoration: const InputDecoration(labelText: 'Audience'),
          items: const [
            DropdownMenuItem(value: 'All permitted members', child: Text('All permitted members')),
            DropdownMenuItem(value: 'Selected roles only', child: Text('Selected roles only')),
            DropdownMenuItem(value: 'Event participants only', child: Text('Event participants only')),
            DropdownMenuItem(value: 'Invited audience only', child: Text('Invited audience only')),
          ],
          onChanged: (value) => setState(() => _audience = value ?? _audience),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _roomPrivacy,
          decoration: const InputDecoration(labelText: 'Room visibility'),
          items: const [
            DropdownMenuItem(value: 'Community members', child: Text('Community members')),
            DropdownMenuItem(value: 'Private invited room', child: Text('Private invited room')),
            DropdownMenuItem(value: 'Assigned team only', child: Text('Assigned team only')),
            DropdownMenuItem(value: 'Selected event scope', child: Text('Selected event scope')),
          ],
          onChanged: (value) => setState(() => _roomPrivacy = value ?? _roomPrivacy),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _roomExpiry,
          decoration: const InputDecoration(labelText: 'Temporary room lifetime'),
          items: const [
            DropdownMenuItem(value: 'When the host ends it', child: Text('When the host ends it')),
            DropdownMenuItem(value: 'After 30 minutes idle', child: Text('After 30 minutes idle')),
            DropdownMenuItem(value: 'At the end of the event', child: Text('At the end of the event')),
            DropdownMenuItem(value: 'After the selected match', child: Text('After the selected match')),
          ],
          onChanged: (value) => setState(() => _roomExpiry = value ?? _roomExpiry),
        ),
      ]))),
      _section('Access preview', 'The same privacy boundary is checked before someone enters.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _previewRow('Speakers', _speakerPolicy),
        _previewRow('Audience', _audience),
        _previewRow('Room access', _roomPrivacy),
        _previewRow('Room expiry', _roomExpiry),
        const Divider(height: 18),
        const Text('No Stage channel is created by this preview. Stage-specific publishing and speaker promotion are a separate product surface.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.45)),
      ]))),
    ]);
  }

  Widget _previewRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      SizedBox(width: 100, child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9))),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))),
    ]),
  );

  Widget _eventFlowTab() {
    final template = _templates.firstWhere((row) => row['name'] == _templateName);
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      _section('Approved event channel templates', 'Create communication surfaces only from a configured template and a specific scope.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: _templates.map((row) {
        final selected = row['name'] == _templateName;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: () => setState(() { _templateName = row['name'].toString(); _generatedPreview = false; }),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(color: selected ? KomnivoTheme.surfaceRaised : KomnivoTheme.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: selected ? KomnivoTheme.accent : KomnivoTheme.line)),
              child: Row(children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? KomnivoTheme.accent : KomnivoTheme.muted, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Expanded(child: Text(row['name'].toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900))), _pill(row['scope'].toString())]),
                  const SizedBox(height: 3),
                  Text(row['detail'].toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
                ])),
              ]),
            ),
          ),
        );
      }).toList())),
      Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('TEMPLATE PREVIEW', style: TextStyle(fontSize: 9, letterSpacing: 1, color: KomnivoTheme.muted, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text(template['name'].toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
        _previewRow('Scope', template['scope'].toString()),
        _previewRow('Audience', template['audience'].toString()),
        const Divider(height: 18),
        ...(template['channels'] as List).map((name) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Icon(Icons.tag, size: 15, color: KomnivoTheme.cyan),
            const SizedBox(width: 8),
            Expanded(child: Text(name.toString(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))),
            const Text('Template channel', style: TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
          ]),
        )),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: () => setState(() => _generatedPreview = true), icon: const Icon(Icons.preview_outlined, size: 17), label: const Text('Generate local preview')),
        if (_generatedPreview) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Preview ready · nothing has been published or created.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 9))),
      ]))),
      _section('Temporary channel lifecycle', 'Lock or archive temporary channels after the matching event lifecycle step.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButtonFormField<String>(
          value: _lifecycleScope,
          decoration: const InputDecoration(labelText: 'Temporary channel scope'),
          items: const ['Event', 'Stage', 'Group', 'Match'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
          onChanged: (value) => setState(() => _lifecycleScope = value ?? _lifecycleScope),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _closeRule,
          decoration: const InputDecoration(labelText: 'After the lifecycle step'),
          items: const [
            DropdownMenuItem(value: 'Lock after completion', child: Text('Lock after completion')),
            DropdownMenuItem(value: 'Archive after event completion', child: Text('Archive after event completion')),
            DropdownMenuItem(value: 'Archive after cancellation', child: Text('Archive after cancellation')),
            DropdownMenuItem(value: 'Keep open until organiser closes it', child: Text('Keep open until organiser closes it')),
          ],
          onChanged: (value) => setState(() => _closeRule = value ?? _closeRule),
        ),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Lock at match/stage start', style: TextStyle(fontSize: 11)), subtitle: const Text('Stops new conversation while existing records remain visible.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _lockAtStart, onChanged: (value) => setState(() => _lockAtStart = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Archive after completion', style: TextStyle(fontSize: 11)), value: _archiveOnComplete, onChanged: (value) => setState(() => _archiveOnComplete = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Apply only to temporary event channels', style: TextStyle(fontSize: 11)), value: _temporaryOnly, onChanged: (value) => setState(() => _temporaryOnly = value)),
        const Divider(height: 1),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Preserve official match records', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)), subtitle: const Text('Match IDs, participants, results and standings are not channel data.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _preserveRecords, onChanged: null),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Preserve evidence and audit history', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)), subtitle: const Text('Screenshots, evidence and review records stay available after channel archive.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _preserveEvidence, onChanged: null),
        const SizedBox(height: 7),
        _pill('Official records are never deleted with a channel', color: const Color(0xFF54C9A5)),
      ]))),
      _section('Example lifecycle map', 'Channel access follows the configured event stage, not the other way around.'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _surface(child: const Column(children: [
        _Timeline(number: '1', title: 'Event published', detail: 'Create only the approved event template and scope access.'),
        _Timeline(number: '2', title: 'Stage / group / match begins', detail: 'Open only the corresponding temporary communication surface.'),
        _Timeline(number: '3', title: 'Reschedule or cancel', detail: 'Update or invalidate affected access and notify participants.'),
        _Timeline(number: '4', title: 'Result and dispute review', detail: 'Keep evidence and official result review in structured records.'),
        _Timeline(number: '5', title: 'Completion', detail: 'Lock or archive temporary channels and preserve match history.'),
      ]))),
    ]);
  }
}

class _ChannelDraftDialog extends StatefulWidget {
  const _ChannelDraftDialog({required this.categories, this.initialCategoryId, this.channel});
  final List<Map<String, dynamic>> categories;
  final String? initialCategoryId;
  final Map<String, dynamic>? channel;

  @override
  State<_ChannelDraftDialog> createState() => _ChannelDraftDialogState();
}

class _ChannelDraftDialogState extends State<_ChannelDraftDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late String _kind;
  late String _category;
  late bool _private;
  late bool _temporary;

  @override
  void initState() {
    super.initState();
    final row = widget.channel;
    _name = TextEditingController(text: row?['name']?.toString() ?? '');
    _description = TextEditingController(text: row?['description']?.toString() ?? '');
    _kind = row?['kind']?.toString() ?? 'text';
    _category = row?['category']?.toString() ?? widget.initialCategoryId ?? widget.categories.first['id'].toString();
    _private = row?['private'] == true;
    _temporary = row?['temporary'] == true;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.channel == null ? 'Create channel' : 'Channel settings'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _name, autofocus: true, maxLength: 50, decoration: const InputDecoration(labelText: 'Channel name')),
      TextField(controller: _description, maxLength: 240, decoration: const InputDecoration(labelText: 'Description')),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: _kind,
        decoration: const InputDecoration(labelText: 'Channel type'),
        items: const [
          DropdownMenuItem(value: 'text', child: Text('Text')),
          DropdownMenuItem(value: 'announcement', child: Text('Announcement')),
          DropdownMenuItem(value: 'forum', child: Text('Forum')),
          DropdownMenuItem(value: 'voice', child: Text('Voice')),
        ],
        onChanged: (value) => setState(() => _kind = value ?? _kind),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: _category,
        decoration: const InputDecoration(labelText: 'Category'),
        items: widget.categories.map((row) => DropdownMenuItem(value: row['id'].toString(), child: Text(row['name'].toString()))).toList(),
        onChanged: (value) => setState(() => _category = value ?? _category),
      ),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Private channel', style: TextStyle(fontSize: 11)), subtitle: const Text('Visible only to the permitted audience.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _private, onChanged: (value) => setState(() => _private = value)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Temporary event channel', style: TextStyle(fontSize: 11)), subtitle: const Text('Can be locked or archived by its lifecycle rule.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)), value: _temporary, onChanged: (value) => setState(() => _temporary = value)),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () {
          if (_name.text.trim().length < 2) {
            showMessage(context, 'Enter a channel name with at least 2 characters.');
            return;
          }
          Navigator.pop(context, {
            'name': _name.text.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-'),
            'description': _description.text.trim(),
            'kind': _kind,
            'category': _category,
            'private': _private.toString(),
            'temporary': _temporary.toString(),
          });
        },
        child: Text(widget.channel == null ? 'Add preview channel' : 'Update preview'),
      ),
    ],
  );
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.check_circle_outline, color: KomnivoTheme.cyan, size: 14),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4))),
    ]),
  );
}

class _ThreadReply extends StatelessWidget {
  const _ThreadReply({required this.author, required this.body});
  final String author;
  final String body;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const CircleAvatar(radius: 12, child: Icon(Icons.person_outline, size: 14)),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(author, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: KomnivoTheme.cyan)),
        Text(body, style: const TextStyle(fontSize: 11)),
      ])),
    ]),
  );
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.number, required this.title, required this.detail});
  final String number;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CircleAvatar(radius: 12, backgroundColor: KomnivoTheme.surfaceRaised, child: Text(number, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: KomnivoTheme.accent))),
      const SizedBox(width: 9),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9, height: 1.4)),
      ])),
    ]),
  );
}
