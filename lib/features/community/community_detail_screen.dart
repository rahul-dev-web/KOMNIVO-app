import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'community_logo.dart';
import '../inbox/chat_screen.dart';
import '../inbox/voice_room_screen.dart';
import 'role_management_screen.dart';
import 'channel_studio_screen.dart';
import '../inbox/forum_channel_screen.dart';

class CommunityDetailScreen extends StatefulWidget {
  const CommunityDetailScreen({
    super.key,
    required this.community,
    this.embedded = false,
    this.onCommunityUpdated,
  });

  final Map<String, dynamic> community;
  final bool embedded;
  final VoidCallback? onCommunityUpdated;

  @override
  State<CommunityDetailScreen> createState() => _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends State<CommunityDetailScreen> {
  late Map<String, dynamic> _community;
  late Future<List<Map<String, dynamic>>> _channelsFuture;
  String _channelQuery = '';
  bool _canManageSettings = false;
  bool _canManageStructure = false;
  bool _canManageRoles = false;
  bool _canManagePermissions = false;
  bool _canManageMembers = false;
  bool _permissionsLoading = true;

  String get _communityId => _community['id'] as String;

  Future<void> _loadPermissions() async {
    final communityId = _communityId;
    try {
      final permissions = await Future.wait([
        KomnivoRepository.instance.hasPermission(
          permissionKey: 'community.manage_settings',
          scopeType: 'community',
          scopeId: communityId,
        ),
        KomnivoRepository.instance.hasPermission(
          permissionKey: 'community.manage_structure',
          scopeType: 'community',
          scopeId: communityId,
        ),
        KomnivoRepository.instance.hasPermission(
          permissionKey: 'community.manage_roles',
          scopeType: 'community',
          scopeId: communityId,
        ),
        KomnivoRepository.instance.hasPermission(
          permissionKey: 'community.manage_permissions',
          scopeType: 'community',
          scopeId: communityId,
        ),
        KomnivoRepository.instance.hasPermission(
          permissionKey: 'community.manage_members',
          scopeType: 'community',
          scopeId: communityId,
        ),
      ]);
      if (!mounted || communityId != _communityId) return;
      setState(() {
        _canManageSettings = permissions[0];
        _canManageStructure = permissions[1];
        _canManageRoles = permissions[2];
        _canManagePermissions = permissions[3];
        _canManageMembers = permissions[4];
        _permissionsLoading = false;
      });
    } catch (_) {
      if (!mounted || communityId != _communityId) return;
      setState(() {
        _canManageSettings = false;
        _canManageStructure = false;
        _canManageRoles = false;
        _canManagePermissions = false;
        _canManageMembers = false;
        _permissionsLoading = false;
      });
    }
  }

  Future<bool> _verifyPermission(String permissionKey) async {
    try {
      return await KomnivoRepository.instance.hasPermission(
        permissionKey: permissionKey,
        scopeType: 'community',
        scopeId: _communityId,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _community = Map<String, dynamic>.from(widget.community);
    _channelsFuture = KomnivoRepository.instance.channels(communityId: _communityId);
    _loadPermissions();
  }

  @override
  void didUpdateWidget(covariant CommunityDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.community['id'] != widget.community['id']) {
      _community = Map<String, dynamic>.from(widget.community);
      _channelsFuture = KomnivoRepository.instance.channels(communityId: _communityId);
      _permissionsLoading = true;
      _canManageSettings = false;
      _canManageStructure = false;
      _canManageRoles = false;
      _loadPermissions();
    } else if (oldWidget.community != widget.community) {
      _community = Map<String, dynamic>.from(widget.community);
    }
  }

  void _reloadChannels() {
    setState(() {
      _channelsFuture = KomnivoRepository.instance.channels(communityId: _communityId);
    });
  }

  Future<void> _manageRoles() async {
    if (!await _verifyPermission('community.manage_roles')) {
      if (mounted) showMessage(context, 'You do not have permission to manage community roles.');
      await _loadPermissions();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RoleManagementScreen(
          communityId: _communityId,
          communityName: _community['name']?.toString() ?? 'Community roles',
        ),
      ),
    );
    if (mounted) await _loadPermissions();
  }

  Future<void> _editCommunity() async {
    if (!await _verifyPermission('community.manage_settings')) {
      if (mounted) showMessage(context, 'You do not have permission to edit community settings.');
      await _loadPermissions();
      return;
    }
    final draft = await showDialog<_CommunityDraft>(
      context: context,
      builder: (_) => _EditCommunityDialog(community: _community),
    );
    if (draft == null || !mounted) return;
    try {
      final logoBytes = draft.logoBytes;
      final logoExtension = draft.logoExtension;
      String? logoPath;
      if (logoBytes != null && logoExtension != null) {
        // Upload the actual image bytes before writing its Storage key to
        // communities.icon_url. Never persist a path for a failed upload.
        logoPath = await KomnivoRepository.instance.uploadCommunityLogo(
          communityId: _communityId,
          bytes: logoBytes,
          extension: logoExtension,
          contentType: communityLogoMimeType(logoExtension),
        );
      }
      final updated = await KomnivoRepository.instance.updateCommunity(
        communityId: _communityId,
        name: draft.name,
        description: draft.description,
        visibility: draft.visibility,
        iconUrl: logoPath,
      );
      if (!mounted) return;
      setState(() => _community = updated);
      widget.onCommunityUpdated?.call();
      showMessage(context, 'Community details updated.');
    } catch (error) {
      if (mounted) {
        showMessage(context, 'Community update failed. The logo was not changed: $error');
      }
    }
  }

  Future<void> _addChannel() async {
    if (!await _verifyPermission('community.manage_structure')) {
      if (mounted) showMessage(context, 'You do not have permission to manage community channels.');
      await _loadPermissions();
      return;
    }
    final draft = await showDialog<_ChannelDraft>(
      context: context,
      builder: (_) => const _AddChannelDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      await KomnivoRepository.instance.createCommunityChannel(
        communityId: _communityId,
        name: draft.name,
        description: draft.description,
        kind: draft.kind,
      );
      if (!mounted) return;
      _reloadChannels();
      showMessage(context, 'Channel created.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _editChannel(Map<String, dynamic> channel) async {
    if (!await _verifyPermission('community.manage_structure')) {
      if (mounted) showMessage(context, 'You do not have permission to edit community channels.');
      await _loadPermissions();
      return;
    }
    final draft = await showDialog<_ChannelDraft>(
      context: context,
      builder: (_) => _EditChannelDialog(channel: channel),
    );
    if (draft == null || !mounted) return;
    try {
      await KomnivoRepository.instance.updateCommunityChannel(
        channelId: channel['id'] as String,
        name: draft.name,
        description: draft.description,
      );
      if (!mounted) return;
      _reloadChannels();
      showMessage(context, 'Channel updated.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _openChannelStudio(List<Map<String, dynamic>> channels) async {
    if (!await _verifyPermission('community.manage_structure')) {
      if (mounted) showMessage(context, 'You do not have permission to manage channel structure.');
      await _loadPermissions();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChannelStudioScreen(
          communityId: _communityId,
          communityName: _community['name']?.toString() ?? 'Community',
          channels: channels,
          canManagePermissions: _canManagePermissions,
        ),
      ),
    );
    if (mounted) _reloadChannels();
  }

  void _openChannel(Map<String, dynamic> channel) {
    final kind = channel['kind']?.toString() ?? 'text';
    final Widget page = kind == 'voice'
        ? VoiceRoomScreen(
            channelId: channel['id'] as String,
            channelName: channel['name']?.toString() ?? 'Voice room',
          )
        : kind == 'forum'
            ? ForumChannelScreen(
                channel: channel,
                canModerate: _canManageMembers,
              )
            : ChatScreen(channel: channel);
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));
  }

  Widget _sectionTitle(String title, {Widget? trailing}) {
    final compact = widget.embedded && MediaQuery.sizeOf(context).width < 600;
    return Padding(
        padding: EdgeInsets.fromLTRB(2, compact ? 8 : 15, 2, compact ? 4 : 7),
        child: Row(
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: KomnivoTheme.muted,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
      );
  }

  Widget _channelTile(Map<String, dynamic> channel) {
    final compact = widget.embedded && MediaQuery.sizeOf(context).width < 600;
    final kind = channel['kind']?.toString() ?? 'text';
    final name = channel['name']?.toString() ?? 'channel';
    final isVoice = kind == 'voice';
    final isForum = kind == 'forum';
    final isAnnouncement = kind == 'announcement' || name == 'announcements';
    final icon = isVoice
        ? Icons.volume_up_outlined
        : isForum
            ? Icons.forum_outlined
            : isAnnouncement
                ? Icons.campaign_outlined
                : Icons.tag;
    final tint = isVoice ? KomnivoTheme.cyan : isForum ? KomnivoTheme.accent : isAnnouncement ? KomnivoTheme.cyan : KomnivoTheme.muted;

    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KomnivoTheme.line.withValues(alpha: .75)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _openChannel(channel),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 7 : 10,
              vertical: compact ? 5 : 7,
            ),
            child: Row(
              children: [
                Container(
                  width: compact ? 28 : 34,
                  height: compact ? 28 : 34,
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surfaceRaised,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: tint, size: compact ? 15 : 18),
                ),
                SizedBox(width: compact ? 6 : 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 12 : 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (!compact &&
                          (channel['description'] ?? '').toString().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          channel['description'].toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: KomnivoTheme.muted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (channel['is_private'] == true)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.lock_outline,
                      color: KomnivoTheme.muted,
                      size: 14,
                    ),
                  ),
                if (!_permissionsLoading && _canManageStructure)
                  IconButton(
                    tooltip: 'Edit channel',
                    visualDensity: VisualDensity.compact,
                    constraints: compact
                        ? const BoxConstraints.tightFor(width: 28, height: 28)
                        : const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _editChannel(channel),
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: KomnivoTheme.muted,
                    ),
                  ),
                Icon(
                  isVoice
                      ? Icons.headset_mic_outlined
                      : Icons.chevron_right_rounded,
                  color: KomnivoTheme.muted,
                  size: 19,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _channelGroup(
    String title,
    List<Map<String, dynamic>> channels,
  ) {
    if (channels.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(title),
        ...channels.map(_channelTile),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _community['name']?.toString() ?? 'Community';
    final description =
        _community['description']?.toString().trim() ?? '';
    final compact = widget.embedded && MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Row(
          children: [
            CommunityLogo(
              name: title,
              imagePath: _community['icon_url']?.toString(),
              size: compact ? 28 : 34,
            ),
            SizedBox(width: compact ? 6 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 13 : 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Text(
                    'COMMUNITY SERVER',
                    style: TextStyle(
                      color: KomnivoTheme.muted,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!_permissionsLoading && _canManageRoles)
            IconButton(
              tooltip: 'Manage roles',
              onPressed: _manageRoles,
              icon: const Icon(Icons.admin_panel_settings_outlined),
              constraints: compact ? const BoxConstraints.tightFor(width: 34, height: 48) : const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          if (!_permissionsLoading && _canManageStructure)
            IconButton(
              tooltip: 'Channel Studio',
              onPressed: () async {
                final rows = await _channelsFuture;
                if (mounted) await _openChannelStudio(rows);
              },
              icon: const Icon(Icons.dashboard_customize_outlined),
              constraints: compact ? const BoxConstraints.tightFor(width: 34, height: 48) : const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          if (!_permissionsLoading && _canManageStructure)
            IconButton(
              tooltip: 'Create channel',
              onPressed: _addChannel,
              icon: const Icon(Icons.add_circle_outline),
              constraints: compact
                  ? const BoxConstraints.tightFor(width: 34, height: 48)
                  : const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          if (!_permissionsLoading && _canManageSettings)
            IconButton(
              tooltip: 'Edit community',
              onPressed: _editCommunity,
              icon: const Icon(Icons.settings_outlined),
              constraints: compact
                  ? const BoxConstraints.tightFor(width: 34, height: 48)
                  : const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _channelsFuture,
        builder: (context, snapshot) {
          final channels = snapshot.data ?? const <Map<String, dynamic>>[];
          final query = _channelQuery.trim().toLowerCase();
          final filteredChannels = channels.where((channel) {
            final name = channel['name']?.toString().toLowerCase() ?? '';
            final detail =
                channel['description']?.toString().toLowerCase() ?? '';
            return query.isEmpty ||
                name.contains(query) ||
                detail.contains(query);
          }).toList();

          final voiceChannels = filteredChannels
              .where((channel) => channel['kind'] == 'voice')
              .toList();
          final textChannels = filteredChannels
              .where((channel) => channel['kind'] != 'voice')
              .toList();
          final announcements = textChannels.where((channel) {
            final name = channel['name']?.toString().toLowerCase() ?? '';
            return channel['kind'] == 'announcement' ||
                name == 'announcements';
          }).toList();
          const competitiveTerms = [
            'looking-for-team',
            'team',
            'scrim',
            'tournament',
            'strategy',
            'tryout',
            'lfg',
            'match',
          ];
          final competitive = textChannels.where((channel) {
            final name = channel['name']?.toString().toLowerCase() ?? '';
            return !announcements.contains(channel) &&
                competitiveTerms.any(name.contains);
          }).toList();
          final communityChannels = textChannels.where((channel) {
            return !announcements.contains(channel) &&
                !competitive.contains(channel);
          }).toList();

          return ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 8 : 16,
              compact ? 7 : 10,
              compact ? 8 : 16,
              compact ? 16 : 28,
            ),
            children: [
              Container(
                padding: EdgeInsets.all(compact ? 11 : 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      KomnivoTheme.surfaceRaised,
                      KomnivoTheme.surface,
                    ],
                  ),
                  border: Border.all(
                    color: KomnivoTheme.accent.withValues(alpha: .28),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      description.isNotEmpty
                          ? description
                          : 'Welcome to the community. Pick a channel and start connecting.',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: compact ? 10 : 12,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 13),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        _InfoPill(
                          icon: Icons.people_outline,
                          label:
                              '${_community['member_count'] ?? 1} members',
                        ),
                        _InfoPill(
                          icon: _community['visibility'] == 'private'
                              ? Icons.lock_outline
                              : Icons.public,
                          label: _community['visibility'] == 'private'
                              ? 'INVITE ONLY'
                              : 'PUBLIC',
                        ),
                        if (!_permissionsLoading && _canManageSettings)
                          const _InfoPill(
                            icon: Icons.shield_outlined,
                            label: 'OWNER / ADMIN',
                          ),
                      ],
                    ),
                    if (!_permissionsLoading && (_canManageSettings || _canManageRoles)) ...[
                      const SizedBox(height: 13),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_canManageSettings)
                            OutlinedButton.icon(
                              onPressed: _editCommunity,
                              icon: const Icon(Icons.tune, size: 16),
                              label: const Text('Manage server'),
                              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 12)),
                            ),
                          if (_canManageStructure)
                            OutlinedButton.icon(
                              onPressed: () async {
                                final rows = await _channelsFuture;
                                if (mounted) await _openChannelStudio(rows);
                              },
                              icon: const Icon(Icons.dashboard_customize_outlined, size: 16),
                              label: const Text('Channel Studio'),
                              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 12)),
                            ),
                          if (_canManageRoles)
                            OutlinedButton.icon(
                              onPressed: _manageRoles,
                              icon: const Icon(Icons.admin_panel_settings_outlined, size: 16),
                              label: const Text('Manage roles'),
                              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 12)),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: compact ? 9 : 15),
              TextField(
                onChanged: (value) => setState(() => _channelQuery = value),
                decoration: const InputDecoration(
                  hintText: 'Search channels',
                  prefixIcon: Icon(Icons.search, size: 19),
                  isDense: true,
                ),
              ),
              SizedBox(height: compact ? 5 : 10),
              _sectionTitle(
                'Channels',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${filteredChannels.length}',
                      style: const TextStyle(
                        color: KomnivoTheme.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (!_permissionsLoading && _canManageStructure) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _addChannel,
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text('Add'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snapshot.hasError)
                EmptyState(
                  title: 'Could not load channels',
                  message: snapshot.error.toString(),
                  icon: Icons.error_outline,
                )
              else if (filteredChannels.isEmpty)
                EmptyState(
                  title: query.isEmpty
                      ? 'No channels yet'
                      : 'No matching channels',
                  message: query.isEmpty
                      ? 'Create a channel to start your community.'
                      : 'Try a different channel name.',
                  icon: Icons.tag,
                )
              else ...[
                // Grouping is a presentation rule; no channel records or roles are changed.
                _channelGroup('ANNOUNCEMENTS', announcements),
                _channelGroup('COMMUNITY', communityChannels),
                _channelGroup('COMPETITIVE', competitive),
                _channelGroup('VOICE CHANNELS', voiceChannels),
              ],
              if (!_canManageStructure)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Open a text channel to chat or join a voice channel to talk with your squad.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: KomnivoTheme.muted,
                      fontSize: 10,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CommunityDraft {
  const _CommunityDraft(
    this.name,
    this.description,
    this.visibility, {
    this.logoBytes,
    this.logoExtension,
  });
  final String name;
  final String description;
  final String visibility;
  final Uint8List? logoBytes;
  final String? logoExtension;
}

class _EditCommunityDialog extends StatefulWidget {
  const _EditCommunityDialog({required this.community});
  final Map<String, dynamic> community;

  @override
  State<_EditCommunityDialog> createState() => _EditCommunityDialogState();
}

class _EditCommunityDialogState extends State<_EditCommunityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late String _visibility;
  Uint8List? _logoBytes;
  String? _logoExtension;
  String? _logoName;

  Future<void> _pickLogo() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (!mounted || file == null) return;

    final extension = file.extension?.toLowerCase() ?? '';
    if (!const {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)) {
      showMessage(context, 'Choose a JPG, PNG or WebP image.');
      return;
    }

    final length = await file.length();
    if (!mounted) return;
    if (length == null || length == 0) {
      showMessage(context, 'Could not read the selected image. Please choose it again.');
      return;
    }
    if (length > 2 * 1024 * 1024) {
      showMessage(context, 'Community logos must be 2 MB or smaller.');
      return;
    }

    final bytes = await file.readAsBytes();
    if (!mounted) return;
    if (bytes.isEmpty) {
      showMessage(context, 'Could not read the selected image. Please choose it again.');
      return;
    }
    setState(() {
      _logoBytes = bytes;
      _logoExtension = extension;
      _logoName = file.name;
    });
  }

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.community['name']?.toString() ?? '');
    _description = TextEditingController(text: widget.community['description']?.toString() ?? '');
    _visibility = widget.community['visibility']?.toString() ?? 'public';
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Manage community'),
        content: SizedBox(
          width: 430,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Community name'),
                  validator: (value) => (value?.trim().length ?? 0) < 3
                      ? 'Enter at least 3 characters.'
                      : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  maxLength: 500,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_logoBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(_logoBytes!, width: 46, height: 46, fit: BoxFit.cover),
                      )
                    else
                      CommunityLogo(
                        name: _name.text.isEmpty ? 'Community' : _name.text,
                        imagePath: widget.community['icon_url']?.toString(),
                        size: 46,
                      ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Community logo', style: TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            _logoName ?? 'Optional · JPG, PNG or WebP · max 2 MB',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _pickLogo,
                      icon: const Icon(Icons.image_outlined, size: 17),
                      label: Text(_logoBytes == null ? 'Change' : 'Replace'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _visibility,
                  decoration: const InputDecoration(labelText: 'Community access'),
                  items: const [
                    DropdownMenuItem(value: 'public', child: Text('Public')),
                    DropdownMenuItem(value: 'private', child: Text('Private / invite only')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _visibility = value);
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!_formKey.currentState!.validate()) return;
              Navigator.pop(
                context,
                _CommunityDraft(
                  _name.text.trim(),
                  _description.text.trim(),
                  _visibility,
                  logoBytes: _logoBytes,
                  logoExtension: _logoExtension,
                ),
              );
            },
            child: const Text('Save changes'),
          ),
        ],
      );
}

class _ChannelDraft {
  const _ChannelDraft(this.name, this.description, this.kind);
  final String name;
  final String description;
  final String kind;
}

class _AddChannelDialog extends StatefulWidget {
  const _AddChannelDialog();

  @override
  State<_AddChannelDialog> createState() => _AddChannelDialogState();
}

class _AddChannelDialogState extends State<_AddChannelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  String _kind = 'text';

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Create channel'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  maxLength: 50,
                  decoration: const InputDecoration(labelText: 'Channel name', hintText: 'e.g. ranked-grind'),
                  validator: (value) => (value?.trim().length ?? 0) < 2
                      ? 'Enter at least 2 characters.'
                      : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  maxLength: 250,
                  decoration: const InputDecoration(labelText: 'Description (optional)'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _kind,
                  decoration: const InputDecoration(labelText: 'Channel type'),
                  items: const [
                    DropdownMenuItem(
                      value: 'text',
                      child: Row(children: [Icon(Icons.tag, size: 17), SizedBox(width: 8), Text('Text channel')]),
                    ),
                    DropdownMenuItem(
                      value: 'announcement',
                      child: Row(children: [Icon(Icons.campaign_outlined, size: 17), SizedBox(width: 8), Text('Announcement channel')]),
                    ),
                    DropdownMenuItem(
                      value: 'forum',
                      child: Row(children: [Icon(Icons.forum_outlined, size: 17), SizedBox(width: 8), Text('Forum channel')]),
                    ),
                    DropdownMenuItem(
                      value: 'voice',
                      child: Row(children: [Icon(Icons.volume_up_outlined, size: 17), SizedBox(width: 8), Text('Voice channel')]),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _kind = value);
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!_formKey.currentState!.validate()) return;
              Navigator.pop(context, _ChannelDraft(_name.text.trim(), _description.text.trim(), _kind));
            },
            child: const Text('Create'),
          ),
        ],
      );
}

class _EditChannelDialog extends StatefulWidget {
  const _EditChannelDialog({required this.channel});
  final Map<String, dynamic> channel;

  @override
  State<_EditChannelDialog> createState() => _EditChannelDialogState();
}

class _EditChannelDialogState extends State<_EditChannelDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.channel['name']?.toString() ?? '');
    _description = TextEditingController(text: widget.channel['description']?.toString() ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit channel'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 50,
                  decoration: const InputDecoration(labelText: 'Channel name'),
                  validator: (value) => (value?.trim().length ?? 0) < 2
                      ? 'Enter at least 2 characters.'
                      : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  maxLength: 250,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!_formKey.currentState!.validate()) return;
              Navigator.pop(
                context,
                _ChannelDraft(_name.text.trim(), _description.text.trim(), widget.channel['kind']?.toString() ?? 'text'),
              );
            },
            child: const Text('Save changes'),
          ),
        ],
      );
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: KomnivoTheme.cyan),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w800)),
          ],
        ),
      );
}
