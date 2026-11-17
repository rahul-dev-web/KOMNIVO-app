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
  final TextEditingController _searchController = TextEditingController();
  String _scope = 'all';
  String? _selectedCommunityId;

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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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

      // The database trigger creates the owner membership and standard channels.
      final createdId = community['id']?.toString();
      if (createdId != null && createdId.isNotEmpty) {
        _selectedCommunityId = createdId;
      }

      // Keep the server list and selected community side by side on phones,
      // tablets and desktop. Only very narrow viewports use the detail route.
      if (MediaQuery.sizeOf(context).width >= 320) {
        _refresh();
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => CommunityDetailScreen(
              community: community,
              canManage: true,
            ),
          ),
        );
        if (!mounted) return;
        _refresh();
      }
      if (!mounted) return;
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
        _selectedCommunityId = id;
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
    final id = community['id']?.toString() ?? '';
    if (MediaQuery.sizeOf(context).width >= 320) {
      setState(() => _selectedCommunityId = id);
      return;
    }
    if (membership == null) return;

    final role = membership['role']?.toString() ?? 'member';
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

  Future<void> _showCommunitySearch() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Find a community'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: _searchController,
            autofocus: true,
            onChanged: (_) {
              if (mounted) setState(() {});
            },
            onSubmitted: (_) => Navigator.of(dialogContext).pop(),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search by community name or description',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _searchController.clear();
              if (mounted) setState(() {});
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _railHeader({
    required int total,
    required int joined,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(7, 10, 7, 9),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        border: Border(
          bottom: BorderSide(color: KomnivoTheme.line.withValues(alpha: .8)),
        ),
      ),
      child: Column(
        children: [
          IconButton.filledTonal(
            tooltip: 'Search communities',
            onPressed: _showCommunitySearch,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.search_rounded, size: 19),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(42),
              maximumSize: const Size.square(42),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          const SizedBox(height: 7),
          PopupMenuButton<String>(
            tooltip: 'Filter communities',
            initialValue: _scope,
            onSelected: (value) => setState(() => _scope = value),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'all',
                child: Text('All communities ($total)'),
              ),
              PopupMenuItem(
                value: 'joined',
                child: Text('Joined ($joined)'),
              ),
              const PopupMenuItem(
                value: 'discover',
                child: Text('Discover'),
              ),
            ],
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: KomnivoTheme.surfaceRaised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _scope == 'all'
                      ? KomnivoTheme.line
                      : KomnivoTheme.accent.withValues(alpha: .65),
                ),
              ),
              child: Icon(
                Icons.filter_list_rounded,
                size: 19,
                color: _scope == 'all' ? KomnivoTheme.muted : KomnivoTheme.cyan,
              ),
            ),
          ),
          const SizedBox(height: 7),
          IconButton.filledTonal(
            tooltip: 'Create community',
            onPressed: _create,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_rounded, size: 20),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(42),
              maximumSize: const Size.square(42),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _communityRail({
    required List<Map<String, dynamic>> communities,
    required Map<String, Map<String, dynamic>> memberships,
    required String? selectedId,
  }) {
    return RefreshIndicator(
      onRefresh: () async {
        final next = _load();
        setState(() => _future = next);
        try {
          await next;
        } catch (_) {
          // FutureBuilder displays the refreshed error.
        }
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 9),
        itemCount: communities.isEmpty ? 1 : communities.length,
        itemBuilder: (context, index) {
          if (communities.isEmpty) {
            return SizedBox(
              height: 76,
              child: Tooltip(
                message: _searchController.text.trim().isNotEmpty
                    ? 'No matching communities'
                    : 'No communities in this filter',
                child: const Icon(
                  Icons.groups_outlined,
                  color: KomnivoTheme.muted,
                  size: 22,
                ),
              ),
            );
          }

          final row = communities[index];
          final id = row['id']?.toString() ?? '';
          return _CommunityRailTile(
            row: row,
            joined: memberships.containsKey(id),
            selected: id == selectedId,
            onOpen: () => _open(row, memberships[id]),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preview) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
        children: const [
          PreviewBanner(),
          SectionTitle(
            'Community',
            subtitle: 'Your servers. Your squads. Your space.',
          ),
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
        final memberships = data?.memberships ??
            const <String, Map<String, dynamic>>{};
        final query = _searchController.text.trim().toLowerCase();

        final filteredRows = rows.where((row) {
          final name = row['name']?.toString().toLowerCase() ?? '';
          final description = row['description']?.toString().toLowerCase() ?? '';
          final matchesQuery = query.isEmpty ||
              name.contains(query) ||
              description.contains(query);
          if (!matchesQuery) return false;

          final id = row['id']?.toString() ?? '';
          final joined = memberships.containsKey(id);
          if (_scope == 'joined') return joined;
          if (_scope == 'discover') return !joined;
          return true;
        }).toList();

        final joinedRows = filteredRows.where((row) {
          return memberships.containsKey(row['id']?.toString() ?? '');
        }).toList();
        final discoverRows = filteredRows.where((row) {
          return !memberships.containsKey(row['id']?.toString() ?? '');
        }).toList();
        final directoryRows = [...joinedRows, ...discoverRows];

        Map<String, dynamic>? selectedCommunity;
        if (_selectedCommunityId != null) {
          for (final row in directoryRows) {
            if (row['id']?.toString() == _selectedCommunityId) {
              selectedCommunity = row;
              break;
            }
          }
        }
        selectedCommunity ??= joinedRows.isNotEmpty
            ? joinedRows.first
            : (directoryRows.isNotEmpty ? directoryRows.first : null);

        final screenWidth = MediaQuery.sizeOf(context).width;
        final railWidth = screenWidth < 400 ? 66.0 : (screenWidth < 600 ? 74.0 : 82.0);

        Widget railContent;
        if (snapshot.connectionState == ConnectionState.waiting && data == null) {
          railContent = const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        } else if (snapshot.hasError) {
          railContent = const Center(
            child: Tooltip(
              message: 'Could not load communities',
              child: Icon(Icons.error_outline, color: KomnivoTheme.muted),
            ),
          );
        } else {
          railContent = _communityRail(
            communities: directoryRows,
            memberships: memberships,
            selectedId: selectedCommunity?['id']?.toString(),
          );
        }

        final selectedMembership = selectedCommunity == null
            ? null
            : memberships[selectedCommunity['id']?.toString() ?? ''];
        final rightPane = selectedCommunity == null
            ? const _CommunityWelcomePane()
            : selectedMembership != null
                ? CommunityDetailScreen(
                    key: ValueKey(selectedCommunity['id']),
                    community: selectedCommunity,
                    canManage: selectedCommunity['owner_user_id'] ==
                            Supabase.instance.client.auth.currentUser?.id ||
                        const {'owner', 'admin', 'moderator', 'organiser'}
                            .contains(selectedMembership['role']?.toString()),
                    embedded: true,
                    onCommunityUpdated: _refresh,
                  )
                : _CommunityPreviewPane(
                    key: ValueKey(selectedCommunity['id']),
                    community: selectedCommunity,
                    joining: _joining.contains(
                      selectedCommunity['id']?.toString() ?? '',
                    ),
                    onJoin: () => _join(selectedCommunity!),
                  );

        return Row(
          children: [
            SizedBox(
              width: railWidth,
              child: Container(
                color: KomnivoTheme.surface,
                child: Column(
                  children: [
                    _railHeader(total: rows.length, joined: memberships.length),
                    Expanded(child: railContent),
                  ],
                ),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: KomnivoTheme.line.withValues(alpha: .8),
            ),
            Expanded(child: rightPane),
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

class _CommunityRailTile extends StatelessWidget {
  const _CommunityRailTile({
    required this.row,
    required this.joined,
    required this.selected,
    required this.onOpen,
  });

  final Map<String, dynamic> row;
  final bool joined;
  final bool selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final name = row['name']?.toString() ?? 'Community';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      child: Tooltip(
        message: name,
        waitDuration: const Duration(milliseconds: 350),
        child: SizedBox(
          width: 52,
          height: 54,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Material(
                  color: selected
                      ? KomnivoTheme.accent.withValues(alpha: .18)
                      : KomnivoTheme.surfaceRaised.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    onTap: onOpen,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: CommunityLogo(
                        name: name,
                        imagePath: row['icon_url']?.toString(),
                        size: 46,
                      ),
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  left: -7,
                  top: 11,
                  bottom: 11,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: KomnivoTheme.cyan,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              if (joined)
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: KomnivoTheme.cyan,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: KomnivoTheme.surface,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommunityPreviewPane extends StatelessWidget {
  const _CommunityPreviewPane({
    super.key,
    required this.community,
    required this.joining,
    required this.onJoin,
  });

  final Map<String, dynamic> community;
  final bool joining;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final name = community['name']?.toString() ?? 'Community';
    final description = community['description']?.toString().trim() ?? '';
    final isPublic = (community['visibility']?.toString() ?? 'public') == 'public';
    final compact = MediaQuery.sizeOf(context).width < 600;

    return Container(
      color: KomnivoTheme.background,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(
              compact ? 9 : 20,
              compact ? 10 : 15,
              compact ? 9 : 20,
              compact ? 10 : 15,
            ),
            decoration: BoxDecoration(
              color: KomnivoTheme.surface,
              border: Border(
                bottom: BorderSide(color: KomnivoTheme.line.withValues(alpha: .8)),
              ),
            ),
            child: Row(
              children: [
                CommunityLogo(
                  name: name,
                  imagePath: community['icon_url']?.toString(),
                  size: compact ? 28 : 40,
                ),
                SizedBox(width: compact ? 6 : 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 11 : 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Text(
                        'COMMUNITY SERVER',
                        style: TextStyle(
                          color: KomnivoTheme.muted,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isPublic)
                  FilledButton.icon(
                    onPressed: joining ? null : onJoin,
                    icon: joining
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add, size: 17),
                    label: const Text('Join'),
                    style: FilledButton.styleFrom(
                      minimumSize: Size(0, compact ? 32 : 38),
                      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 13),
                      textStyle: TextStyle(fontSize: compact ? 10 : 14),
                    ),
                  )
                else
                  const Chip(
                    avatar: Icon(Icons.lock_outline, size: 14),
                    label: Text('Invite only'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(compact ? 10 : 22),
              children: [
                Container(
                  padding: EdgeInsets.all(compact ? 13 : 22),
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: KomnivoTheme.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ABOUT THIS COMMUNITY',
                        style: TextStyle(
                          color: KomnivoTheme.cyan,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        description.isEmpty
                            ? 'No description has been added yet.'
                            : description,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 9,
                        runSpacing: 9,
                        children: [
                          _CommunityMetaPill(
                            icon: Icons.people_outline,
                            label: '${community['member_count'] ?? 1} members',
                          ),
                          _CommunityMetaPill(
                            icon: isPublic ? Icons.public : Icons.lock_outline,
                            label: isPublic ? 'PUBLIC' : 'INVITE ONLY',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  isPublic
                      ? 'Join this community to see its channels, meet players and take part in its activities.'
                      : 'This community is invite-only. You will need an invitation from its owner or an admin.',
                  style: const TextStyle(
                    color: KomnivoTheme.muted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommunityWelcomePane extends StatelessWidget {
  const _CommunityWelcomePane();

  @override
  Widget build(BuildContext context) => Container(
        color: KomnivoTheme.background,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: KomnivoTheme.surfaceRaised,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: KomnivoTheme.line),
                ),
                child: const Icon(
                  Icons.groups_rounded,
                  color: KomnivoTheme.cyan,
                  size: 36,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your community space',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 7),
              const Text(
                'Choose a server from the left to view its channels and details.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: KomnivoTheme.muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
}


class _CommunityMetaPill extends StatelessWidget {
  const _CommunityMetaPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: KomnivoTheme.surfaceRaised,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: KomnivoTheme.muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: KomnivoTheme.muted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
}
