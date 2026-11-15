import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'community_logo.dart';
import '../inbox/chat_screen.dart';
import '../inbox/voice_room_screen.dart';

class CommunityDetailScreen extends StatefulWidget {
  const CommunityDetailScreen({
    super.key,
    required this.community,
    required this.canManage,
  });

  final Map<String, dynamic> community;
  final bool canManage;

  @override
  State<CommunityDetailScreen> createState() => _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends State<CommunityDetailScreen> {
  late Map<String, dynamic> _community;
  late Future<List<Map<String, dynamic>>> _channelsFuture;
  String _channelQuery = '';

  String get _communityId => _community['id'] as String;
  bool get _canManage =>
      widget.canManage ||
      _community['owner_user_id'] == Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _community = Map<String, dynamic>.from(widget.community);
    _channelsFuture = KomnivoRepository.instance.channels(communityId: _communityId);
  }

  void _reloadChannels() {
    setState(() {
      _channelsFuture = KomnivoRepository.instance.channels(communityId: _communityId);
    });
  }

  Future<void> _editCommunity() async {
    final draft = await showDialog<_CommunityDraft>(
      context: context,
      builder: (_) => _EditCommunityDialog(community: _community),
    );
    if (draft == null || !mounted) return;
    try {
      var updated = await KomnivoRepository.instance.updateCommunity(
        communityId: _communityId,
        name: draft.name,
        description: draft.description,
        visibility: draft.visibility,
      );
      final logoBytes = draft.logoBytes;
      final logoExtension = draft.logoExtension;
      if (logoBytes != null && logoExtension != null) {
        try {
          final logoPath = await KomnivoRepository.instance.uploadCommunityLogo(
            communityId: _communityId,
            bytes: logoBytes,
            extension: logoExtension,
            contentType: communityLogoMimeType(logoExtension),
          );
          updated = await KomnivoRepository.instance.updateCommunity(
            communityId: _communityId,
            name: draft.name,
            description: draft.description,
            visibility: draft.visibility,
            iconUrl: logoPath,
          );
        } catch (error) {
          showMessage(context, 'Community details were saved, but logo upload failed: $error');
        }
      }
      if (!mounted) return;
      setState(() => _community = updated);
      showMessage(context, 'Community details updated.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _addChannel() async {
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

  void _openChannel(Map<String, dynamic> channel) {
    final kind = channel['kind']?.toString() ?? 'text';
    final Widget page = kind == 'voice'
        ? VoiceRoomScreen(
            channelId: channel['id'] as String,
            channelName: channel['name']?.toString() ?? 'Voice room',
          )
        : ChatScreen(channel: channel);
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));
  }

  Widget _sectionTitle(String title, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 18, 2, 9),
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

  Widget _channelTile(Map<String, dynamic> channel) {
    final kind = channel['kind']?.toString() ?? 'text';
    final name = channel['name']?.toString() ?? 'channel';
    final isVoice = kind == 'voice';
    final isAnnouncement = kind == 'announcement' || name == 'announcements';
    final icon = isVoice
        ? Icons.volume_up_outlined
        : isAnnouncement
            ? Icons.campaign_outlined
            : Icons.tag;
    final tint = isVoice ? KomnivoTheme.cyan : KomnivoTheme.muted;

    return Container(
      margin: const EdgeInsets.only(bottom: 5),
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surfaceRaised,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: tint, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if ((channel['description'] ?? '').toString().isNotEmpty) ...[
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
                if (_canManage)
                  IconButton(
                    tooltip: 'Edit channel',
                    visualDensity: VisualDensity.compact,
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
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CommunityLogo(
              name: title,
              imagePath: _community['icon_url']?.toString(),
              size: 34,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
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
          if (_canManage)
            IconButton(
              tooltip: 'Create channel',
              onPressed: _addChannel,
              icon: const Icon(Icons.add_circle_outline),
            ),
          if (_canManage)
            IconButton(
              tooltip: 'Edit community',
              onPressed: _editCommunity,
              icon: const Icon(Icons.settings_outlined),
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
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
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.45,
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
                        if (_canManage)
                          const _InfoPill(
                            icon: Icons.shield_outlined,
                            label: 'OWNER / ADMIN',
                          ),
                      ],
                    ),
                    if (_canManage) ...[
                      const SizedBox(height: 13),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _editCommunity,
                          icon: const Icon(Icons.tune, size: 16),
                          label: const Text('Manage server'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 38),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 15),
              TextField(
                onChanged: (value) => setState(() => _channelQuery = value),
                decoration: const InputDecoration(
                  hintText: 'Search channels',
                  prefixIcon: Icon(Icons.search, size: 19),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 13),
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
                    if (_canManage) ...[
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
              if (!_canManage)
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

class _EmptyChannelHint extends StatelessWidget {
  const _EmptyChannelHint({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      );
}
