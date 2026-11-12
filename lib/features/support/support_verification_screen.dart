import 'package:flutter/material.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class SupportVerificationScreen extends StatefulWidget {
  const SupportVerificationScreen({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  State<SupportVerificationScreen> createState() => _SupportVerificationScreenState();
}

class _SupportVerificationScreenState extends State<SupportVerificationScreen> {
  final _repo = KomnivoRepository.instance;
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _batches = [];
  List<Map<String, dynamic>> _members = [];
  String? _selectedBatchId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() { _busy = true; _error = null; });
    try {
      final requests = await _repo.supportVerificationRequests();
      final batches = await _repo.supportVerificationBatches();
      if (!mounted) return;
      setState(() { _requests = requests; _batches = batches; });
      if (_selectedBatchId != null) await _loadMembers(_selectedBatchId!);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _assign(Map<String, dynamic> request) async {
    setState(() => _busy = true);
    try {
      Map<String, dynamic>? openBatch;
      for (final batch in _batches) {
        if (batch['status'] == 'forming') { openBatch = batch; break; }
      }
      if (openBatch == null) openBatch = await _repo.createSupportVerificationBatch();
      final batchId = (openBatch['batch_id'] ?? openBatch['id']).toString();
      final result = await _repo.assignSupportVerificationRequest(request['request_id'].toString(), batchId);
      if (mounted) showMessage(context, 'Player assigned · ${result['participant_count'] ?? '?'} of 48 slots filled.');
      await _refresh();
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _schedule(Map<String, dynamic> batch) async {
    final roomId = TextEditingController();
    final roomPassword = TextEditingController();
    final suggested = DateTime.now().add(const Duration(days: 1)).toLocal();
    final scheduledAt = TextEditingController(
      text: '${suggested.year.toString().padLeft(4, '0')}-${suggested.month.toString().padLeft(2, '0')}-${suggested.day.toString().padLeft(2, '0')} ${suggested.hour.toString().padLeft(2, '0')}:${suggested.minute.toString().padLeft(2, '0')}',
    );
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Schedule solo verification room'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: roomId, decoration: const InputDecoration(labelText: 'In-game Room ID')),
          const SizedBox(height: 10),
          TextField(controller: roomPassword, decoration: const InputDecoration(labelText: 'In-game Room Password')),
          const SizedBox(height: 10),
          TextField(controller: scheduledAt, decoration: const InputDecoration(labelText: 'Local date/time · YYYY-MM-DD HH:mm')),
          const SizedBox(height: 8),
          const Text('Room credentials remain in the private Support workspace. Contact the 48 players using their KOMNIVO account email/contact details.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Schedule')),
        ],
      ),
    );
    if (confirm == true) {
      final parsed = DateTime.tryParse(scheduledAt.text.trim().replaceFirst(' ', 'T'));
      if (parsed == null) {
        if (mounted) showMessage(context, 'Enter date/time as YYYY-MM-DD HH:mm.');
      } else {
        setState(() => _busy = true);
        try {
          await _repo.scheduleSupportVerificationBatch(
            batchId: batch['batch_id'].toString(),
            scheduledAt: parsed,
            roomId: roomId.text.trim(),
            roomPassword: roomPassword.text.trim(),
          );
          if (mounted) showMessage(context, 'Solo room scheduled. Contact all 48 players.');
          await _refresh();
        } catch (error) {
          if (mounted) showMessage(context, error.toString());
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }
    roomId.dispose();
    roomPassword.dispose();
    scheduledAt.dispose();
  }

  Future<void> _loadMembers(String batchId) async {
    try {
      final members = await _repo.supportVerificationBatchMembers(batchId);
      if (mounted) setState(() { _selectedBatchId = batchId; _members = members; });
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _start(Map<String, dynamic> batch) async {
    setState(() => _busy = true);
    try {
      await _repo.startSupportVerificationBatch(batch['batch_id'].toString());
      await _loadMembers(batch['batch_id'].toString());
      await _refresh();
      if (mounted) showMessage(context, 'Solo-room verification session started.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _record(Map<String, dynamic> member, String outcome) async {
    setState(() => _busy = true);
    try {
      await _repo.recordSupportVerificationResult(
        memberId: member['member_id'].toString(),
        outcome: outcome,
      );
      if (mounted) showMessage(context, switch (outcome) {
        'verified' => 'Player ownership verified.',
        'rejected' => 'Player marked as not verified.',
        _ => 'Player marked as no-show and returned to the pending queue.',
      });
      await _refresh();
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _memberCard(Map<String, dynamic> member) {
    final outcome = member['outcome']?.toString() ?? 'pending';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KomnivoTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Slot ${member['slot_number']}: ${member['display_name'] ?? 'Player'}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(height: 4),
        Text('UID ${member['uid'] ?? '—'} · IGN ${member['nickname'] ?? '—'}',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
        Text(member['contact_email']?.toString() ?? 'No account email',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
        if (outcome == 'pending')
          Wrap(spacing: 4, children: [
            TextButton(onPressed: _busy ? null : () => _record(member, 'verified'), child: const Text('Verified')),
            TextButton(onPressed: _busy ? null : () => _record(member, 'no_show'), child: const Text('No-show')),
            TextButton(onPressed: _busy ? null : () => _record(member, 'rejected'), child: const Text('Reject')),
          ])
        else
          Text('Result: ${outcome.replaceAll('_', ' ').toUpperCase()}',
            style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800, fontSize: 11)),
      ]),
    );
  }

  Widget _batchCard(Map<String, dynamic> batch) {
    final count = (batch['participant_count'] as num?)?.toInt() ?? 0;
    final status = batch['status']?.toString() ?? 'forming';
    final isSelected = _selectedBatchId == batch['batch_id'].toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.groups_2_outlined, color: KomnivoTheme.cyan),
            const SizedBox(width: 8),
            Expanded(child: Text('Solo room batch · $count/48',
              style: const TextStyle(fontWeight: FontWeight.w900))),
            Text(status.replaceAll('_', ' ').toUpperCase(),
              style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 8),
          if (status == 'forming')
            const Text('Waiting for 48 different players with unique game UIDs. Do not open the room before all slots are assigned.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4)),
          if (status == 'ready_for_room')
            SizedBox(width: double.infinity, child: FilledButton(
              onPressed: _busy ? null : () => _schedule(batch),
              child: const Text('Create & schedule in-game solo room'),
            )),
          if (status == 'scheduled') ...[
            Text('Room ID: ${batch['room_id'] ?? '—'} · Password: ${batch['room_password'] ?? '—'}',
              style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            Text('Scheduled: ${batch['scheduled_at'] ?? '—'}',
              style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            SizedBox(width: double.infinity, child: FilledButton(
              onPressed: _busy ? null : () => _start(batch),
              child: const Text('Start solo-room verification'),
            )),
          ],
          if (status == 'in_progress' || status == 'completed')
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _loadMembers(batch['batch_id'].toString()),
              icon: const Icon(Icons.people_outline),
              label: Text(isSelected ? 'Refresh 48 slots' : 'Review 48 player slots'),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _requests.where((row) => row['status'] == 'pending').toList();
    return ListView(padding: const EdgeInsets.all(20), children: [
      SectionTitle(
        'Platform Support · Game Verification',
        subtitle: 'Private management workspace — separate from Event Organisers',
        trailing: widget.onBack == null ? null : IconButton(onPressed: widget.onBack, icon: const Icon(Icons.close)),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .5)),
        ),
        child: const Text(
          'Only authorised Platform Support staff can manage this queue. Each in-game solo room is opened after 48 unique players are assigned. Check every player UID in the room before recording an outcome.',
          style: TextStyle(color: Colors.white, fontSize: 12, height: 1.45),
        ),
      ),
      const SizedBox(height: 18),
      Row(children: [
        const Expanded(child: SectionTitle('Pending UID requests', subtitle: 'Players waiting for a full batch')),
        IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh)),
      ]),
      if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12)),
      if (_busy && _requests.isEmpty) const LinearProgressIndicator(),
      if (!_busy && pending.isEmpty)
        const Text('No pending ownership requests.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ...pending.map((request) => Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(request['display_name']?.toString() ?? 'KOMNIVO player',
            style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text('UID: ${request['uid'] ?? '—'} · IGN: ${request['nickname'] ?? '—'} · ${request['region'] ?? 'IND'}',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
          Text('Contact: ${request['contact_email'] ?? 'No account email'}',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
          SizedBox(width: double.infinity, child: OutlinedButton(
            onPressed: _busy ? null : () => _assign(request),
            child: const Text('Assign to next 48-player solo room'),
          )),
        ]),
      )),
      const SizedBox(height: 16),
      Row(children: [
        const Expanded(child: SectionTitle('48-player solo-room batches', subtitle: 'Managed only by Platform Support')),
        IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh)),
      ]),
      if (_batches.isEmpty)
        const Text('No verification batches created yet.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ..._batches.map(_batchCard),
      if (_selectedBatchId != null) ...[
        const SizedBox(height: 12),
        SectionTitle('Player slots', subtitle: 'In-game UID checks for selected batch'),
        if (_members.isEmpty)
          const Text('No member slots loaded.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
        ..._members.map(_memberCard),
      ],
    ]);
  }
}
