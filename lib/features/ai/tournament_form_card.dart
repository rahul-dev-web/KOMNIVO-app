import 'package:flutter/material.dart';

import '../../core/komnivo_theme.dart';

/// Converts a picked wall-clock time to an explicit India Standard Time
/// ISO-8601 timestamp. It does not depend on the device timezone.
String formatKOMNIVOIstTimestamp(DateTime date, TimeOfDay time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}T'
      '${two(time.hour)}:${two(time.minute)}:00+05:30';
}

class TournamentFormCard extends StatefulWidget {
  const TournamentFormCard({
    super.key,
    required this.communities,
    required this.loadingCommunities,
    required this.communityLoadError,
    required this.initialCommunityId,
    required this.busy,
    required this.onSubmit,
    required this.onClose,
  });

  final List<Map<String, String>> communities;
  final bool loadingCommunities;
  final String? communityLoadError;
  final String? initialCommunityId;
  final bool busy;
  final void Function(String message, String communityId) onSubmit;
  final VoidCallback onClose;

  @override
  State<TournamentFormCard> createState() => _TournamentFormCardState();
}

class _TournamentFormCardState extends State<TournamentFormCard> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _teams = TextEditingController(text: '12');
  final _prize = TextEditingController(text: '1000');
  final _stages = TextEditingController(text: '1 (Final only)');
  final _matches = TextEditingController(text: '6 back-to-back matches');
  final _rules = TextEditingController(text: 'Free Fire standard rules');
  final _scoring = TextEditingController(
    text: '1 point per kill; placement points per match: 1st 12, 2nd 9, 3rd 8, 4th 7, 5th 6, 6th 5, 7th 4, 8th 3, 9th 2, 10th 1, 11th 0, 12th 0.',
  );
  final _prizeDistribution = TextEditingController(
    text: 'Only 1st place receives the full prize pool.',
  );
  final _matchNotes = TextEditingController(
    text: 'All maps will be randomly decided.',
  );

  static const String _game = 'Free Fire MAX';
  String _format = 'squad';
  String? _communityId;
  DateTime? _startDate;
  TimeOfDay? _startTime;
  DateTime? _registrationDate;
  TimeOfDay? _registrationTime;
  bool _showAdvanced = false;

  static const _modes = <String, String>{
    'solo': 'Solo',
    'duo': 'Duo',
    'squad': 'Squad',
    'custom': 'Custom',
  };

  @override
  void initState() {
    super.initState();
    _communityId = widget.initialCommunityId ??
        (widget.communities.length == 1 ? widget.communities.first['id'] : null);
  }

  @override
  void didUpdateWidget(covariant TournamentFormCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_communityId == null && widget.communities.length == 1) {
      _communityId = widget.communities.first['id'];
    } else if (_communityId != null &&
        !widget.communities.any((community) => community['id'] == _communityId)) {
      _communityId = widget.initialCommunityId ??
          (widget.communities.length == 1 ? widget.communities.first['id'] : null);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _teams.dispose();
    _prize.dispose();
    _stages.dispose();
    _matches.dispose();
    _rules.dispose();
    _scoring.dispose();
    _prizeDistribution.dispose();
    _matchNotes.dispose();
    super.dispose();
  }

  String _dateLabel(DateTime? date) {
    if (date == null) return 'Choose date';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  String _timeLabel(TimeOfDay? time) {
    if (time == null) return 'Choose time';
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    return '${hour}:${time.minute.toString().padLeft(2, '0')} ${time.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  DateTime _todayInIndia() {
    final indiaNow = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    return DateTime(indiaNow.year, indiaNow.month, indiaNow.day);
  }

  Future<void> _pickStart() async {
    final todayInIndia = _todayInIndia();
    final date = await showDatePicker(
      context: context,
      initialDate: _startDate ?? todayInIndia,
      firstDate: todayInIndia,
      lastDate: DateTime(2100),
      helpText: 'Tournament start date (IST)',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _startTime ?? const TimeOfDay(hour: 18, minute: 0),
      helpText: 'Tournament start time (IST)',
    );
    if (time == null || !mounted) return;
    setState(() {
      _startDate = date;
      _startTime = time;
    });
  }

  Future<void> _pickRegistrationClose() async {
    final todayInIndia = _todayInIndia();
    final date = await showDatePicker(
      context: context,
      initialDate: _registrationDate ?? _startDate ?? todayInIndia,
      firstDate: todayInIndia,
      lastDate: DateTime(2100),
      helpText: 'Registration closing date (IST)',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _registrationTime ?? const TimeOfDay(hour: 11, minute: 0),
      helpText: 'Registration closing time (IST)',
    );
    if (time == null || !mounted) return;
    setState(() {
      _registrationDate = date;
      _registrationTime = time;
    });
  }

  DateTime _asUtc(DateTime date, TimeOfDay time) => DateTime.utc(
        date.year, date.month, date.day, time.hour, time.minute,
      ).subtract(const Duration(hours: 5, minutes: 30));

  void _submit() {
    if (widget.busy || widget.loadingCommunities) return;
    if (!_formKey.currentState!.validate()) return;
    final selectedCommunities = widget.communities.where(
      (community) => community['id'] == _communityId,
    );
    if (selectedCommunities.isEmpty) {
      _showError('Select a community that you manage.');
      return;
    }
    final selectedCommunity = selectedCommunities.first;
    if (_startDate == null || _startTime == null) {
      _showError('Select the tournament start date and time.');
      return;
    }
    if (_registrationDate == null || _registrationTime == null) {
      _showError('Select the registration closing date and time.');
      return;
    }

    final startUtc = _asUtc(_startDate!, _startTime!);
    final closeUtc = _asUtc(_registrationDate!, _registrationTime!);
    final nowUtc = DateTime.now().toUtc();
    if (!startUtc.isAfter(nowUtc)) {
      _showError('Tournament start must be in the future (IST).');
      return;
    }
    if (!closeUtc.isAfter(nowUtc)) {
      _showError('Registration closing time must be in the future (IST).');
      return;
    }
    if (!closeUtc.isBefore(startUtc)) {
      _showError('Registration must close before the tournament starts.');
      return;
    }

    final teamCount = int.parse(_teams.text.trim());
    final prizeAmount = int.parse(_prize.text.trim());
    final startIso = formatKOMNIVOIstTimestamp(_startDate!, _startTime!);
    final closeIso = formatKOMNIVOIstTimestamp(_registrationDate!, _registrationTime!);
    final message = [
      'Create a tournament draft using these confirmed details:',
      'Community: ${selectedCommunity['name']} (community_id: ${selectedCommunity['id']})',
      'Tournament name: ${_name.text.trim()}',
      'Game: Free Fire MAX (game_code: free_fire_max)',
      'Mode: ${_modes[_format]} (${_format})',
      'Maximum teams: ${teamCount}',
      'Stages: ${_stages.text.trim()}',
      'Prize pool: INR ${prizeAmount}',
      'Prize distribution: ${_prizeDistribution.text.trim()}',
      'Tournament starts: ${startIso} (India Standard Time, Asia/Kolkata, UTC+05:30)',
      'Registration closes: ${closeIso} (India Standard Time, Asia/Kolkata, UTC+05:30)',
      'Rules: ${_rules.text.trim()}',
      'Scoring: ${_scoring.text.trim()}',
      'Matches: ${_matches.text.trim()}',
      'Map selection: ${_matchNotes.text.trim()}',
      'Put prize pool, prize distribution, stage count, match count and map selection into the structured event rules data, and scoring values into scoring_config. Use the exact timestamps above. Do not change any confirmed values or invent missing details.',
    ].join('\n');
    widget.onSubmit(message, selectedCommunity['id']!);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _dateTimeTile({
    required IconData icon,
    required String title,
    required DateTime? date,
    required TimeOfDay? time,
    required VoidCallback onTap,
  }) {
    final selected = date != null && time != null;
    return InkWell(
      onTap: widget.busy ? null : onTap,
      borderRadius: BorderRadius.circular(13),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: KomnivoTheme.surfaceRaised,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Row(children: [
          Icon(icon, size: 19, color: KomnivoTheme.cyan),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(
              selected ? '${_dateLabel(date)} · ${_timeLabel(time)} IST' : 'Choose date and time',
              style: TextStyle(
                color: selected ? Colors.white : KomnivoTheme.muted,
                fontSize: 12,
              ),
            ),
          ])),
          const Icon(Icons.edit_calendar_outlined, size: 18, color: KomnivoTheme.muted),
        ]),
      ),
    );
  }

  InputDecoration _decoration(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.cyan.withValues(alpha: .55)),
      ),
      child: Form(
        key: _formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.emoji_events_outlined, color: KomnivoTheme.cyan),
            const SizedBox(width: 8),
            const Expanded(child: Text(
              'CREATE TOURNAMENT',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: .6),
            )),
            IconButton(
              tooltip: 'Close form',
              visualDensity: VisualDensity.compact,
              onPressed: widget.busy ? null : widget.onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ]),
          const SizedBox(height: 7),
          if (widget.loadingCommunities)
            const LinearProgressIndicator(minHeight: 2)
          else if (widget.communities.isEmpty)
            Text(
              widget.communityLoadError ?? 'No communities with organizer access were found.',
              style: const TextStyle(color: KomnivoTheme.danger, fontSize: 12),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: widget.communities.any((row) => row['id'] == _communityId)
                  ? _communityId
                  : null,
              isExpanded: true,
              decoration: _decoration('Community'),
              items: widget.communities.map((community) => DropdownMenuItem<String>(
                value: community['id'],
                child: Text(community['name'] ?? 'Community', overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: widget.busy ? null : (value) => setState(() => _communityId = value),
              validator: (value) => value == null ? 'Choose a community' : null,
            ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _name,
            decoration: _decoration('Tournament name', hint: 'e.g. Testing.ai'),
            textCapitalization: TextCapitalization.sentences,
            validator: (value) => (value == null || value.trim().length < 3)
                ? 'Enter at least 3 characters' : null,
          ),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _format,
                isExpanded: true,
                decoration: _decoration('Mode'),
                items: _modes.entries.map((entry) => DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value),
                )).toList(),
                onChanged: widget.busy ? null : (value) {
                  if (value != null) setState(() => _format = value);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _teams,
                decoration: _decoration('Max teams'),
                keyboardType: TextInputType.number,
                validator: (value) {
                  final count = int.tryParse(value?.trim() ?? '');
                  return count == null || count < 1 || count > 1000 ? '1–1000' : null;
                },
              ),
            ),
          ]),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: _game,
              readOnly: true,
              decoration: _decoration('Game'),
            )),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(
              controller: _prize,
              decoration: _decoration('Prize pool (₹)'),
              keyboardType: TextInputType.number,
              validator: (value) {
                final amount = int.tryParse(value?.trim() ?? '');
                return amount == null || amount < 0 ? 'Enter amount' : null;
              },
            )),
          ]),
          const SizedBox(height: 9),
          _dateTimeTile(
            icon: Icons.event_outlined,
            title: 'Tournament starts',
            date: _startDate,
            time: _startTime,
            onTap: _pickStart,
          ),
          const SizedBox(height: 8),
          _dateTimeTile(
            icon: Icons.lock_clock_outlined,
            title: 'Registration closes',
            date: _registrationDate,
            time: _registrationTime,
            onTap: _pickRegistrationClose,
          ),
          const SizedBox(height: 8),
          const Row(children: [
            Icon(Icons.schedule, size: 15, color: KomnivoTheme.cyan),
            SizedBox(width: 6),
            Expanded(child: Text(
              'Timezone fixed: India Standard Time · Asia/Kolkata · UTC+05:30',
              style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, height: 1.25),
            )),
          ]),
          const SizedBox(height: 6),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              initiallyExpanded: _showAdvanced,
              onExpansionChanged: (value) => setState(() => _showAdvanced = value),
              title: const Text('Rules, scoring and match details',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              children: [
                TextFormField(controller: _stages, decoration: _decoration('Stages')),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _rules,
                  minLines: 2,
                  maxLines: 3,
                  decoration: _decoration('Rules'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _scoring,
                  minLines: 3,
                  maxLines: 5,
                  decoration: _decoration('Scoring rules'),
                ),
                const SizedBox(height: 8),
                TextFormField(controller: _matches, decoration: _decoration('Matches')),
                const SizedBox(height: 8),
                TextFormField(controller: _matchNotes, decoration: _decoration('Map selection / match notes')),
                const SizedBox(height: 8),
                TextFormField(controller: _prizeDistribution, decoration: _decoration('Prize distribution')),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: widget.busy || widget.loadingCommunities || widget.communities.isEmpty
                  ? null : _submit,
              icon: const Icon(Icons.send_rounded, size: 17),
              label: const Text('Send details to Player AI'),
            ),
          ),
        ]),
      ),
    );
  }
}
