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
      if (MediaQuery.sizeOf(context).width >= 360) {
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
    if (MediaQuery.sizeOf(context).width >= 360) {
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

  Widget _directoryHeader({
    required int total,
    required int joined,
  }) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        compact ? 8 : 13,
        compact ? 9 : 12,
        compact ? 8 : 13,
        compact ? 8 : 11,
      ),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        border: Border(
          bottom: BorderSide(color: KomnivoTheme.line.withValues(alpha: .8)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Communities',
                  style: TextStyle(
                    fontSize: compact ? 13 : 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.25,
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Create community',
                visualDensity: VisualDensity.compact,
                onPressed: _create,
                icon: const Icon(Icons.add_rounded, size: 19),
                style: IconButton.styleFrom(
                  minimumSize: Size.square(compact ? 32 : 36),
                  maximumSize: Size.square(compact ? 32 : 36),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 9),
          SizedBox(
            height: compact ? 35 : 39,
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: compact ? 10 : 12),
              decoration: InputDecoration(
                hintText: compact ? 'Search' : 'Search communities',
                prefixIcon: Icon(Icons.search, size: compact ? 16 : 18),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close, size: 16),
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 6 : 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _scopeChip(compact ? 'All' : 'All $total', 'all'),
                const SizedBox(width: 4),
                _scopeChip(compact ? 'Joined' : 'Joined $joined', 'joined'),
                const SizedBox(width: 5),
                _scopeChip('Discover', 'discover'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scopeChip(String label, String value) {
    return ChoiceChip(
      label: Text(label),
      selected: _scope == value,
      onSelected: (_) => setState(() => _scope = value),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
      side: BorderSide(
        color: _scope == value
            ? KomnivoTheme.accent.withValues(alpha: .55)
            : KomnivoTheme.line,
      ),
      backgroundColor: KomnivoTheme.surfaceRaised.withValues(alpha: .55),
      selectedColor: KomnivoTheme.accent.withValues(alpha: .18),
    );
  }

  Widget _directoryList({
    required List<Map<String, dynamic>> communities,
    required Map<String, Map<String, dynamic>> memberships,
    required bool desktop,
    required bool compact,
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
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        itemCount: communities.length,
        itemBuilder: (context, index) {
          final row = communities[index];
          final id = row['id']?.toString() ?? '';
          final membership = memberships[id];
          return _CommunitySidebarTile(
            row: row,
            membership: membership,
            joining: _joining.contains(id),
            selected: desktop && id == selectedId,
            desktop: desktop,
            compact: compact,
            onJoin: () => _join(row),
            onOpen: () => _open(row, membership),
          );
        },
      ),
    );
  }

  Widget _emptyDirectory({
    required String title,
    required String message,
    required IconData icon,
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
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 70),
          EmptyState(title: title, message: message, icon: icon),
        ],
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
        final isDesktop = screenWidth >= 360;
        final isCompactSplitView = screenWidth < 600;

        Widget listContent;
        if (snapshot.connectionState == ConnectionState.waiting && data == null) {
          listContent = const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          listContent = EmptyState(
            title: 'Could not load communities',
            message: snapshot.error.toString(),
            icon: Icons.error_outline,
          );
        } else if (directoryRows.isEmpty) {
          listContent = _emptyDirectory(
            title: query.isNotEmpty ? 'No matching communities' : 'Nothing here yet',
            message: query.isNotEmpty
                ? 'Try another community name.'
                : _scope == 'joined'
                    ? 'Join a public community to see it here.'
                    : 'Create a community or explore spaces to join.',
            icon: Icons.groups_outlined,
          );
        } else {
          listContent = _directoryList(
            communities: directoryRows,
            memberships: memberships,
            desktop: isDesktop,
            compact: isCompactSplitView,
            selectedId: selectedCommunity?['id']?.toString(),
          );
        }

        final directoryPane = Column(
          children: [
            _directoryHeader(total: rows.length, joined: memberships.length),
            Expanded(child: listContent),
          ],
        );

        if (!isDesktop) return directoryPane;

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
                  )
                : _CommunityPreviewPane(
                    key: ValueKey(selectedCommunity['id']),
                    community: selectedCommunity,
                    joining: _joining.contains(
                      selectedCommunity['id']?.toString() ?? '',
                    ),
                    onJoin: () => _join(selectedCommunity!),
                  );

        final sidebarWidth = isCompactSplitView
            ? (screenWidth * .38).clamp(132.0, 220.0).toDouble()
            : (screenWidth * .29).clamp(220.0, 350.0).toDouble();

        return Row(
          children: [
            SizedBox(width: sidebarWidth, child: directoryPane),
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

class _CommunitySidebarTile extends StatelessWidget {
  const _CommunitySidebarTile({
    required this.row,
    required this.membership,
    required this.joining,
    required this.selected,
    required this.desktop,
    required this.compact,
    required this.onJoin,
    required this.onOpen,
  });

  final Map<String, dynamic> row;
  final Map<String, dynamic>? membership;
  final bool joining;
  final bool selected;
  final bool desktop;
  final bool compact;
  final VoidCallback onJoin;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final joined = membership != null;
    final isPublic = (row['visibility']?.toString() ?? 'public') == 'public';
    final name = row['name']?.toString() ?? 'Community';
    final count = row['member_count']?.toString() ?? '1';
    final role = membership?['role']?.toString() ?? 'member';

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: selected
            ? KomnivoTheme.accent.withValues(alpha: .11)
            : KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: selected
              ? KomnivoTheme.accent.withValues(alpha: .62)
              : KomnivoTheme.line.withValues(alpha: .7),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: (desktop || joined) ? onOpen : null,
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 6 : 8,
              vertical: compact ? 5 : 6,
            ),
            child: Row(
              children: [
                CommunityLogo(
                  name: name,
                  imagePath: row['icon_url']?.toString(),
                  size: compact ? 30 : 38,
                ),
                SizedBox(width: compact ? 6 : 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 10 : 12,
                          fontWeight: FontWeight.w800,
                          color: selected ? Colors.white : null,
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            const Icon(
                              Icons.people_outline,
                              size: 11,
                              color: KomnivoTheme.muted,
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                '$count members',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: KomnivoTheme.muted,
                                  fontSize: 9,
                                ),
                              ),
                            ),
                            if (joined)
                              Text(
                                role == 'owner' ? 'OWNER' : 'JOINED',
                                style: const TextStyle(
                                  color: KomnivoTheme.cyan,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: .4,
                                ),
                              )
                            else if (!isPublic)
                              const Icon(
                                Icons.lock_outline,
                                size: 12,
                                color: KomnivoTheme.muted,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                if (!compact && !joined && isPublic)
                  TextButton(
                    onPressed: joining ? null : onJoin,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(42, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: joining
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'Join',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                          ),
                  )
                else if (joined)
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: KomnivoTheme.cyan,
                    size: 19,
                  )
                else if (!compact)
                  const SizedBox(width: 19),
              ],
            ),
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
