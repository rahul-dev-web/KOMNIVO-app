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
import 'community_operations_screen.dart';
import 'community_channel_grouping.dart';
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
  late Future<_CommunityChannelStructure> _channelsFuture;
  String _channelQuery = '';
  final Set<String> _collapsedChannelGroupIds = <String>{};
  bool _canManageSettings = false;
  bool _canManageStructure = false;
  bool _canManageRoles = false;
  bool _canManagePermissions = false;
  bool _permissionsLoading = true;

  String get _communityId => _community['id'] as String;

  Future<_CommunityChannelStructure> _loadChannelStructure() async {
    final channelsFuture =
        KomnivoRepository.instance.channels(communityId: _communityId);
    final categoriesFuture =
        KomnivoRepository.instance.channelCategories(_communityId);

    final channels = await channelsFuture;
    var categories = <Map<String, dynamic>>[];
    try {
      categories = await categoriesFuture;
    } catch (_) {
      // Some public viewers can read a channel but not its category metadata.
      // Keep the channel list available and present these channels as
      // uncategorized rather than failing the entire community screen.
    }

    return _CommunityChannelStructure(
      channels: channels,
      categories: categories,
    );
  }

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
      ]);
      if (!mounted || communityId != _communityId) return;
      setState(() {
        _canManageSettings = permissions[0];
        _canManageStructure = permissions[1];
        _canManageRoles = permissions[2];
        _canManagePermissions = permissions[3];
        _permissionsLoading = false;
      });
    } catch (_) {
      if (!mounted || communityId != _communityId) return;
      setState(() {
        _canManageSettings = false;
        _canManageStructure = false;
        _canManageRoles = false;
        _canManagePermissions = false;
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
    _channelsFuture = _loadChannelStructure();
    _loadPermissions();
  }

  @override
  void didUpdateWidget(covariant CommunityDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.community['id'] != widget.community['id']) {
      _community = Map<String, dynamic>.from(widget.community);
      _channelsFuture = _loadChannelStructure();
      _collapsedChannelGroupIds.clear();
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
      _channelsFuture = _loadChannelStructure();
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

  Future<void> _openCommunityOperations() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CommunityOperationsScreen(
          community: _community,
          onOpenChannel: _openChannel,
          onOpenChannelStudio: () async {
            if (!await _verifyPermission('community.manage_structure')) {
              if (mounted) showMessage(context, 'You do not have permission to manage channel safety settings.');
              await _loadPermissions();
              return;
            }
            final structure = await _channelsFuture;
            if (mounted) await _openChannelStudio(structure.channels);
          },
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
    final allChannels = await KomnivoRepository.instance.channels(
      communityId: _communityId,
      includeArchivedChannels: true,
      includeArchivedCategories: true,
    );
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChannelStudioScreen(
          communityId: _communityId,
          communityName: _community['name']?.toString() ?? 'Community',
          channels: allChannels.isEmpty ? channels : allChannels,
          canManagePermissions: _canManagePermissions,
        ),
      ),
    );
    if (mounted) _reloadChannels();
  }

  Future<void> _openChannel(Map<String, dynamic> channel) async {
    final kind = channel['kind']?.toString() ?? 'text';
    var canModerate = false;
    try {
      canModerate = await KomnivoRepository.instance.canManageChannelMessages(
        channel['id'].toString(),
      );
    } catch (_) {
      canModerate = false;
    }
    if (!mounted) return;
    final Widget page = kind == 'voice'
        ? VoiceRoomScreen(
            channelId: channel['id'] as String,
            channelName: channel['name']?.toString() ?? 'Voice room',
          )
        : kind == 'forum'
            ? ForumChannelScreen(
                channel: channel,
                canModerate: canModerate,
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
        ? Icons.graphic_eq_rounded
        : isForum
            ? Icons.forum_rounded
            : isAnnouncement
                ? Icons.campaign_rounded
                : Icons.tag_rounded;
    final tint = isVoice
        ? KomnivoTheme.cyan
        : isForum
            ? KomnivoTheme.accent
            : isAnnouncement
                ? KomnivoTheme.cyan
                : KomnivoTheme.muted;
    final kindLabel = isVoice
        ? 'VOICE ROOM'
        : isForum
            ? 'COMMUNITY FORUM'
            : isAnnouncement
                ? 'OFFICIAL UPDATES'
                : 'TEXT CHAT';

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [KomnivoTheme.surfaceRaised.withValues(alpha: .9), KomnivoTheme.surface],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: KomnivoTheme.line.withValues(alpha: .85)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => _openChannel(channel),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12, vertical: compact ? 7 : 9),
            child: Row(children: [
              Container(
                width: compact ? 34 : 42,
                height: compact ? 34 : 42,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [tint.withValues(alpha: .18), tint.withValues(alpha: .07)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: tint.withValues(alpha: .20)),
                ),
                child: Icon(icon, color: tint, size: compact ? 17 : 20),
              ),
              SizedBox(width: compact ? 8 : 11),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: compact ? 12 : 13, fontWeight: FontWeight.w900))),
                  if (channel['is_private'] == true) ...[
                    const SizedBox(width: 5),
                    const Icon(Icons.lock_rounded, color: KomnivoTheme.muted, size: 12),
                  ],
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Container(width: 5, height: 5, decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(kindLabel, style: TextStyle(color: tint, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .7)),
                  if (!compact && (channel['description'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(width: 7),
                    const Text('·', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                    const SizedBox(width: 5),
                    Expanded(child: Text(channel['description'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9))),
                  ],
                ]),
              ])),
              if (!_permissionsLoading && _canManageStructure)
                IconButton(
                  tooltip: 'Edit channel',
                  visualDensity: VisualDensity.compact,
                  constraints: compact ? const BoxConstraints.tightFor(width: 30, height: 30) : const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: () => _editChannel(channel),
                  icon: const Icon(Icons.tune_rounded, size: 16, color: KomnivoTheme.muted),
                ),
              Icon(isVoice ? Icons.arrow_forward_ios_rounded : Icons.chevron_right_rounded,
                color: tint.withValues(alpha: .8), size: 17),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _channelGroup(
    String title,
    List<Map<String, dynamic>> channels, {
    required String groupId,
  }) {
    if (channels.isEmpty) return const SizedBox.shrink();
    final compact = widget.embedded && MediaQuery.sizeOf(context).width < 600;
    final filtering = _channelQuery.trim().isNotEmpty;
    final collapsed = !filtering && _collapsedChannelGroupIds.contains(groupId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(2, compact ? 8 : 15, 2, compact ? 4 : 7),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: filtering
                  ? null
                  : () {
                      setState(() {
                        if (collapsed) {
                          _collapsedChannelGroupIds.remove(groupId);
                        } else {
                          _collapsedChannelGroupIds.add(groupId);
                        }
                      });
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: Row(
                  children: [
                    Icon(
                      collapsed
                          ? Icons.chevron_right_rounded
                          : Icons.expand_more_rounded,
                      color: KomnivoTheme.muted,
                      size: 19,
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        title.toUpperCase(),
                        style: const TextStyle(
                          color: KomnivoTheme.muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                    Text(
                      channels.length.toString(),
                      style: const TextStyle(
                        color: KomnivoTheme.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!collapsed) ...channels.map(_channelTile),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _community['name']?.toString() ?? 'Community';
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.people_outline,
                        size: 11,
                        color: KomnivoTheme.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${_community['member_count'] ?? 1} members',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: KomnivoTheme.muted,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Community tools',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == 'members_safety') {
                _openCommunityOperations();
              } else if (value == 'manage_roles') {
                _manageRoles();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'members_safety',
                child: Row(
                  children: [
                    Icon(Icons.groups_2_outlined, size: 18),
                    SizedBox(width: 9),
                    Text('Members & safety'),
                  ],
                ),
              ),
              if (!_permissionsLoading && _canManageRoles)
                const PopupMenuItem<String>(
                  value: 'manage_roles',
                  child: Row(
                    children: [
                      Icon(Icons.admin_panel_settings_outlined, size: 18),
                      SizedBox(width: 9),
                      Text('Manage roles'),
                    ],
                  ),
                ),
            ],
          ),
          if (!_permissionsLoading && _canManageStructure)
            IconButton(
              tooltip: 'Channel Studio',
              onPressed: () async {
                final structure = await _channelsFuture;
                if (mounted) await _openChannelStudio(structure.channels);
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
      body: FutureBuilder<_CommunityChannelStructure>(
        future: _channelsFuture,
        builder: (context, snapshot) {
          final structure = snapshot.data;
          final channels = structure?.channels ?? const <Map<String, dynamic>>[];
          final categories = structure?.categories ?? const <Map<String, dynamic>>[];
          final query = _channelQuery.trim().toLowerCase();
          final channelGroups = buildCommunityChannelGroups(
            categories: categories,
            channels: channels,
            query: query,
          );
          final visibleChannelCount = channelGroups.fold<int>(
            0,
            (total, group) => total + group.channels.length,
          );

          return ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 8 : 16,
              compact ? 7 : 10,
              compact ? 8 : 16,
              compact ? 16 : 28,
            ),
            children: [
              SizedBox(height: compact ? 4 : 8),
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
                      '${visibleChannelCount}',
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
              else if (channelGroups.isEmpty)
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
                // Display the saved Channel Studio category/channel relationships.
                // Text, announcement, forum and voice channels stay under their event category.
                ...channelGroups.map(
                  (group) => _channelGroup(
                    group.title,
                    group.channels,
                    groupId: group.categoryId ?? '__uncategorized__',
                  ),
                ),
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

class _CommunityChannelStructure {
  const _CommunityChannelStructure({
    required this.channels,
    required this.categories,
  });

  final List<Map<String, dynamic>> channels;
  final List<Map<String, dynamic>> categories;
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
