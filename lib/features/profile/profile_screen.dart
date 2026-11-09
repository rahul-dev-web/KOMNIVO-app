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

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _load();
  }

  Future<void> _load() async {
    try {
      final profile = await KomnivoRepository.instance.myProfile();
      _name.text = profile['display_name']?.toString() ?? '';
      _bio.text = profile['bio']?.toString() ?? '';
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
    } catch (error) { if (mounted) showMessage(context, error.toString()); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _syncUid() async {
    if (_uid.text.trim().length < 5) {
      showMessage(context, 'Enter a valid Free Fire UID (5–15 digits).');
      return;
    }
    setState(() { _loading = true; _syncMessage = 'Fetching game profile…'; });
    try {
      final result = await KomnivoRepository.instance.syncFreeFire(_uid.text.trim());
      final profile = (result['profile'] is Map) ? Map<String, dynamic>.from(result['profile'] as Map) : <String, dynamic>{};
      setState(() => _syncMessage = '${profile['nickname'] ?? profile['accountName'] ?? 'Profile synced'} · ownership not independently verified');
    } catch (error) {
      setState(() => _syncMessage = error.toString());
    } finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  void dispose() { _name.dispose(); _bio.dispose(); _uid.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      SectionTitle('Player profile', subtitle: 'Your platform identity and game identity', trailing: widget.onBack == null ? null : IconButton(onPressed: widget.onBack, icon: const Icon(Icons.close))),
      const SizedBox(height: 16),
      if (widget.preview) const PreviewBanner(),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [CircleAvatar(radius: 25, child: Icon(Icons.person_outline, size: 26)), SizedBox(width: 12), Expanded(child: Text('Your KOMNIVO identity', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)))]),
          const SizedBox(height: 18),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name')),
          const SizedBox(height: 12),
          TextField(controller: _bio, maxLines: 3, decoration: const InputDecoration(labelText: 'Bio')),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: widget.preview || _loading ? null : _save, child: const Text('Save profile'))),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Free Fire MAX profile', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 6),
          const Text('Enter your UID. KOMNIVO fetches supported profile data through the protected server-side provider.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 14),
          TextField(controller: _uid, keyboardType: TextInputType.number, maxLength: 15, decoration: const InputDecoration(labelText: 'Free Fire UID', hintText: '5–15 digits')),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.info_outline, size: 16, color: KomnivoTheme.cyan),
            const SizedBox(width: 7),
            Expanded(child: Text(_syncMessage, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12))),
          ]),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: widget.preview || _loading ? null : _syncUid, icon: const Icon(Icons.sync), label: const Text('Sync game profile · IND'))),
          const SizedBox(height: 8),
          const Text('UID lookup does not prove account ownership. The app will not ask for your game password.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
        ]),
      ),
      const SizedBox(height: 16),
      if (!widget.preview) OutlinedButton.icon(
        onPressed: () async => Supabase.instance.client.auth.signOut(),
        icon: const Icon(Icons.logout),
        label: const Text('Sign out'),
      ),
    ]);
  }
}
