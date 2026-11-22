import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/komnivo_theme.dart';

/// Converts a picked wall-clock time to an explicit India Standard Time
/// ISO-8601 timestamp. It does not depend on the device timezone.
String formatKOMNIVOIstTimestamp(DateTime date, TimeOfDay time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}T'
      '${two(time.hour)}:${two(time.minute)}:00+05:30';
}

/// Builds an optional roadmap. A wholly empty roadmap is deliberately null;
/// a partially completed roadmap is rejected rather than guessed.
Map<String, dynamic>? buildTournamentRoadmap({
  required String groupSize,
  required String qualifiersPerGroup,
  required String nextRoundTeamCount,
  required String qualifiedTeamCount,
  required String directInvites,
}) {
  final values = [
    groupSize.trim(),
    qualifiersPerGroup.trim(),
    nextRoundTeamCount.trim(),
    qualifiedTeamCount.trim(),
    directInvites.trim(),
  ];
  if (values.every((value) => value.isEmpty)) return null;
  if (values.any((value) => value.isEmpty)) {
    throw const FormatException('Complete every roadmap field or leave the roadmap unset for Coming soon.');
  }
  final parsed = values.map(int.tryParse).toList();
  if (parsed.any((value) => value == null)) {
    throw const FormatException('Roadmap values must be whole numbers.');
  }
  final group = parsed[0]!;
  final qualifiers = parsed[1]!;
  final nextRound = parsed[2]!;
  final qualified = parsed[3]!;
  final invited = parsed[4]!;
  if (group < 2 || group > 1000 || qualifiers < 1 || qualifiers > group ||
      nextRound < 1 || qualified < 0 || invited < 0 ||
      qualified + invited != nextRound) {
    throw const FormatException(
      'Qualified teams plus direct invites must equal the next-round team count.',
    );
  }
  return {
    'group_size': group,
    'qualifiers_per_group': qualifiers,
    'next_round_team_count': nextRound,
    'qualified_team_count': qualified,
    'direct_invites': invited,
  };
}

Map<String, dynamic> _asMap(dynamic value) => value is Map
    ? Map<String, dynamic>.from(value)
    : <String, dynamic>{};

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

class TournamentFormScreen extends StatefulWidget {
  const TournamentFormScreen({
    super.key,
    required this.communities,
    this.initialCommunityId,
    this.conversationId,
    this.event,
  });

  final List<Map<String, String>> communities;
  final String? initialCommunityId;
  final String? conversationId;
  final Map<String, dynamic>? event;

  bool get isEditing => event != null;

  @override
  State<TournamentFormScreen> createState() => _TournamentFormScreenState();
}

class _TournamentFormScreenState extends State<TournamentFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _slots = TextEditingController(text: '');
  final _stageCount = TextEditingController(text: '');
  final _stageNames = TextEditingController();
  final _rules = TextEditingController();
  final _scoring = TextEditingController();
  final _groupSize = TextEditingController();
  final _qualifiers = TextEditingController();
  final _nextRound = TextEditingController();
  final _qualified = TextEditingController();
  final _invites = TextEditingController();
  final _prizePool = TextEditingController(text: '0');
  final _prizeDistribution = TextEditingController();
  final _entryFee = TextEditingController();

  final SupabaseClient _client = Supabase.instance.client;
  List<Map<String, String>> _communities = [];
  List<Map<String, dynamic>> _games = [];
  List<Map<String, dynamic>> _rulebooks = [];
  String? _communityId;
  String? _gameId;
  String _format = 'squad';
  String _rulesSource = 'standard';
  String? _rulebookId;
  String _entryType = 'free';
  DateTime? _registrationStartDate;
  TimeOfDay? _registrationStartTime;
  DateTime? _registrationCloseDate;
  TimeOfDay? _registrationCloseTime;
  DateTime? _tournamentStartDate;
  TimeOfDay? _tournamentStartTime;
  PlatformFile? _bannerFile;
  Uint8List? _bannerBytes;
  String? _bannerPath;
  String? _bannerSignedUrl;
  String? _idempotencyFingerprint;
  String? _idempotencyKey;
  bool _loading = true;
  bool _saving = false;
  bool _loadingRulebooks = false;
  bool _showRoadmap = false;
  String? _loadError;

  static const _modes = <String, String>{
    'solo': 'Solo',
    'duo': 'Duo',
    'squad': 'Squad',
    'custom': 'Custom',
  };

  @override
  void initState() {
    super.initState();
    _communityId = widget.initialCommunityId ?? widget.event?['community_id']?.toString();
    _hydrateEvent();
    _loadInitialData();
  }

  void _hydrateEvent() {
    final event = widget.event;
    if (event == null) return;
    final config = _asMap(event['event_config']);
    final roadmap = _asMap(config['roadmap']);
    _name.text = event['name']?.toString() ?? '';
    _slots.text = event['capacity']?.toString() ?? '';
    _format = _modes.containsKey(event['format']?.toString())
        ? event['format'].toString()
        : 'squad';
    _stageCount.text = config['stage_count']?.toString() ?? '';
    _stageNames.text = (config['stage_names'] is List)
        ? (config['stage_names'] as List).map((value) => value.toString()).join('\n')
        : '';
    _groupSize.text = roadmap['group_size']?.toString() ?? '';
    _qualifiers.text = roadmap['qualifiers_per_group']?.toString() ?? '';
    _nextRound.text = roadmap['next_round_team_count']?.toString() ?? '';
    _qualified.text = roadmap['qualified_team_count']?.toString() ?? '';
    _invites.text = roadmap['direct_invites']?.toString() ?? '';
    _showRoadmap = roadmap.isNotEmpty;
    _prizePool.text = config['prize_pool_amount']?.toString() ?? '0';
    _prizeDistribution.text = config['prize_distribution']?.toString() ?? '';
    _entryType = config['entry_type']?.toString() == 'paid' ? 'paid' : 'free';
    _entryFee.text = config['entry_fee']?.toString() ?? '';
    _rulesSource = config['rules_source']?.toString() == 'standard' ? 'standard' : 'custom';
    final rules = _asMap(event['rules_json']);
    _rules.text = rules['custom_text']?.toString() ??
        rules['summary']?.toString() ??
        rules['rules']?.toString() ?? '';
    final scoring = _asMap(event['scoring_config']);
    _scoring.text = const JsonEncoder.withIndent('  ').convert(scoring);
    _rulebookId = _asMap(config['rulebook'])['id']?.toString();
    _bannerPath = event['banner_path']?.toString() ?? config['banner_path']?.toString();
    _registrationStartDate = _dateInIst(event['registration_opens_at']);
    _registrationStartTime = _timeInIst(event['registration_opens_at']);
    _registrationCloseDate = _dateInIst(event['registration_closes_at']);
    _registrationCloseTime = _timeInIst(event['registration_closes_at']);
    _tournamentStartDate = _dateInIst(event['starts_at']);
    _tournamentStartTime = _timeInIst(event['starts_at']);
  }

  DateTime? _dateInIst(dynamic raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    if (parsed == null) return null;
    final ist = parsed.toUtc().add(const Duration(hours: 5, minutes: 30));
    return DateTime(ist.year, ist.month, ist.day);
  }

  TimeOfDay? _timeInIst(dynamic raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    if (parsed == null) return null;
    final ist = parsed.toUtc().add(const Duration(hours: 5, minutes: 30));
    return TimeOfDay(hour: ist.hour, minute: ist.minute);
  }

  Future<void> _loadInitialData() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) throw Exception('Sign in again before creating a tournament.');

      if (widget.communities.isNotEmpty) {
        _communities = widget.communities;
      } else {
        final results = await Future.wait([
          _client.from('communities').select('id').eq('owner_user_id', user.id),
          _client.from('community_members').select('community_id')
              .eq('user_id', user.id)
              .inFilter('role', ['owner', 'admin', 'organiser']),
        ]);
        final ids = <String>{
          ...List<Map<String, dynamic>>.from(results[0] as List)
              .map((row) => row['id'].toString()),
          ...List<Map<String, dynamic>>.from(results[1] as List)
              .map((row) => row['community_id'].toString()),
        };
        final rows = ids.isEmpty
            ? <Map<String, dynamic>>[]
            : List<Map<String, dynamic>>.from(await _client.from('communities')
                .select('id,name').inFilter('id', ids.toList()).order('name'));
        _communities = rows.map((row) => <String, String>{
          'id': row['id'].toString(),
          'name': row['name']?.toString() ?? 'Community',
        }).toList();
      }

      final games = await _client.from('games')
          .select('id,code,name,is_active')
          .eq('is_active', true)
          .inFilter('code', ['free_fire_india', 'bgmi'])
          .order('name');
      _games = List<Map<String, dynamic>>.from(games);

      if (_gameId == null) {
        final eventGame = widget.event?['game_id']?.toString();
        _gameId = _firstOrNull(_games.where((row) => row['id'].toString() == eventGame)
            .map((row) => row['id'].toString()));
      }
      if (_gameId == null) {
        _gameId = _firstOrNull(_games.where((row) => row['code'] == 'free_fire_india')
            .map((row) => row['id'].toString()));
      }
      if (_communityId == null && _communities.length == 1) {
        _communityId = _communities.first['id'];
      }
      if (_communityId != null) await _loadRulebooks();
      if (_bannerPath != null && _bannerPath!.isNotEmpty) {
        try {
          final signed = await _client.storage.from('tournament-banners')
              .createSignedUrl(_bannerPath!, 3600);
          _bannerSignedUrl = signed;
        } catch (_) {
          _bannerSignedUrl = null;
        }
      }
    } catch (error) {
      _loadError = error.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRulebooks() async {
    if (_communityId == null || _gameId == null) return;
    setState(() => _loadingRulebooks = true);
    try {
      final response = await _client.functions.invoke(
        'organizer-tournament-workflow',
        body: {
          'action': 'rulebooks',
          'community_id': _communityId,
          'game_id': _gameId,
          'format': _format,
        },
      );
      if (response.status < 200 || response.status >= 300) {
        throw Exception('Could not load standard rulebooks.');
      }
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      final rows = data['rulebooks'] is List
          ? List<Map<String, dynamic>>.from(
              (data['rulebooks'] as List).whereType<Map>())
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _rulebooks = rows;
        if (_rulebooks.isEmpty && _rulesSource == 'standard') {
          _rulesSource = 'custom';
          _rulebookId = null;
        } else if (_rulesSource == 'standard') {
          final hasCurrent = _rulebooks.any((row) => row['id'].toString() == _rulebookId);
          if (!hasCurrent) _rulebookId = _rulebooks.first['id'].toString();
        } else if (_rulebookId != null &&
            !_rulebooks.any((row) => row['id'].toString() == _rulebookId)) {
          _rulebookId = null;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _rulebooks = [];
          if (_rulesSource == 'standard') _rulesSource = 'custom';
          _loadError ??= error.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _loadingRulebooks = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _slots.dispose();
    _stageCount.dispose();
    _stageNames.dispose();
    _rules.dispose();
    _scoring.dispose();
    _groupSize.dispose();
    _qualifiers.dispose();
    _nextRound.dispose();
    _qualified.dispose();
    _invites.dispose();
    _prizePool.dispose();
    _prizeDistribution.dispose();
    _entryFee.dispose();
    super.dispose();
  }

  DateTime _todayInIndia() {
    final indiaNow = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    return DateTime(indiaNow.year, indiaNow.month, indiaNow.day);
  }

  DateTime _asUtc(DateTime date, TimeOfDay time) => DateTime.utc(
        date.year, date.month, date.day, time.hour, time.minute,
      ).subtract(const Duration(hours: 5, minutes: 30));

  Future<void> _pickDateTime({
    required String title,
    required DateTime? currentDate,
    required TimeOfDay? currentTime,
    required void Function(DateTime, TimeOfDay) onSelected,
  }) async {
    final today = _todayInIndia();
    final date = await showDatePicker(
      context: context,
      initialDate: currentDate != null && currentDate.isBefore(today)
          ? today
          : currentDate ?? today,
      firstDate: today,
      lastDate: DateTime(2100),
      helpText: '$title date (IST)',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: currentTime ?? const TimeOfDay(hour: 18, minute: 0),
      helpText: '$title time (IST)',
    );
    if (time == null || !mounted) return;
    setState(() => onSelected(date, time));
  }

  String _dateTimeLabel(DateTime? date, TimeOfDay? time) {
    if (date == null || time == null) return 'Choose date and time';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    return '${date.day} ${months[date.month - 1]} ${date.year} · $hour:${time.minute.toString().padLeft(2,'0')} ${time.period == DayPeriod.am ? 'AM' : 'PM'} IST';
  }

  Future<void> _pickBanner() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['jpg','jpeg','png','webp'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw Exception('Choose a non-empty JPG, PNG or WebP image up to 10 MB.');
      }
      if (!mounted) return;
      setState(() {
        _bannerFile = file;
        _bannerBytes = bytes;
        _bannerSignedUrl = null;
      });
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _uploadBannerIfNeeded() async {
    if (_bannerFile == null || _bannerBytes == null) return;
    final user = _client.auth.currentUser;
    if (user == null || _communityId == null) throw Exception('Select a community before uploading a banner.');
    final extension = (_bannerFile!.extension ?? 'jpg').toLowerCase();
    final contentType = switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    final safeName = _bannerFile!.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final nonce = '${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 24)}';
    final path = '$_communityId/${user.id}/${nonce}_$safeName';
    await _client.storage.from('tournament-banners').uploadBinary(
      path,
      _bannerBytes!,
      fileOptions: FileOptions(contentType: contentType, upsert: false),
    );
    _bannerPath = path;
    _bannerFile = null;
    _bannerSignedUrl = await _client.storage.from('tournament-banners')
        .createSignedUrl(path, 3600);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _submit() async {
    if (_saving || _loading || !_formKey.currentState!.validate()) return;
    if (_communityId == null || !_communities.any((row) => row['id'] == _communityId)) {
      _showError('Choose a community you manage.');
      return;
    }
    if (_registrationStartDate == null || _registrationStartTime == null ||
        _registrationCloseDate == null || _registrationCloseTime == null ||
        _tournamentStartDate == null || _tournamentStartTime == null) {
      _showError('Choose all three registration/tournament dates and times.');
      return;
    }

    final opens = _asUtc(_registrationStartDate!, _registrationStartTime!);
    final closes = _asUtc(_registrationCloseDate!, _registrationCloseTime!);
    final starts = _asUtc(_tournamentStartDate!, _tournamentStartTime!);
    final now = DateTime.now().toUtc();
    if (!opens.isAfter(now) || !closes.isAfter(now) || !starts.isAfter(now)) {
      _showError('Registration and tournament dates must all be in the future.');
      return;
    }
    if (!opens.isBefore(closes) || !closes.isBefore(starts)) {
      _showError('Use this order: registration start → registration close → tournament start.');
      return;
    }

    final stageCount = int.tryParse(_stageCount.text.trim());
    if (stageCount == null || stageCount < 1 || stageCount > 16) {
      _showError('Stage count must be a whole number from 1 to 16.');
      return;
    }
    final stageNames = _stageNames.text
        .split('\n').map((value) => value.trim()).where((value) => value.isNotEmpty).toList();
    if (stageNames.isNotEmpty && stageNames.length != stageCount) {
      _showError('Enter exactly one name per stage, or leave stage names blank for Coming soon.');
      return;
    }

    Map<String, dynamic>? roadmap;
    try {
      roadmap = buildTournamentRoadmap(
        groupSize: _groupSize.text,
        qualifiersPerGroup: _qualifiers.text,
        nextRoundTeamCount: _nextRound.text,
        qualifiedTeamCount: _qualified.text,
        directInvites: _invites.text,
      );
    } on FormatException catch (error) {
      _showError(error.message);
      return;
    }

    final slots = int.tryParse(_slots.text.trim());
    if (slots == null || slots < 1 || slots > 1000) {
      _showError('Slots must be a whole number from 1 to 1000.');
      return;
    }
    final prize = double.tryParse(_prizePool.text.trim());
    if (prize == null || prize < 0 || prize > 100000000) {
      _showError('Enter a valid INR prize pool amount.');
      return;
    }
    final distribution = _prizeDistribution.text.trim();
    if (prize > 0 && distribution.isEmpty) {
      _showError('Describe how the prize pool will be distributed.');
      return;
    }
    final entryFee = _entryType == 'paid' ? double.tryParse(_entryFee.text.trim()) : null;
    if (_entryType == 'paid' && (entryFee == null || entryFee <= 0 || entryFee > 1000000)) {
      _showError('Paid entry requires a positive fee up to ₹10,00,000.');
      return;
    }
    final game = _firstOrNull(_games.where((row) => row['id'].toString() == _gameId));
    if (game == null) {
      _showError('Select a supported game.');
      return;
    }

    Map<String, dynamic> rulesJson;
    Map<String, dynamic> scoringConfig;
    Map<String, dynamic>? rulebookMeta;
    if (_rulesSource == 'standard') {
      final selected = _firstOrNull(_rulebooks.where((row) => row['id'].toString() == _rulebookId));
      if (selected == null) {
        _showError('No official standard rulebook is available for this game and mode. Choose Custom rules.');
        return;
      }
      rulesJson = _asMap(selected['rules_config']);
      scoringConfig = _asMap(selected['scoring_config']);
      rulebookMeta = {
        'id': selected['id'],
        'title': selected['title'],
        'version': selected['version'],
        'region': selected['region'],
        'scope': selected['scope'],
        'source_title': selected['source_title'],
        'source_url': selected['source_url'],
        'notes': selected['notes'],
      };
    } else {
      final customRules = _rules.text.trim();
      if (customRules.length < 10) {
        _showError('Enter the custom rule details (at least 10 characters).');
        return;
      }
      final scoringText = _scoring.text.trim();
      if (scoringText.isEmpty) {
        scoringConfig = {};
      } else {
        try {
          final decoded = jsonDecode(scoringText);
          if (decoded is! Map) throw const FormatException('Scoring must be a JSON object.');
          scoringConfig = Map<String, dynamic>.from(decoded);
        } catch (error) {
          _showError('Scoring configuration must be a valid JSON object: $error');
          return;
        }
      }
      rulesJson = {
        'source': 'organiser_custom',
        'custom_text': customRules,
      };
    }

    setState(() => _saving = true);
    try {
      await _uploadBannerIfNeeded();
      final payload = <String, dynamic>{
        'name': _name.text.trim(),
        'description': '',
        'community_id': _communityId,
        'game_id': game['id'],
        'format': _format,
        'capacity': slots,
        'registration_opens_at': formatKOMNIVOIstTimestamp(
          _registrationStartDate!, _registrationStartTime!,
        ),
        'registration_closes_at': formatKOMNIVOIstTimestamp(
          _registrationCloseDate!, _registrationCloseTime!,
        ),
        'starts_at': formatKOMNIVOIstTimestamp(
          _tournamentStartDate!, _tournamentStartTime!,
        ),
        'rules_json': rulesJson,
        'scoring_config': scoringConfig,
        'banner_path': _bannerPath,
        'event_config': {
          'schema_version': 1,
          'stage_count': stageCount,
          'stage_names': stageNames,
          'roadmap': roadmap,
          'prize_pool_amount': prize,
          'prize_pool_currency': 'INR',
          'prize_distribution': distribution,
          'entry_type': _entryType,
          'entry_fee': entryFee,
          'rules_source': _rulesSource,
          'rulebook': rulebookMeta,
          'banner_path': _bannerPath,
        },
      };

      if (!widget.isEditing) {
        final fingerprint = jsonEncode(payload);
        if (_idempotencyFingerprint != fingerprint || _idempotencyKey == null) {
          _idempotencyFingerprint = fingerprint;
          _idempotencyKey = 'tournament_${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 24)}';
        }
      }

      final response = await _client.functions.invoke(
        'organizer-tournament-workflow',
        body: widget.isEditing
            ? {
                'action': 'update_draft',
                'community_id': _communityId,
                'event_id': widget.event!['id'],
                'payload': payload,
              }
            : {
                'action': 'create_proposal',
                'community_id': _communityId,
                'conversation_id': (widget.initialCommunityId != null &&
                        widget.initialCommunityId != _communityId)
                    ? null
                    : widget.conversationId,
                'idempotency_key': _idempotencyKey,
                'payload': payload,
              },
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Tournament save failed.');
      }
      if (!mounted) return;
      if (widget.isEditing) {
        Navigator.of(context).pop(true);
      } else {
        final proposal = data['proposal'] is Map
            ? Map<String, dynamic>.from(data['proposal'] as Map)
            : <String, dynamic>{};
        Navigator.of(context).pop({
          'conversation_id': data['conversation_id'],
          'proposal': {
            'workflow_type': 'tournament',
            'community_id': _communityId,
            'id': proposal['id'],
            'status': proposal['status'] ?? 'pending_approval',
            'expires_at': proposal['expires_at'],
            'source_refs': proposal['source_refs'] ?? [],
            'name': payload['name'],
            'description': payload['description'],
            'game_name': game['name'],
            'game_code': game['code'],
            'format': payload['format'],
            'capacity': payload['capacity'],
            'starts_at': payload['starts_at'],
            'registration_opens_at': payload['registration_opens_at'],
            'registration_closes_at': payload['registration_closes_at'],
            'event_config': payload['event_config'],
            'rules_json': payload['rules_json'],
            'scoring_config': payload['scoring_config'],
            'banner_path': payload['banner_path'],
          },
        });
      }
    } catch (error) {
      if (mounted) _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSource(String? url) async {
    final value = Uri.tryParse(url ?? '');
    if (value == null || !value.hasScheme) return;
    await launchUrl(value, mode: LaunchMode.externalApplication);
  }

  Widget _dateTile({
    required IconData icon,
    required String title,
    required DateTime? date,
    required TimeOfDay? time,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: _saving ? null : onTap,
    borderRadius: BorderRadius.circular(13),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: KomnivoTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Row(children: [
        Icon(icon, color: KomnivoTheme.cyan, size: 19),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            _dateTimeLabel(date, time),
            style: TextStyle(fontSize: 12, color: date == null || time == null ? KomnivoTheme.muted : Colors.white),
          ),
        ])),
        const Icon(Icons.edit_calendar_outlined, color: KomnivoTheme.muted, size: 18),
      ]),
    ),
  );

  InputDecoration _decoration(String label, {String? helper}) => InputDecoration(
    labelText: label,
    helperText: helper,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
  );

  @override
  Widget build(BuildContext context) {
    final editing = widget.isEditing;
    final canSelectCommunity = _communities.length > 1 && !editing;
    final selectedGame = _firstOrNull(_games.where((row) => row['id'].toString() == _gameId));
    final selectedRulebook = _firstOrNull(_rulebooks.where((row) => row['id'].toString() == _rulebookId));

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit tournament' : 'Create tournament'),
        actions: [
          IconButton(
            tooltip: 'Close',
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null && _communities.isEmpty
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_loadError!, textAlign: TextAlign.center),
                ))
              : SafeArea(
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: KomnivoTheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: KomnivoTheme.line),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('BASIC DETAILS', style: TextStyle(
                              color: KomnivoTheme.cyan, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: .7,
                            )),
                            const SizedBox(height: 12),
                            if (canSelectCommunity)
                              DropdownButtonFormField<String>(
                                initialValue: _communityId,
                                isExpanded: true,
                                decoration: _decoration('Community'),
                                items: _communities.map((row) => DropdownMenuItem<String>(
                                  value: row['id'],
                                  child: Text(row['name'] ?? 'Community', overflow: TextOverflow.ellipsis),
                                )).toList(),
                                onChanged: _saving ? null : (value) async {
                                  setState(() {
                                    _communityId = value;
                                    _rulebooks = [];
                                    _rulebookId = null;
                                    _rulesSource = 'custom';
                                  });
                                  await _loadRulebooks();
                                },
                                validator: (value) => value == null ? 'Choose a community' : null,
                              )
                            else
                              InputDecorator(
                                decoration: _decoration('Community'),
                                child: Text(
                                  _firstOrNull(_communities.where((row) => row['id'] == _communityId)
                                      .map((row) => row['name'] ?? 'Community')) ?? 'Choose a managed community',
                                ),
                              ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _name,
                              decoration: _decoration('Tournament name'),
                              textCapitalization: TextCapitalization.sentences,
                              validator: (value) => value == null || value.trim().length < 3
                                  ? 'Enter at least 3 characters' : null,
                            ),
                            const SizedBox(height: 10),
                            DropdownButtonFormField<String>(
                              initialValue: selectedGame == null ? null : _gameId,
                              isExpanded: true,
                              decoration: _decoration('Game'),
                              items: _games.map((game) => DropdownMenuItem<String>(
                                value: game['id'].toString(),
                                child: Text(
                                  game['code'] == 'free_fire_india'
                                      ? 'Free Fire India'
                                      : game['name']?.toString() ?? 'Game',
                                ),
                              )).toList(),
                              onChanged: _saving ? null : (value) async {
                                setState(() {
                                  _gameId = value;
                                  _rulebookId = null;
                                  _rulesSource = 'custom';
                                });
                                await _loadRulebooks();
                              },
                              validator: (value) => value == null ? 'Choose a supported game' : null,
                            ),
                            const SizedBox(height: 10),
                            DropdownButtonFormField<String>(
                              initialValue: _format,
                              isExpanded: true,
                              decoration: _decoration('Mode'),
                              items: _modes.entries.map((entry) => DropdownMenuItem<String>(
                                value: entry.key,
                                child: Text(entry.value),
                              )).toList(),
                              onChanged: _saving ? null : (value) async {
                                if (value == null) return;
                                setState(() {
                                  _format = value;
                                  _rulebookId = null;
                                  _rulesSource = 'custom';
                                });
                                await _loadRulebooks();
                              },
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _slots,
                              keyboardType: TextInputType.number,
                              decoration: _decoration('Slots', helper: 'Total player/team registrations allowed'),
                              validator: (value) {
                                final number = int.tryParse(value?.trim() ?? '');
                                return number == null || number < 1 || number > 1000
                                    ? 'Enter a whole number from 1 to 1000' : null;
                              },
                            ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: KomnivoTheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: KomnivoTheme.line),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('STAGES & ROADMAP', style: TextStyle(
                              color: KomnivoTheme.cyan, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: .7,
                            )),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _stageCount,
                              keyboardType: TextInputType.number,
                              decoration: _decoration('Stage count', helper: 'Required · 1–16'),
                              validator: (value) {
                                final number = int.tryParse(value?.trim() ?? '');
                                return number == null || number < 1 || number > 16
                                    ? 'Enter 1 to 16 stages' : null;
                              },
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _stageNames,
                              onChanged: (_) => setState(() {}),
                              minLines: 2,
                              maxLines: 4,
                              decoration: _decoration(
                                'Stage names (optional)',
                                helper: 'One name per line. Leave blank to decide later.',
                              ),
                            ),
                            if (_stageNames.text.trim().isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text('Coming soon · Stage names can be completed later.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                              ),
                            const Divider(height: 22),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Configure roadmap now'),
                              subtitle: const Text('Group size, qualifiers and direct invites'),
                              value: _showRoadmap,
                              onChanged: _saving ? null : (value) => setState(() => _showRoadmap = value),
                            ),
                            if (_showRoadmap) ...[
                              Row(children: [
                                Expanded(child: TextField(controller: _groupSize, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: _decoration('Teams per group'))),
                                const SizedBox(width: 8),
                                Expanded(child: TextField(controller: _qualifiers, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: _decoration('Qualify per group'))),
                              ]),
                              const SizedBox(height: 8),
                              TextField(controller: _nextRound, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: _decoration('Next-round team count')),
                              const SizedBox(height: 8),
                              Row(children: [
                                Expanded(child: TextField(controller: _qualified, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: _decoration('Qualified teams'))),
                                const SizedBox(width: 8),
                                Expanded(child: TextField(controller: _invites, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: _decoration('Direct invites')),
                                ),
                              ]),
                              if ([
                                _groupSize,_qualifiers,_nextRound,_qualified,_invites,
                              ].every((controller) => controller.text.trim().isEmpty))
                                const Padding(
                                  padding: EdgeInsets.only(top: 7),
                                  child: Text('Coming soon · Leave every roadmap field blank to complete this later.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                                ),
                            ] else
                              const Text('Coming soon · Leave the roadmap unset and complete it when your bracket is decided.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: KomnivoTheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: KomnivoTheme.line),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('RULES & SCORING', style: TextStyle(
                              color: KomnivoTheme.cyan, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: .7,
                            )),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: _rulesSource,
                              decoration: _decoration('Rules source'),
                              items: [
                                if (_rulebooks.isNotEmpty)
                                  const DropdownMenuItem(value: 'standard', child: Text('Standard rulebook')),
                                const DropdownMenuItem(value: 'custom', child: Text('Enter custom rules')),
                              ],
                              onChanged: _saving ? null : (value) {
                                if (value != null) {
                                  setState(() {
                                    _rulesSource = value;
                                    _rulebookId = value == 'standard' ? _rulebooks.first['id'].toString() : null;
                                  });
                                }
                              },
                            ),
                            if (_loadingRulebooks)
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: LinearProgressIndicator(minHeight: 2),
                              ),
                            if (_rulesSource == 'standard' && _rulebooks.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              DropdownButtonFormField<String>(
                                initialValue: _rulebooks.any((row) => row['id'].toString() == _rulebookId)
                                    ? _rulebookId : _rulebooks.first['id'].toString(),
                                isExpanded: true,
                                decoration: _decoration('Available rulebook'),
                                items: _rulebooks.map((row) => DropdownMenuItem<String>(
                                  value: row['id'].toString(),
                                  child: Text('${row['title']} · ${row['version']}', overflow: TextOverflow.ellipsis),
                                )).toList(),
                                onChanged: (value) => setState(() => _rulebookId = value),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                selectedRulebook?['notes']?.toString() ??
                                    'Source-linked rulebook. Check whether it is a general baseline or specific to one competition.',
                                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
                              ),
                              TextButton.icon(
                                onPressed: selectedRulebook?['download_available'] == false
                                    ? null
                                    : () => _openSource(
                                        selectedRulebook?['download_url']?.toString(),
                                      ),
                                icon: const Icon(Icons.download_outlined, size: 15),
                                label: Text(selectedRulebook?['download_available'] == true
                                    ? 'Open cleaned KOMNIVO PDF copy'
                                    : 'Clean PDF is not available yet'),
                              ),
                              Text(
                                "Scoring loaded from this rulebook version: ${const JsonEncoder.withIndent('  ').convert(_asMap(selectedRulebook?['scoring_config']))}",
                                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                selectedRulebook?['scope'] == 'competition_specific'
                                    ? 'Competition-specific rulebook. Do not treat these scoring values as universal for every event.'
                                    : 'Curated gameplay baseline, not an official Garena publication. Verify map pool and settings against the current game client.',
                                style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 11),
                              ),
                            ],
                            if (_rulesSource == 'custom') ...[
                              const SizedBox(height: 10),
                              if (_games.any((row) => row['id'].toString() == _gameId && row['code'] == 'free_fire_india'))
                                const Text(
                                  'KOMNIVO-curated Free Fire India baseline available for Squad. This is adapted from the organiser-supplied source PDF, not issued or endorsed by Garena.',
                                  style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
                                ),
                              TextField(
                                controller: _rules,
                                minLines: 3,
                                maxLines: 7,
                                decoration: _decoration('Custom rules', helper: 'Enter game-specific rules and restrictions.'),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _scoring,
                                minLines: 3,
                                maxLines: 6,
                                decoration: _decoration(
                                  'Scoring / points table (JSON)',
                                  helper: 'Example: {"kill_point":1,"placement_points":{"1":12,"2":9}}',
                                ),
                              ),
                            ],
                          ]),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: KomnivoTheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: KomnivoTheme.line),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('BANNER & PRIZES', style: TextStyle(
                              color: KomnivoTheme.cyan, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: .7,
                            )),
                            const SizedBox(height: 10),
                            if (_bannerBytes != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.memory(_bannerBytes!, height: 150, width: double.infinity, fit: BoxFit.cover),
                              )
                            else if (_bannerSignedUrl != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(_bannerSignedUrl!, height: 150, width: double.infinity, fit: BoxFit.cover),
                              )
                            else
                              Container(
                                height: 82,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: KomnivoTheme.surfaceRaised,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: KomnivoTheme.line),
                                ),
                                child: const Center(child: Text('No tournament banner selected', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12))),
                              ),
                            const SizedBox(height: 8),
                            Row(children: [
                              Expanded(child: OutlinedButton.icon(
                                onPressed: _saving ? null : _pickBanner,
                                icon: const Icon(Icons.upload_file_outlined),
                                label: Text(_bannerPath == null ? 'Upload banner' : 'Replace banner'),
                              )),
                              if (_bannerFile != null) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Remove selected banner',
                                  onPressed: _saving ? null : () => setState(() {
                                    _bannerFile = null;
                                    _bannerBytes = null;
                                  }),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ]),
                            const SizedBox(height: 14),
                            Row(children: [
                              Expanded(child: TextField(
                                controller: _prizePool,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: _decoration('Prize pool (INR)'),
                              )),
                              const SizedBox(width: 8),
                              Expanded(child: DropdownButtonFormField<String>(
                                initialValue: _entryType,
                                decoration: _decoration('Entry type'),
                                items: const [
                                  DropdownMenuItem(value: 'free', child: Text('Free')),
                                  DropdownMenuItem(value: 'paid', child: Text('Paid')),
                                ],
                                onChanged: (value) => setState(() => _entryType = value ?? 'free'),
                              )),
                            ]),
                            if (_entryType == 'paid') ...[
                              const SizedBox(height: 8),
                              TextField(
                                controller: _entryFee,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: _decoration('Entry fee (INR)'),
                              ),
                            ],
                            const SizedBox(height: 8),
                            TextField(
                              controller: _prizeDistribution,
                              minLines: 2,
                              maxLines: 4,
                              decoration: _decoration('Prize pool distribution'),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: KomnivoTheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: KomnivoTheme.line),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('REGISTRATION & TOURNAMENT DATES', style: TextStyle(
                              color: KomnivoTheme.cyan, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: .7,
                            )),
                            const SizedBox(height: 10),
                            _dateTile(
                              icon: Icons.how_to_reg_outlined,
                              title: 'Registration starts',
                              date: _registrationStartDate,
                              time: _registrationStartTime,
                              onTap: () => _pickDateTime(
                                title: 'Registration start',
                                currentDate: _registrationStartDate,
                                currentTime: _registrationStartTime,
                                onSelected: (date,time) {
                                  _registrationStartDate = date;
                                  _registrationStartTime = time;
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            _dateTile(
                              icon: Icons.lock_clock_outlined,
                              title: 'Registration closes',
                              date: _registrationCloseDate,
                              time: _registrationCloseTime,
                              onTap: () => _pickDateTime(
                                title: 'Registration close',
                                currentDate: _registrationCloseDate,
                                currentTime: _registrationCloseTime,
                                onSelected: (date,time) {
                                  _registrationCloseDate = date;
                                  _registrationCloseTime = time;
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            _dateTile(
                              icon: Icons.emoji_events_outlined,
                              title: 'Tournament matches start',
                              date: _tournamentStartDate,
                              time: _tournamentStartTime,
                              onTap: () => _pickDateTime(
                                title: 'Tournament start',
                                currentDate: _tournamentStartDate,
                                currentTime: _tournamentStartTime,
                                onSelected: (date,time) {
                                  _tournamentStartDate = date;
                                  _tournamentStartTime = time;
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text('All dates are saved with the Asia/Kolkata timezone offset (+05:30).', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                          ]),
                        ),
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF172A31),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: KomnivoTheme.cyan.withValues(alpha: .35)),
                          ),
                          child: const Text(
                            'Saving creates a recoverable tournament preview in Organizer AI. Keep as Draft creates a private, editable DRAFT event; Publish creates the tournament category and channels. Registration remains closed until the organiser opens it separately.',
                            style: TextStyle(fontSize: 11, height: 1.4, color: Colors.white70),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            onPressed: _loading || _saving ? null : _submit,
                            icon: _saving
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : Icon(editing ? Icons.save_outlined : Icons.send_rounded),
                            label: Text(_saving
                                ? 'Saving…'
                                : editing ? 'Save tournament changes' : 'Save draft & preview in chat'),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
    );
  }
}
