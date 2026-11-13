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
  Map<String, dynamic>? _gameProfile;
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
      _uid.text = verification['uid']?.toString() ?? '';
      _challengeExpiresAt = DateTime.tryParse(
        verification['challenge_expires_at']?.toString() ?? '',
      );

      if (verification['nickname'] != null) {
        _gameProfile = {
          'nickname': verification['nickname'],
          'level': verification['level'],
          'rank': verification['rank_label'],
          'region': verification['region'],
        };
      }
      _syncMessage = verification['message']?.toString() ??
          'Enter your Free Fire UID to generate a verification code.';
      setState(() {});
    } catch (_) {
      // Keep the platform profile form usable if status retrieval is unavailable.
    }
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

  Future<void> _generateCode() async {
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
      _syncMessage = 'Preparing your one-time verification code. Free Fire profile API will not be called yet…';
    });

    try {
      final result = await KomnivoRepository.instance.prepareFreeFireVerification(uid);
      if (!mounted) return;

      final status = result['status']?.toString() ?? 'proof_pending';
      final locked = status == 'locked';
      final verified = status == 'verified';

      setState(() {
        _verification = {
          ...?_verification,
          ...result,
          'uid': uid,
          'status': status,
          'ownership_status': result['ownership_status'] ?? status,
        };
        _challengeCode = result['challenge_code']?.toString();
        _challengeExpiresAt = DateTime.tryParse(
          result['challenge_expires_at']?.toString() ?? '',
        );
        _syncMessage = result['message']?.toString() ??
            (verified
                ? 'This Free Fire account is already verified.'
                : locked
                    ? 'Contact KOMNIVO Support.'
                    : 'Verification code is ready.');
      });

      showMessage(
        context,
        verified
            ? 'This Free Fire account is already verified.'
            : locked
                ? 'Three verification requests used. Contact KOMNIVO Support.'
                : 'Code generated. Replace your complete Free Fire Bio with this exact code only.',
      );
    } catch (error) {
      if (mounted) {
        setState(() => _syncMessage = error.toString());
        showMessage(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyChallenge() async {
    final code = _challengeCode;
    if (code == null || code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showMessage(context, 'Exact verification code copied.');
  }

  Future<void> _verifyBio() async {
    final accountId = _verification?['account_id']?.toString();
    if (accountId == null || accountId.isEmpty) {
      showMessage(context, 'Generate a verification code first.');
      return;
    }
    if (_challengeCode == null || _challengeCode!.isEmpty) {
      showMessage(context, 'Generate a fresh verification code first.');
      return;
    }
    if (!_bioConfirmed) {
      showMessage(context, 'Confirm that the complete Bio contains only this exact code.');
      return;
    }

    setState(() {
      _loading = true;
      _syncMessage = 'Checking your Free Fire profile and Bio in one API request…';
    });

    try {
      final result = await KomnivoRepository.instance.verifyFreeFireOwnership(
        accountId: accountId,
        bioConfirmed: _bioConfirmed,
      );
      if (!mounted) return;

      final status = result['status']?.toString() ?? 'proof_pending';
      final verified = status == 'verified' || result['verified'] == true;
      final locked = status == 'locked';
      final expired = status == 'expired';
      final throttled = status == 'throttled';

      setState(() {
        _verification = {
          ...?_verification,
          ...result,
          'status': status,
          'ownership_status': result['ownership_status'] ??
              (verified ? 'verified' : 'proof_pending'),
          'uid': _uid.text.trim(),
        };

        if (result['profile'] is Map) {
          _gameProfile = Map<String, dynamic>.from(result['profile'] as Map);
        }

        if (verified) {
          _challengeCode = null;
          _challengeExpiresAt = null;
          _bioConfirmed = false;
          _syncMessage = 'Ownership verified. You may change your Bio back now.';
        } else if (locked) {
          _challengeCode = null;
          _bioConfirmed = false;
          _syncMessage = result['error']?.toString() ??
              'All three verification requests are used. Contact KOMNIVO Support.';
        } else if (expired) {
          _challengeCode = null;
          _bioConfirmed = false;
          _syncMessage = result['error']?.toString() ??
              'The code expired. Generate a new code; attempts will not reset.';
        } else if (throttled) {
          _syncMessage = result['error']?.toString() ??
              'Please wait before trying again. No verification request was consumed.';
        } else {
          _syncMessage = result['error']?.toString() ??
              'Verification is still pending. Check the Bio and retry after the delay.';
        }
      });

      showMessage(
        context,
        verified
            ? 'Free Fire ownership verified. You may change your Bio back.'
            : locked
                ? 'Verification limit reached. Contact KOMNIVO Support.'
                : result['error']?.toString() ?? 'Verification Pending.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _syncMessage = error.toString());
      showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isVerified =>
      _verification?['status'] == 'verified' ||
      _verification?['ownership_status'] == 'verified';

  int get _attemptsRemaining {
    final value = _verification?['attempts_remaining'];
    return value is num ? value.toInt() : 3;
  }

  bool get _isLocked =>
      _verification?['status'] == 'locked' || _attemptsRemaining <= 0;

  bool get _hasVisibleActiveCode {
    if (_challengeCode == null || _challengeCode!.isEmpty) return false;
    if (_challengeExpiresAt == null) return true;
    return _challengeExpiresAt!.isAfter(DateTime.now());
  }

  Widget _verificationCard() {
    final verification = _verification;
    if (verification == null) return const SizedBox.shrink();

    final status = verification['status']?.toString() ??
        verification['ownership_status']?.toString() ??
        'not_linked';
    final verified = status == 'verified' ||
        verification['ownership_status'] == 'verified';
    final locked = status == 'locked' || _isLocked;
    final expired = status == 'expired' ||
        verification['challenge_status'] == 'expired';
    final remaining = _attemptsRemaining;

    final accent = verified
        ? const Color(0xFF58D6A1)
        : locked || expired
            ? const Color(0xFFFFC66D)
            : KomnivoTheme.cyan;

    final title = verified
        ? 'Free Fire Ownership Verified'
        : locked
            ? 'Verification Attempts Used'
            : 'Ownership Verification Pending';

    final message = verified
        ? 'KOMNIVO confirmed the exact code in the complete Bio returned for this UID. You may now restore or edit your previous Bio.'
        : locked
            ? 'You have used all three Free Fire verification requests for this UID. Contact KOMNIVO Support for further verification. Generating another code will not reset the limit.'
            : expired
                ? 'This code expired after 30 minutes. Generate a new code; your verification-attempt count will remain unchanged.'
                : 'The code is ready. Replace the complete in-game Bio with only this code, tick the confirmation checkbox and tap Verify. UID profile lookup and Bio matching happen together in one provider request.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: .55)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            verified ? Icons.verified_user : Icons.hourglass_top_rounded,
            color: accent,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: accent,
                fontSize: 16,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
          message,
          style: const TextStyle(color: Colors.white, height: 1.45, fontSize: 13),
        ),
        if (!verified) ...[
          const SizedBox(height: 9),
          Text(
            'Verification requests remaining: ' + remaining.toString() + ' of 3.',
            style: const TextStyle(
              color: KomnivoTheme.muted,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ]),
    );
  }

  Widget _challengePanel() {
    final code = _challengeCode;
    if (code == null || code.isEmpty || _isVerified || _isLocked) {
      return const SizedBox.shrink();
    }

    final expires = _challengeExpiresAt;
    final expiryLabel = expires == null
        ? 'One-time code'
        : 'Expires at ' + TimeOfDay.fromDateTime(expires).format(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .65)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'Your verification code',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
        ),
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
                  fontSize: 14,
                  letterSpacing: .6,
                ),
              ),
            ),
            IconButton(
              onPressed: _loading ? null : _copyChallenge,
              icon: const Icon(Icons.copy_rounded),
              tooltip: 'Copy exact code',
            ),
          ]),
        ),
        const SizedBox(height: 7),
        Text(
          expiryLabel,
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11),
        ),
        const SizedBox(height: 14),
        const Text(
          'Instructions — Free Fire India',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        const Text(
          '1. Copy the code above.\\n'
          '2. Open Free Fire India and edit your profile Bio.\\n'
          '3. Delete the entire existing Bio and paste only this exact code. Do not add your name, spaces, emojis or any other text before or after it.\\n'
          '4. Save the Bio in Free Fire and return to KOMNIVO.\\n'
          '5. Tick the checkbox below and tap Verify Bio.',
          style: TextStyle(
            color: KomnivoTheme.muted,
            fontSize: 12,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 10),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _bioConfirmed,
          onChanged: _loading || widget.preview
              ? null
              : (value) => setState(() => _bioConfirmed = value ?? false),
          title: const Text(
            'I have replaced my complete Free Fire Bio with only this exact code.',
            style: TextStyle(fontSize: 12, height: 1.35),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: widget.preview || _loading || !_bioConfirmed
                ? null
                : _verifyBio,
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.verified_outlined),
            label: Text(_loading ? 'Verifying Bio…' : 'Verify Bio'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Each verification attempt makes exactly one Free Fire /info request. After successful verification, you can immediately restore your old Bio.',
          style: TextStyle(
            color: KomnivoTheme.cyan,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ]),
    );
  }

  Widget _gameProfileCard() {
    final profile = _gameProfile;
    if (profile == null) return const SizedBox.shrink();

    final nickname = profile['nickname']?.toString();
    if (nickname == null || nickname.isEmpty) return const SizedBox.shrink();

    final lines = <String>[];
    if (profile['level'] != null) {
      lines.add('Level ' + profile['level'].toString());
    }
    if (profile['rank'] != null) {
      lines.add('Rank ' + profile['rank'].toString());
    }
    if (profile['likes'] != null) {
      lines.add('Likes ' + profile['likes'].toString());
    }
    if (profile['region'] != null) {
      lines.add(profile['region'].toString());
    }
    if (profile['clan_name'] != null) {
      lines.add('Clan ' + profile['clan_name'].toString());
    }

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
          'Fetched Free Fire profile',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          nickname,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            lines.join(' · '),
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12),
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
    final sameUid = _uid.text.trim() == _verification?['uid']?.toString();
    final canGenerate = !widget.preview &&
        !_loading &&
        !_isLocked &&
        !_isVerified &&
        (!_hasVisibleActiveCode || !sameUid);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
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
              Expanded(
                child: Text(
                  'Your KOMNIVO identity',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                ),
              ),
            ]),
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _bio,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Bio'),
            ),
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
            const Text(
              'Free Fire account · India region',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
            ),
            const SizedBox(height: 6),
            const Text(
              'Enter your UID. KOMNIVO generates the challenge code without calling the Free Fire API. The profile lookup and Bio ownership check happen together only when you tap Verify Bio.',
              style: TextStyle(
                color: KomnivoTheme.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _uid,
              keyboardType: TextInputType.number,
              maxLength: 15,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Free Fire UID',
                hintText: '5–15 digits',
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.info_outline, size: 16, color: KomnivoTheme.cyan),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _syncMessage,
                  style: const TextStyle(
                    color: KomnivoTheme.muted,
                    fontSize: 12,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: canGenerate ? _generateCode : null,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.key_outlined),
                label: Text(
                  _loading
                      ? 'Please wait…'
                      : _verification == null || _verification?['status'] == 'not_linked'
                          ? 'Generate verification code'
                          : 'Generate / replace code',
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Never share your game password or OTP. Your Bio must contain only the exact KOMNIVO code.',
              style: TextStyle(
                color: KomnivoTheme.muted,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        _challengePanel(),
        _gameProfileCard(),
        _verificationCard(),
        const SizedBox(height: 16),
        if (!widget.preview)
          OutlinedButton.icon(
            onPressed: () async => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
      ],
    );
  }
}
