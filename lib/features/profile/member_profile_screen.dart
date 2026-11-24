import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';

class MemberProfileScreen extends StatefulWidget {
  const MemberProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  State<MemberProfileScreen> createState() => _MemberProfileScreenState();
}

class _MemberProfileScreenState extends State<MemberProfileScreen> {
  late Future<Map<String, dynamic>?> _profile;

  @override
  void initState() {
    super.initState();
    _profile = _load();
  }

  Future<Map<String, dynamic>?> _load() async {
    final row = await Supabase.instance.client
        .from('profiles')
        .select('id,display_name,username,avatar_url,bio,region,is_public')
        .eq('id', widget.userId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return 'K';
    return parts.take(2).map((e) => e.substring(0, 1).toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Member profile'),
        backgroundColor: KomnivoTheme.background,
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profile,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final profile = snapshot.data;
          if (snapshot.hasError || profile == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_person_outlined, size: 42, color: KomnivoTheme.muted),
                    const SizedBox(height: 12),
                    const Text('Profile not available', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                    const SizedBox(height: 5),
                    const Text('This member keeps their profile private or it is unavailable.', textAlign: TextAlign.center, style: TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
                  ],
                ),
              ),
            );
          }
          final name = (profile['display_name']?.toString().trim().isNotEmpty == true)
              ? profile['display_name'].toString()
              : (profile['username']?.toString().trim().isNotEmpty == true
                  ? profile['username'].toString()
                  : 'KOMNIVO member');
          final username = profile['username']?.toString() ?? '';
          final avatar = profile['avatar_url']?.toString() ?? '';
          final bio = profile['bio']?.toString() ?? '';
          final region = profile['region']?.toString() ?? '';
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [KomnivoTheme.surfaceRaised, KomnivoTheme.surface],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: KomnivoTheme.line),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: KomnivoTheme.cyan.withValues(alpha: .75), width: 2),
                      ),
                      child: CircleAvatar(
                        radius: 42,
                        backgroundColor: KomnivoTheme.surface,
                        backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
                        onBackgroundImageError: (_, __) {},
                        child: avatar.isEmpty
                            ? Text(_initials(name), style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900))
                            : null,
                      ),
                    ),
                    const SizedBox(height: 13),
                    Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
                    if (username.isNotEmpty)
                      Text('@$username', style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 12, fontWeight: FontWeight.w700)),
                    if (region.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.location_on_outlined, size: 14, color: KomnivoTheme.muted),
                        const SizedBox(width: 4),
                        Text(region, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                      ]),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: KomnivoTheme.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: KomnivoTheme.line),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('ABOUT', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
                  const SizedBox(height: 8),
                  Text(bio.trim().isEmpty ? 'No bio added yet.' : bio, style: TextStyle(color: bio.trim().isEmpty ? KomnivoTheme.muted : null, height: 1.45, fontSize: 13)),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}
