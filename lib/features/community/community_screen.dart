import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'community_detail_screen.dart';
import 'community_logo.dart';

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key, required this.preview});
  final bool preview;

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  Future<_DirectoryData>? _future;
  final Set<String> _joining = <String>{};

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _future = _load();
  }

  Future<_DirectoryData> _load() async {
    final communitiesFuture = KomnivoRepository.instance.communities();
    final membershipsFuture = KomnivoRepository.instance.myCommunityMemberships();
    return _DirectoryData(
      await communitiesFuture,
      await membershipsFuture,
    );
  }

  void _refresh() => setState(() => _future = _load());

  Future<void> _create() async {
    final draft = await showDialog<_CommunityDraft>(
      context: context,
      builder: (_) => const _CreateCommunityDialog(),
    );
    if (draft == null || !mounted) return;

    try {
      final response = await KomnivoRepository.instance.createCommunity(
        name: draft.name,
        description: draft.description,
        isPublic: draft.visibility == 'public',
      );
      final raw = response['community'];
      if (raw is! Map) throw Exception('Community created, but its details could not be loaded.');
      var community = Map<String, dynamic>.from(raw);
      if (!mounted) return;

      final logoBytes = draft.logoBytes;
      final logoExtension = draft.logoExtension;
      if (logoBytes != null && logoExtension != null) {
        try {
          final logoPath = await KomnivoRepository.instance.uploadCommunityLogo(
            communityId: community['id'].toString(),
            bytes: logoBytes,
            extension: logoExtension,
            contentType: communityLogoMimeType(logoExtension),
          );
          community = await KomnivoRepository.instance.updateCommunity(
            communityId: community['id'].toString(),
            name: community['name']?.toString() ?? draft.name,
            description: community['description']?.toString() ?? draft.description,
            visibility: community['visibility']?.toString() ?? draft.visibility,
            iconUrl: logoPath,
          );
        } catch (error) {
          showMessage(context, 'Community created, but logo upload failed. You can add it from Manage community. $error');
        }
      }

      // DB trigger creates the owner membership and standard channels.
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CommunityDetailScreen(community: community, canManage: true),
        ),
      );
      if (!mounted) return;
      _refresh();
      showMessage(context, 'Community created successfully.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _join(Map<String, dynamic> community) async {
    final id = community['id']?.toString() ?? '';
    if (id.isEmpty || _joining.contains(id)) return;
    setState(() => _joining.add(id));
    try {
      await KomnivoRepository.instance.joinCommunity(id);
      if (!mounted) return;
      setState(() {
        _joining.remove(id);
        _future = _load();
      });
      showMessage(context, 'Joined ' + (community['name']?.toString() ?? 'community') + '.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _joining.remove(id));
      showMessage(context, error.toString());
    }
  }

  void _open(
    Map<String, dynamic> community,
    Map<String, dynamic>? membership,
  ) {
    final role = membership?['role']?.toString() ?? 'member';
    final currentUser = Supabase.instance.client.auth.currentUser?.id;
    final canManage = community['owner_user_id'] == currentUser ||
        const {'owner', 'admin', 'moderator', 'organiser'}.contains(role);
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CommunityDetailScreen(
          community: community,
          canManage: canManage,
        ),
      ),
    ).then((_) {
      if (mounted) _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          PreviewBanner(),
          SectionTitle('Communities', subtitle: 'Discover your next squad space'),
          SizedBox(height: 14),
          _PreviewCommunityCard(
            name: 'KOMNIVO India Esports',
            description: 'Scrims, squads, Free Fire MAX and match updates.',
            members: '2.4K',
          ),
          _PreviewCommunityCard(
            name: 'Night Owls Gaming',
            description: 'Late-night customs and competitive practice.',
            members: '860',
          ),
          _PreviewCommunityCard(
            name: 'Rank Push Collective',
            description: 'Find teammates and improve together.',
            members: '1.2K',
          ),
        ],
      );
    }

    return FutureBuilder<_DirectoryData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final rows = data?.communities ?? const <Map<String, dynamic>>[];
        final memberships = data?.memberships ?? const <String, Map<String, dynamic>>{};
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SectionTitle(
              'Communities',
              subtitle: 'Your gaming spaces, organised like servers',
              trailing: FilledButton.icon(
                onPressed: snapshot.connectionState == ConnectionState.waiting && data == null ? null : _create,
                icon: const Icon(Icons.add),
                label: const Text('Create'),
              ),
            ),
            const SizedBox(height: 16),
            if (snapshot.connectionState == ConnectionState.waiting && data == null)
              const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()))
            else if (snapshot.hasError)
              EmptyState(
                title: 'Could not load communities',
                message: snapshot.error.toString(),
                icon: Icons.error_outline,
              )
            else if (rows.isEmpty)
              const EmptyState(
                title: 'No communities yet',
                message: 'Create your own space or join a public community to get started.',
                icon: Icons.groups_outlined,
              )
            else
              ...rows.map((row) {
                final id = row['id']?.toString() ?? '';
                final membership = memberships[id];
                return _CommunityDataCard(
                  row: row,
                  membership: membership,
                  joining: _joining.contains(id),
                  onJoin: () => _join(row),
                  onOpen: () => _open(row, membership),
                );
              }),
          ],
        );
      },
    );
  }
}

class _DirectoryData {
  const _DirectoryData(this.communities, this.memberships);
  final List<Map<String, dynamic>> communities;
  final Map<String, Map<String, dynamic>> memberships;
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

class _CreateCommunityDialog extends StatefulWidget {
  const _CreateCommunityDialog();

  @override
  State<_CreateCommunityDialog> createState() => _CreateCommunityDialogState();
}

class _CreateCommunityDialogState extends State<_CreateCommunityDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  String _visibility = 'public';
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
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Row(
          children: [
            CircleAvatar(
              backgroundColor: KomnivoTheme.surfaceRaised,
              child: Icon(Icons.groups_rounded, color: KomnivoTheme.cyan),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Create your community')),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Set up a home for your squad, scrims and players.',
                    style: TextStyle(color: KomnivoTheme.muted, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _name,
                    autofocus: true,
                    maxLength: 60,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Community name',
                      hintText: 'e.g. IGL Esports',
                      prefixIcon: Icon(Icons.groups_outlined),
                    ),
                    validator: (value) {
                      final name = value?.trim() ?? '';
                      if (name.length < 3) return 'Enter at least 3 characters.';
                      if (name.length > 60) return 'Keep the name within 60 characters.';
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _description,
                    maxLength: 500,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'About this community',
                      hintText: 'What is this space for?',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (_logoBytes != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(13),
                          child: Image.memory(_logoBytes!, width: 48, height: 48, fit: BoxFit.cover),
                        )
                      else
                        CommunityLogo(
                          name: _name.text.isEmpty ? 'Community' : _name.text,
                          size: 48,
                        ),
                      const SizedBox(width: 12),
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
                        label: Text(_logoBytes == null ? 'Add' : 'Change'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _visibility,
                    decoration: const InputDecoration(
                      labelText: 'Who can join?',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'public', child: Text('Public — anyone can join')),
                      DropdownMenuItem(value: 'private', child: Text('Private — invite only')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _visibility = value);
                    },
                  ),
                  const SizedBox(height: 17),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: KomnivoTheme.surface,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: KomnivoTheme.line),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DEFAULT CHANNELS',
                          style: TextStyle(
                            color: KomnivoTheme.cyan,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                          ),
                        ),
                        SizedBox(height: 10),
                        _TemplateChannel(icon: Icons.campaign_outlined, name: 'announcements'),
                        _TemplateChannel(icon: Icons.tag, name: 'general'),
                        _TemplateChannel(icon: Icons.tag, name: 'looking-for-team'),
                        _TemplateChannel(icon: Icons.tag, name: 'scrim-hub'),
                        _TemplateChannel(icon: Icons.volume_up_outlined, name: 'voice-lounge'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'You are added as the owner automatically. You can edit the community and channels later.',
                    style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton.icon(
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
            icon: const Icon(Icons.add),
            label: const Text('Create community'),
          ),
        ],
      );
}

class _TemplateChannel extends StatelessWidget {
  const _TemplateChannel({required this.icon, required this.name});
  final IconData icon;
  final String name;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          children: [
            Icon(icon, size: 16, color: KomnivoTheme.muted),
            const SizedBox(width: 9),
            Text(name, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}

class _PreviewCommunityCard extends StatelessWidget {
  const _PreviewCommunityCard({
    required this.name,
    required this.description,
    required this.members,
  });
  final String name;
  final String description;
  final String members;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Row(
          children: [
            CommunityLogo(name: name, size: 48),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(description, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                  const SizedBox(height: 5),
                  Text('$members members',
                    style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: KomnivoTheme.muted),
          ],
        ),
      );
}

class _CommunityDataCard extends StatelessWidget {
  const _CommunityDataCard({
    required this.row,
    required this.membership,
    required this.joining,
    required this.onJoin,
    required this.onOpen,
  });

  final Map<String, dynamic> row;
  final Map<String, dynamic>? membership;
  final bool joining;
  final VoidCallback onJoin;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final joined = membership != null;
    final isPublic = (row['visibility']?.toString() ?? 'public') == 'public';
    final role = membership?['role']?.toString() ?? 'member';
    final name = row['name']?.toString() ?? 'Community';
    final description = row['description']?.toString() ?? '';
    final count = row['member_count']?.toString() ?? '1';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: joined
              ? KomnivoTheme.accent.withValues(alpha: .42)
              : KomnivoTheme.line,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: joined ? onOpen : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                CommunityLogo(
                  name: name,
                  imagePath: row['icon_url']?.toString(),
                  size: 49,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (joined)
                            _MembershipBadge(
                              label: role == 'owner' ? 'OWNER' : role.toUpperCase(),
                            )
                          else
                            _MembershipBadge(label: isPublic ? 'PUBLIC' : 'PRIVATE'),
                        ],
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: KomnivoTheme.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.people_outline,
                            size: 13,
                            color: KomnivoTheme.muted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$count members',
                            style: const TextStyle(
                              color: KomnivoTheme.muted,
                              fontSize: 10,
                            ),
                          ),
                          if (!isPublic) ...[
                            const SizedBox(width: 9),
                            const Icon(Icons.lock_outline, size: 12, color: KomnivoTheme.muted),
                            const SizedBox(width: 3),
                            const Text(
                              'Invite only',
                              style: TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
                if (joined)
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: KomnivoTheme.cyan,
                    size: 22,
                  )
                else if (isPublic)
                  TextButton(
                    onPressed: joining ? null : onJoin,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(52, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: joining
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Join', style: TextStyle(fontWeight: FontWeight.w800)),
                  )
                else
                  const Icon(Icons.lock_outline, color: KomnivoTheme.muted, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MembershipBadge extends StatelessWidget {
  const _MembershipBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: KomnivoTheme.accent.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w900),
        ),
      );
}
