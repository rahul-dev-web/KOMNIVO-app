import 'package:flutter/material.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.preview, required this.onLiveOps, required this.onOrganizer});
  final bool preview;
  final VoidCallback onLiveOps;
  final VoidCallback onOrganizer;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        if (preview) const PreviewBanner(),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF30255D), Color(0xFF172A43), Color(0xFF101827)],
            ),
            border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .35)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('THE NEXT MATCH STARTS HERE', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
            const SizedBox(height: 14),
            Text('Play together.\nCompete as one.', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, height: 1.05)),
            const SizedBox(height: 12),
            const Text('Your gaming communities, teams and tournaments — connected in one place.', style: TextStyle(color: Colors.white70, height: 1.45)),
            const SizedBox(height: 20),
            Wrap(spacing: 10, runSpacing: 10, children: [
              FilledButton.icon(onPressed: onOrganizer, icon: const Icon(Icons.dashboard_outlined), label: const Text('Organiser desk')),
              OutlinedButton.icon(onPressed: onLiveOps, icon: const Icon(Icons.radar), label: const Text('Open LiveOps')),
            ]),
          ]),
        ),
        const SizedBox(height: 26),
        const SectionTitle('Your competitive hub', subtitle: 'A quick view of your KOMNIVO activity'),
        const SizedBox(height: 14),
        const LayoutBuilder(
          builder: _MetricGridBuilder.build,
        ),
        const SizedBox(height: 28),
        const SectionTitle('One connected workflow', subtitle: 'From finding a squad to verified results'),
        const SizedBox(height: 14),
        const _WorkflowCard(icon: Icons.groups_2_outlined, title: 'Find your community', detail: 'Join communities, channels and voice rooms.'),
        const _WorkflowCard(icon: Icons.shield_outlined, title: 'Build your team', detail: 'Maintain rosters, invite players and recruit substitutes.'),
        const _WorkflowCard(icon: Icons.emoji_events_outlined, title: 'Compete with structure', detail: 'Register, check in, play matches and track standings.'),
        const _WorkflowCard(icon: Icons.radar_outlined, title: 'Run matches with LiveOps', detail: 'Use same-phone screen observation and voice guidance.'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
          child: const Row(children: [
            Icon(Icons.verified_user_outlined, color: KomnivoTheme.cyan),
            SizedBox(width: 12),
            Expanded(child: Text('Official tournament results always come from the verification workflow — OCR and AI are only evidence assistants.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.4))),
          ]),
        ),
      ],
    );
  }
}

class _MetricGridBuilder {
  static Widget build(BuildContext context, BoxConstraints constraints) {
    final count = constraints.maxWidth > 760 ? 4 : 2;
    return GridView.count(
      crossAxisCount: count,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: count == 4 ? 1.7 : 1.55,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      children: const [
        MetricCard(label: 'Communities', value: '—', icon: Icons.groups, tint: KomnivoTheme.cyan),
        MetricCard(label: 'Your teams', value: '—', icon: Icons.shield, tint: KomnivoTheme.accent),
        MetricCard(label: 'Upcoming events', value: '—', icon: Icons.emoji_events, tint: Color(0xFFFFC36B)),
        MetricCard(label: 'Verified matches', value: '—', icon: Icons.verified, tint: Color(0xFF72D6A1)),
      ],
    );
  }
}

class _WorkflowCard extends StatelessWidget {
  const _WorkflowCard({required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      Container(width: 40, height: 40, decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: KomnivoTheme.accent)),
      const SizedBox(width: 13),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(detail, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ])),
      const Icon(Icons.chevron_right, color: KomnivoTheme.muted),
    ]),
  );
}
