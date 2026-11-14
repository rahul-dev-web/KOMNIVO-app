import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
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
      final updated = await KomnivoRepository.instance.updateCommunity(
        communityId: _communityId,
        name: draft.name,
        description: draft.description,
        visibility: draft.visibility,
      );
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
    final isVoice = kind == 'voice';
    final icon = isVoice
        ? Icons.volume_up_outlined
        : kind == 'announcement'
            ? Icons.campaign_outlined
            : Icons.tag;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: ListTile(
        onTap: () => _openChannel(channel),
        leading: Icon(icon, color: isVoice ? KomnivoTheme.cyan : KomnivoTheme.muted),
        title: Text(
          channel['name']?.toString() ?? 'channel',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        subtitle: (channel['description'] ?? '').toString().isNotEmpty
            ? Text(
                channel['description'].toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11),
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_canManage)
              IconButton(
                tooltip: 'Edit channel',
                visualDensity: VisualDensity.compact,
                onPressed: () => _editChannel(channel),
                icon: const Icon(Icons.edit_outlined, size: 17, color: KomnivoTheme.muted),
              ),
            Icon(
              isVoice ? Icons.headset_mic_outlined : Icons.chevron_right_rounded,
              color: KomnivoTheme.muted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _community['name']?.toString() ?? 'Community';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
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
          final textChannels = channels
              .where((channel) => channel['kind'] == 'text' || channel['kind'] == 'announcement')
              .toList();
          final voiceChannels = channels.where((channel) => channel['kind'] == 'voice').toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
            children: [
              Container(
                padding: const EdgeInsets.all(19),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(21),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF30255D), Color(0xFF172A43), Color(0xFF101827)],
                  ),
                  border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundColor: Colors.white.withValues(alpha: .1),
                          child: Text(
                            title.isEmpty ? 'K' : title.substring(0, 1).toUpperCase(),
                            style: const TextStyle(
                              color: KomnivoTheme.cyan,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                        ),
                        if (_canManage)
                          const Icon(Icons.verified_user_outlined, color: KomnivoTheme.cyan, size: 19),
                      ],
                    ),
                    const SizedBox(height: 13),
                    Text(
                      (_community['description']?.toString().isNotEmpty == true)
                          ? _community['description'].toString()
                          : 'Welcome to the community. Pick a channel and start connecting.',
                      style: const TextStyle(color: Colors.white70, height: 1.45),
                    ),
                    const SizedBox(height: 15),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _InfoPill(
                          icon: Icons.people_outline,
                          label: (_community['member_count']?.toString() ?? '1') + ' members',
                        ),
                        _InfoPill(
                          icon: _community['visibility'] == 'private' ? Icons.lock_outline : Icons.public,
                          label: (_community['visibility'] ?? 'public').toString().toUpperCase(),
                        ),
                        if (_canManage)
                          const _InfoPill(icon: Icons.shield_outlined, label: 'OWNER / ADMIN'),
                      ],
                    ),
                  ],
                ),
              ),
              if (_canManage)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    onPressed: _editCommunity,
                    icon: const Icon(Icons.tune),
                    label: const Text('Manage community'),
                  ),
                ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.all(36),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snapshot.hasError)
                EmptyState(
                  title: 'Could not load channels',
                  message: snapshot.error.toString(),
                  icon: Icons.error_outline,
                )
              else ...[
                _sectionTitle(
                  'Text channels',
                  trailing: _canManage
                      ? TextButton.icon(
                          onPressed: _addChannel,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add'),
                        )
                      : null,
                ),
                if (textChannels.isEmpty)
                  const _EmptyChannelHint(label: 'No text channels yet.')
                else
                  ...textChannels.map(_channelTile),
                _sectionTitle(
                  'Voice channels',
                  trailing: _canManage
                      ? TextButton.icon(
                          onPressed: _addChannel,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add'),
                        )
                      : null,
                ),
                if (voiceChannels.isEmpty)
                  const _EmptyChannelHint(label: 'No voice channels yet.')
                else
                  ...voiceChannels.map(_channelTile),
              ],
              if (!_canManage)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text(
                    'Tap a text channel to open chat, or a voice channel to join the room.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
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
  const _CommunityDraft(this.name, this.description, this.visibility);
  final String name;
  final String description;
  final String visibility;
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
              Navigator.pop(context, _CommunityDraft(_name.text.trim(), _description.text.trim(), _visibility));
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
