import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _bioConfirmed = false;
  String _syncMessage = 'Game profile is not linked yet.';
  Map<String, dynamic>? _verification;
  String? _challengeCode;
  DateTime? _challengeExpiresAt;

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
        _syncMessage = verification['nickname']?.toString() ?? 'Free Fire profile loaded';
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
      if (mounted) showMessage(context, 'KOMNIVO profile saved.');
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
      _bioConfirmed = false;
      _challengeCode = null;
      _challengeExpiresAt = null;
      _syncMessage = 'Looking up your public profile and generating a one-time ownership code…';
    });
    try {
      final result = await KomnivoRepository.instance.syncFreeFire(uid);
      final profile = result['profile'] is Map
          ? Map<String, dynamic>.from(result['profile'] as Map)
          : <String, dynamic>{};
      if (!mounted) return;
      final status = result['status']?.toString() ?? 'proof_pending';
      setState(() {
        _verification = {
          ...result,
          'uid': uid,
          'nickname': profile['nickname'] ?? 'Free Fire player',
          'ownership_status': result['ownership_status'] ?? status,
          'status': status,
        };
        _challengeCode = result['challenge_code']?.toString();
        _challengeExpiresAt = DateTime.tryParse(result['challenge_expires_at']?.toString() ?? '');
        _syncMessage = status == 'verified'
            ? 'Free Fire profile found · ownership already verified'
            : (profile['nickname'] ?? 'Profile found').toString() + ' · ownership verification pending';
      });
      showMessage(
        context,
        status == 'verified'
            ? 'This Free Fire account is already verified.'
            : 'Profile found. Paste the new code into your Free Fire Bio/Signature.',
      );
    } catch (error) {
      if (mounted) setState(() => _syncMessage = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyChallenge() async {
    final code = _challengeCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showMessage(context, 'Verification code copied.');
  }

  Future<void> _verifyBio() async {
    final verification = _verification;
    final accountId = verification?['account_id']?.toString();
    if (accountId == null || accountId.isEmpty) {
      showMessage(context, 'Look up your Free Fire UID first.');
      return;
    }
    if (!_bioConfirmed) {
      showMessage(context, 'Confirm that the exact code is saved as your complete Bio.');
      return;
    }

    setState(() {
      _loading = true;
      _syncMessage = 'Checking the latest Free Fire profile Bio/Signature…';
    });
    try {
      final result = await KomnivoRepository.instance.verifyFreeFireOwnership(
        accountId: accountId,
        bioConfirmed: _bioConfirmed,
      );
      if (!mounted) return;
      setState(() {
        _verification = {
          ...?_verification,
          ...result,
          'status': 'verified',
          'ownership_status': 'verified',
          'uid': _uid.text.trim(),
        };
        _challengeCode = null;
        _challengeExpiresAt = null;
        _bioConfirmed = false;
        _syncMessage = 'Ownership verified · you may change your Bio back now.';
      });
      showMessage(context, 'Free Fire ownership verified. You may restore your previous Bio.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _syncMessage = error.toString());
      showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _verificationCard() {
    final verification = _verification;
    if (verification == null) return const SizedBox.shrink();

    final status = verification['status']?.toString() ??
        verification['ownership_status']?.toString() ?? 'not_linked';
    final isVerified = status == 'verified' || verification['ownership_status'] == 'verified';
    final challengeStatus = verification['challenge_status']?.toString();
    final isExpired = status == 'expired' || challengeStatus == 'expired';
    final isLocked = challengeStatus == 'locked';
    final accent = isVerified
        ? const Color(0xFF58D6A1)
        : (isExpired || isLocked)
            ? const Color(0xFFFFC66D)
            : KomnivoTheme.cyan;
    final title = isVerified
        ? 'Free Fire Ownership Verified'
        : isExpired || isLocked
            ? 'Generate a New Verification Code'
            : 'Ownership Verification Pending';
    final message = isVerified
        ? 'KOMNIVO confirmed that the code appeared as the complete Bio/Signature on the linked Free Fire profile. You may now restore your previous Bio.'
        : isExpired
            ? 'The previous code expired after 30 minutes. Look up the same UID again to generate a fresh code.'
            : isLocked
                ? 'This code reached its five-check limit. Look up the same UID again to generate a fresh code.'
                : 'UID lookup only finds public profile data. Ownership remains pending until the one-time code is visible in the linked game profile Bio/Signature.';

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
        if (!isVerified) ...[
          const SizedBox(height: 10),
          const Text(
            'The checkbox only confirms that you pasted the code. KOMNIVO grants Verified status only after the server re-reads the profile and finds an exact code match.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
          ),
        ],
      ]),
    );
  }

  Widget _challengePanel() {
    final code = _challengeCode;
    final isVerified = _verification?['status'] == 'verified' ||
        _verification?['ownership_status'] == 'verified';
    if (code == null || isVerified) return const SizedBox.shrink();

    final expires = _challengeExpiresAt;
    final expiryLabel = expires == null
        ? 'Code expires in 30 minutes'
        : 'Code expires at ' + TimeOfDay.fromDateTime(expires).format(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .65)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Your one-time verification code', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
          decoration: BoxDecoration(
            color: KomnivoTheme.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: KomnivoTheme.line),
          ),
          child: Row(children: [
            Expanded(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: KomnivoTheme.cyan,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            IconButton(
              onPressed: _loading ? null : _copyChallenge,
              icon: const Icon(Icons.copy_rounded),
              tooltip: 'Copy code',
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Text(expiryLabel, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
        const SizedBox(height: 14),
        const Text('Do this inside Free Fire India', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 7),
        const Text(
          '1. Copy the code above.\n'
          '2. Open Free Fire India and edit your profile Bio/Signature.\n'
          '3. Delete the existing Bio and paste only this code — no name, spaces or other text before or after it.\n'
          '4. Save the change in-game, return to KOMNIVO and tick the confirmation below.\n'
          '5. Tap “Verify Bio”. If the game/API has not refreshed yet, wait 20–30 seconds and try again.',
          style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.55),
        ),
        const SizedBox(height: 10),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _bioConfirmed,
          onChanged: _loading ? null : (value) => setState(() => _bioConfirmed = value ?? false),
          title: const Text(
            'I have replaced my Free Fire Bio/Signature with this exact code only. There is no other text before or after it.',
            style: TextStyle(fontSize: 12, height: 1.35),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: widget.preview || _loading || !_bioConfirmed ? null : _verifyBio,
            icon: _loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.verified_outlined),
            label: Text(_loading ? 'Checking Bio…' : 'Verify Bio'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'After KOMNIVO verifies the account, you can immediately change your Bio back to your old text.',
          style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, height: 1.4),
        ),
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
      SectionTitle(
        'Player profile',
        subtitle: 'Your platform identity and game identity',
        trailing: widget.onBack == null
            ? null
            : IconButton(onPressed: widget.onBack, icon: const Icon(Icons.close)),
      ),
      const SizedBox(height: 16),
      if (widget.preview) const PreviewBanner(),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: KomnivoTheme.line),
        ),
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
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: widget.preview || _loading ? null : _save,
              child: const Text('Save profile'),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Free Fire account · India region', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 6),
          const Text(
            'Enter your Free Fire UID to fetch your public profile. Ownership is verified separately through a temporary code placed in your in-game Bio/Signature.',
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
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.preview || _loading ? null : _syncUid,
              icon: _loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: Text(_loading ? 'Please wait…' : 'Lookup UID & generate verification code · IND'),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Never share your game password or OTP. The verification code must be the entire Bio value.',
            style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      _challengePanel(),
      _verificationCard(),
      const SizedBox(height: 16),
      if (!widget.preview)
        OutlinedButton.icon(
          onPressed: () async => Supabase.instance.client.auth.signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
    ]);
  }
}
