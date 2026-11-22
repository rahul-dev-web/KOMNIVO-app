import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'event_matches_screen.dart';

class CompeteScreen extends StatefulWidget {
  const CompeteScreen({super.key, required this.preview});
  final bool preview;

  @override
  State<CompeteScreen> createState() => _CompeteScreenState();
}

class _CompeteScreenState extends State<CompeteScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _promotionTitleController = TextEditingController();
  final TextEditingController _promotionDescriptionController = TextEditingController();
  final TextEditingController _promotionLinkController = TextEditingController();
  static final List<_PromotionDraft> _drafts = <_PromotionDraft>[];
  static bool _requireReview = true;
  static bool _allowDirectEnquiries = true;
  static bool _allowTeamPromotions = true;
  String _activeTab = 'Discover';
  String _searchQuery = '';
  Future<List<Map<String, dynamic>>>? _tournamentsFuture;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _tournamentsFuture = _loadTournaments();
  }

  Future<List<Map<String, dynamic>>> _loadTournaments() async {
    final rows = await Supabase.instance.client
        .from('events')
        .select('id,name,description,format,status,starts_at,registration_opens_at,registration_closes_at,capacity,game_id,community_id,games(name,code),communities(name)')
        .inFilter('status', ['published','registration_open'])
        .order('starts_at', ascending: true)
        .limit(50);
    return List<Map<String, dynamic>>.from(rows);
  }

  List<Map<String, dynamic>> _filteredTournaments(List<Map<String, dynamic>> rows) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return rows;
    return rows.where((event) {
      final game = event['games'] is Map ? (event['games'] as Map)['name']?.toString() ?? '' : '';
      final community = event['communities'] is Map ? (event['communities'] as Map)['name']?.toString() ?? '' : '';
      return [event['name'], event['description'], game, community, event['format']]
          .whereType<Object>()
          .any((value) => value.toString().toLowerCase().contains(query));
    }).toList();
  }

  Future<void> _openTournament(Map<String, dynamic> event) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => EventMatchesScreen(event: event)),
    );
  }

  Widget _buildTournamentCard(Map<String, dynamic> event) {
    final game = event['games'] is Map ? Map<String, dynamic>.from(event['games'] as Map) : <String, dynamic>{};
    final community = event['communities'] is Map ? Map<String, dynamic>.from(event['communities'] as Map) : <String, dynamic>{};
    final close = DateTime.tryParse(event['registration_closes_at']?.toString() ?? '');
    final subtitle = [
      game['name']?.toString(),
      event['format']?.toString().toUpperCase(),
      '${event['capacity'] ?? '—'} slots',
      if (community['name'] != null) community['name'].toString(),
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(event['name']?.toString() ?? 'Tournament', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: KomnivoTheme.cyan.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
            child: Text((event['status'] ?? 'published').toString().replaceAll('_', ' ').toUpperCase(),
              style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w900)),
          ),
        ]),
        const SizedBox(height: 5),
        Text(subtitle, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
        if ((event['description'] ?? '').toString().trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(event['description'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35)),
        ],
        const SizedBox(height: 8),
        Text(
          close == null ? 'Registration close time not announced' : 'Registration closes ${close.toLocal()}',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
        ),
        const SizedBox(height: 9),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: () => _openTournament(event),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('View tournament'),
          ),
        ),
      ]),
    );
  }

  static const List<_PromotionType> _promotionTypes = <_PromotionType>[
    _PromotionType(
      name: 'Tournament',
      description: 'Promote your tournament, cup or championship.',
      icon: Icons.emoji_events_outlined,
      tint: Color(0xFFFFC66D),
    ),
    _PromotionType(
      name: 'Scrims',
      description: 'Find teams and players for practice matches.',
      icon: Icons.sports_esports_outlined,
      tint: Color(0xFF66A8F2),
    ),
    _PromotionType(
      name: 'Team recruitment',
      description: 'Showcase tryouts, open slots and roster calls.',
      icon: Icons.groups_2_outlined,
      tint: Color(0xFF68D6B2),
    ),
    _PromotionType(
      name: 'Community event',
      description: 'Bring attention to gaming events and community activities.',
      icon: Icons.campaign_outlined,
      tint: Color(0xFFB49BFF),
    ),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _promotionTitleController.dispose();
    _promotionDescriptionController.dispose();
    _promotionLinkController.dispose();
    super.dispose();
  }

  List<_PromotionType> get _visibleTypes {
    final query = _searchQuery.toLowerCase().trim();
    if (query.isEmpty) return _promotionTypes;
    return _promotionTypes.where((item) =>
      item.name.toLowerCase().contains(query) ||
      item.description.toLowerCase().contains(query)
    ).toList();
  }

  List<_PromotionDraft> get _visibleDrafts {
    final query = _searchQuery.toLowerCase().trim();
    if (query.isEmpty) return _drafts;
    return _drafts.where((draft) =>
      draft.title.toLowerCase().contains(query) ||
      draft.type.toLowerCase().contains(query) ||
      draft.description.toLowerCase().contains(query)
    ).toList();
  }

  Future<void> _createPromotion({String? initialType}) async {
    _promotionTitleController.clear();
    _promotionDescriptionController.clear();
    _promotionLinkController.clear();
    var selectedType = initialType ?? _promotionTypes.first.name;

    final draft = await showModalBottomSheet<_PromotionDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: KomnivoTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      const Expanded(
                        child: Text(
                          'Create a promotion',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    const Text(
                      'Add the essentials now. Publishing and promotion delivery will be connected in a later phase.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.45),
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Promotion type'),
                      items: _promotionTypes.map((type) => DropdownMenuItem<String>(
                        value: type.name,
                        child: Text(type.name),
                      )).toList(),
                      onChanged: (value) {
                        if (value != null) setSheetState(() => selectedType = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('promotion-title-field'),
                      controller: _promotionTitleController,
                      maxLength: 80,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Promotion title',
                        hintText: 'e.g. Friday Night Scrims',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _promotionDescriptionController,
                      maxLength: 400,
                      minLines: 3,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Short description',
                        hintText: 'Tell players what they should know.',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _promotionLinkController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Contact or info link (optional)',
                        hintText: 'https://...',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: KomnivoTheme.surfaceRaised,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: KomnivoTheme.line),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded, color: KomnivoTheme.cyan, size: 19),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'This is a local draft only. It is not published or visible to other users yet.',
                              style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          final title = _promotionTitleController.text.trim();
                          if (title.length < 3) {
                            showMessage(sheetContext, 'Add a title with at least 3 characters.');
                            return;
                          }
                          Navigator.pop(
                            sheetContext,
                            _PromotionDraft(
                              title: title,
                              type: selectedType,
                              description: _promotionDescriptionController.text.trim(),
                              link: _promotionLinkController.text.trim(),
                              createdAt: DateTime.now(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save draft'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (!mounted || draft == null) return;
    setState(() {
      _drafts.insert(0, draft);
      _activeTab = 'My promotions';
      _searchQuery = '';
      _searchController.clear();
    });
    showMessage(context, 'Draft saved for this app session. Publishing is not connected yet.');
  }

  Future<void> _openPromotionSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Promotion settings'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _requireReview,
                  title: const Text('Review before publishing'),
                  subtitle: const Text('Keep new promotions in review until approved.'),
                  onChanged: (value) => setDialogState(() => _requireReview = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowDirectEnquiries,
                  title: const Text('Allow direct enquiries'),
                  subtitle: const Text('Let interested players contact the promoter.'),
                  onChanged: (value) => setDialogState(() => _allowDirectEnquiries = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowTeamPromotions,
                  title: const Text('Allow team and community promos'),
                  onChanged: (value) => setDialogState(() => _allowTeamPromotions = value),
                ),
                const SizedBox(height: 8),
                const Text(
                  'These are local UI preferences for now. Server-side review, permissions and delivery are not connected yet.',
                  style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _buildHeader(bool compact) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text('Compete', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)),
        SizedBox(height: 4),
        Text(
          'Promote your next move. Get seen by players.',
          style: TextStyle(color: KomnivoTheme.muted, fontSize: 12),
        ),
      ],
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: title),
            IconButton(
              tooltip: 'Promotion settings',
              onPressed: _openPromotionSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _createPromotion,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create promotion'),
            ),
          ),
        ],
      );
    }

    return Row(children: [
      Expanded(child: title),
      IconButton(
        tooltip: 'Promotion settings',
        onPressed: _openPromotionSettings,
        icon: const Icon(Icons.tune_rounded),
      ),
      const SizedBox(width: 8),
      FilledButton.icon(
        onPressed: _createPromotion,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Create promotion'),
      ),
    ]);
  }

  Widget _buildHero(bool compact) {
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: KomnivoTheme.accent.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .35)),
          ),
          child: const Text(
            'PROMOTION HUB',
            style: TextStyle(color: KomnivoTheme.accent, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.1),
          ),
        ),
        const SizedBox(height: 13),
        const Text(
          'Your competition deserves the spotlight.',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, height: 1.15),
        ),
        const SizedBox(height: 8),
        const Text(
          'Share tournaments, scrims, team tryouts and gaming events in one focused place.',
          style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.5),
        ),
      ],
    );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 18 : 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF211A3D), Color(0xFF122536), KomnivoTheme.surface],
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .24)),
      ),
      child: Row(
        children: [
          Expanded(child: copy),
          if (!compact) ...[
            const SizedBox(width: 16),
            Container(
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.campaign_rounded, size: 48, color: KomnivoTheme.accent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTypeCard(_PromotionType type) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _createPromotion(initialType: type.name),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: type.tint.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(type.icon, color: type.tint, size: 21),
              ),
              const Spacer(),
              const Icon(Icons.arrow_outward_rounded, size: 17, color: KomnivoTheme.muted),
            ]),
            const Spacer(),
            Text(type.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(height: 5),
            Text(type.description, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35)),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftCard(_PromotionDraft draft) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            decoration: BoxDecoration(
              color: KomnivoTheme.accent.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.campaign_outlined, color: KomnivoTheme.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(draft.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(draft.type, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                if (draft.description.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(draft.description, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: KomnivoTheme.cyan.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Text('Draft', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                tooltip: 'Delete draft',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _drafts.remove(draft)),
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: KomnivoTheme.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 560;
    final columns = width >= 1100 ? 4 : width >= 700 ? 3 : 2;

    return Scaffold(
      backgroundColor: KomnivoTheme.background,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(compact ? 16 : 28, 16, compact ? 16 : 28, 28),
          children: [
            if (widget.preview) const PreviewBanner(),
            _buildHeader(compact),
            const SizedBox(height: 18),
            _buildHero(compact),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Discover'),
                  selected: _activeTab == 'Discover',
                  onSelected: (_) => setState(() => _activeTab = 'Discover'),
                ),
                ChoiceChip(
                  label: const Text('Tournaments'),
                  selected: _activeTab == 'Tournaments',
                  onSelected: (_) {
                    setState(() {
                      _activeTab = 'Tournaments';
                      _tournamentsFuture ??= _loadTournaments();
                    });
                  },
                ),
                ChoiceChip(
                  label: const Text('My promotions'),
                  selected: _activeTab == 'My promotions',
                  onSelected: (_) => setState(() => _activeTab = 'My promotions'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                hintText: switch (_activeTab) {
                  'Discover' => 'Find a promotion type',
                  'Tournaments' => 'Search published tournaments',
                  _ => 'Search your drafts',
                },
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            if (_activeTab == 'Tournaments') ...[
              Row(children: [
                const Expanded(
                  child: Text('Published tournaments',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                ),
                IconButton(
                  tooltip: 'Refresh tournaments',
                  onPressed: () => setState(() => _tournamentsFuture = _loadTournaments()),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ]),
              const SizedBox(height: 8),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _tournamentsFuture ??= _loadTournaments(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return EmptyState(
                      title: 'Tournaments are unavailable',
                      message: snapshot.error.toString(),
                      icon: Icons.cloud_off_outlined,
                    );
                  }
                  final rows = _filteredTournaments(snapshot.data ?? []);
                  if (rows.isEmpty) {
                    return const EmptyState(
                      title: 'No published tournaments',
                      message: 'Published tournaments visible to your account will appear here.',
                      icon: Icons.emoji_events_outlined,
                    );
                  }
                  return Column(children: rows.map(_buildTournamentCard).toList());
                },
              ),
            ] else if (_activeTab == 'Discover') ...[
              const Text('What do you want to promote?',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              const SizedBox(height: 5),
              const Text('Choose a format to start a promotion draft.',
                style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
              const SizedBox(height: 13),
              if (_visibleTypes.isEmpty)
                const EmptyState(
                  title: 'No promotion type found',
                  message: 'Try another search term.',
                  icon: Icons.search_off_rounded,
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _visibleTypes.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 11,
                    mainAxisSpacing: 11,
                    mainAxisExtent: 158,
                  ),
                  itemBuilder: (context, index) => _buildTypeCard(_visibleTypes[index]),
                ),
            ] else ...[
              Row(children: [
                const Expanded(
                  child: Text('My promotions',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                ),
                Text(_drafts.length.toString() + ' drafts',
                  style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
              ]),
              const SizedBox(height: 13),
              if (_visibleDrafts.isEmpty)
                const EmptyState(
                  title: 'No promotions yet',
                  message: 'Create a draft for your tournament, scrim, team tryout or community event.',
                  icon: Icons.campaign_outlined,
                )
              else
                ..._visibleDrafts.map(_buildDraftCard),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: KomnivoTheme.surface,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: KomnivoTheme.line),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: KomnivoTheme.cyan, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Promotion drafts are kept locally for this app session only. Public discovery, publishing, payments and performance analytics will be added later.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PromotionType {
  const _PromotionType({
    required this.name,
    required this.description,
    required this.icon,
    required this.tint,
  });

  final String name;
  final String description;
  final IconData icon;
  final Color tint;
}

class _PromotionDraft {
  const _PromotionDraft({
    required this.title,
    required this.type,
    required this.description,
    required this.link,
    required this.createdAt,
  });

  final String title;
  final String type;
  final String description;
  final String link;
  final DateTime createdAt;
}
