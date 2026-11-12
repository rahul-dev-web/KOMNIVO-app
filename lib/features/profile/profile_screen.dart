import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.preview, this.onBack});
  final bool preview;
  final VoidCallback? onBack;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  final _uid = TextEditingController();
  bool _loading = false;
  String _syncMessage = 'Game profile is not linked yet.';
  Map<String, dynamic>? _verification;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _load();
  }

  Future<void> _load() async {
    try {
      final repo = KomnivoRepository.instance;
      final profile = await repo.myProfile();
      final verification = await repo.myGameAccountVerification();
      if (!mounted) return;
      _name.text = profile['display_name']?.toString() ?? '';
      _bio.text = profile['bio']?.toString() ?? '';
      _verification = verification;
      if ((verification['uid'] ?? '').toString().isNotEmpty) {
        _uid.text = verification['uid'].toString();
        _syncMessage = '${verification['nickname'] ?? 'Free Fire profile'} · profile data loaded';
      }
      setState(() {});
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final repo = KomnivoRepository.instance;
      await repo.client.from('profiles').upsert({
        'id': repo.userId,
        'display_name': _name.text.trim(),
        'bio': _bio.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (mounted) showMessage(context, 'Profile saved.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncUid() async {
    final uid = _uid.text.trim();
    if (!RegExp(r'^\d{5,15}$').hasMatch(uid)) {
      showMessage(context, 'Enter a valid Free Fire UID (5–15 digits).');
      return;
    }
    setState(() {
      _loading = true;
      _syncMessage = 'Fetching the game profile and submitting a Support verification request…';
    });
    try {
      final result = await KomnivoRepository.instance.syncFreeFire(uid);
      final profile = (result['profile'] is Map)
          ? Map<String, dynamic>.from(result['profile'] as Map)
          : <String, dynamic>{};
      final verification = (result['verification'] is Map)
          ? Map<String, dynamic>.from(result['verification'] as Map)
          : await KomnivoRepository.instance.myGameAccountVerification();
      if (!mounted) return;
      setState(() {
        _verification = verification;
        _syncMessage = '${profile['nickname'] ?? profile['accountName'] ?? 'Profile found'} · ownership verification pending';
      });
      showMessage(context, 'Game profile found. Verification is now pending with KOMNIVO Support.');
    } catch (error) {
      if (mounted) setState(() => _syncMessage = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _verificationCard() {
    final verification = _verification;
    if (verification == null) return const SizedBox.shrink();

    final status = verification['status']?.toString() ?? 'not_submitted';
    final isVerified = status == 'verified';
    final isRejected = status == 'rejected';
    final title = switch (status) {
      'verified' => 'Ownership Verified',
      'rejected' => 'Verification Needs Attention',
      'batched' => 'Verification Pending · Batch Assigned',
      'scheduled' => 'Verification Pending · Room Scheduled',
      'pending' => 'Verification Pending',
      _ => 'Ownership Not Yet Verified',
    };
    final accent = isVerified
        ? const Color(0xFF58D6A1)
        : isRejected
            ? const Color(0xFFFF7188)
            : KomnivoTheme.cyan;
    final message = verification['message']?.toString() ??
        'UID lookup does not prove game-account ownership. The KOMNIVO Support Team must complete the in-game check.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: .55)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(isVerified ? Icons.verified_user : Icons.hourglass_top_rounded, color: accent),
          const SizedBox(width: 9),
          Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: accent, fontSize: 16))),
        ]),
        const SizedBox(height: 10),
        Text(message, style: const TextStyle(color: Colors.white, height: 1.45, fontSize: 13)),
        const SizedBox(height: 12),
        const Text(
          'Verification is handled only by the KOMNIVO Platform Support Team — not by community owners or tournament organisers. Support will contact you using the contact details available on your KOMNIVO account.',
          style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
        ),
        if (verification['scheduled_at'] != null) ...[
          const SizedBox(height: 8),
          Text(
            'Room session: ${DateTime.tryParse(verification['scheduled_at'].toString())?.toLocal().toString() ?? verification['scheduled_at']}',
            style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 12),
          ),
        ],
      ]),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _uid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      SectionTitle('Player profile', subtitle: 'Your platform identity and game identity',
        trailing: widget.onBack == null ? null : IconButton(onPressed: widget.onBack, icon: const Icon(Icons.close))),
      const SizedBox(height: 16),
      if (widget.preview) const PreviewBanner(),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            CircleAvatar(radius: 25, child: Icon(Icons.person_outline, size: 26)),
            SizedBox(width: 12),
            Expanded(child: Text('Your KOMNIVO identity', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17))),
          ]),
          const SizedBox(height: 18),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name')),
          const SizedBox(height: 12),
          TextField(controller: _bio, maxLines: 3, decoration: const InputDecoration(labelText: 'Bio')),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: widget.preview || _loading ? null : _save,
            child: const Text('Save profile'),
          )),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Free Fire account · India region', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 6),
          const Text(
            'Enter your UID to look up the supported public game profile. A successful lookup automatically submits an ownership-verification request to KOMNIVO Support.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _uid,
            keyboardType: TextInputType.number,
            maxLength: 15,
            decoration: const InputDecoration(labelText: 'Free Fire UID', hintText: '5–15 digits'),
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.info_outline, size: 16, color: KomnivoTheme.cyan),
            const SizedBox(width: 7),
            Expanded(child: Text(_syncMessage, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12))),
          ]),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: widget.preview || _loading ? null : _syncUid,
            icon: _loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: Text(_loading ? 'Please wait…' : 'Lookup UID & request verification · IND'),
          )),
          const SizedBox(height: 10),
          const Text(
            'UID lookup is not ownership proof. Do not share your game password or OTP. Ownership is confirmed only after the Support Team checks your UID in the 48-player solo room.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      _verificationCard(),
      const SizedBox(height: 16),
      if (!widget.preview) OutlinedButton.icon(
        onPressed: () async => Supabase.instance.client.auth.signOut(),
        icon: const Icon(Icons.logout),
        label: const Text('Sign out'),
      ),
    ]);
  }
}
