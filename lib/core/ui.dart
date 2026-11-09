import 'package:flutter/material.dart';
import 'komnivo_theme.dart';

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: const TextStyle(color: KomnivoTheme.muted)),
        ],
      ])),
      if (trailing != null) trailing!,
    ],
  );
}

class MetricCard extends StatelessWidget {
  const MetricCard({super.key, required this.label, required this.value, required this.icon, this.tint});
  final String label;
  final String value;
  final IconData icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? KomnivoTheme.accent;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 14),
        Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.message, this.icon = Icons.sports_esports_outlined});
  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Column(children: [
      Icon(icon, size: 34, color: KomnivoTheme.muted),
      const SizedBox(height: 12),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
      const SizedBox(height: 6),
      Text(message, textAlign: TextAlign.center, style: const TextStyle(color: KomnivoTheme.muted)),
    ]),
  );
}

class PreviewBanner extends StatelessWidget {
  const PreviewBanner({super.key});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF2B2149),
      border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .5)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Row(children: [
      Icon(Icons.visibility_outlined, color: KomnivoTheme.accent),
      SizedBox(width: 10),
      Expanded(child: Text('Preview mode — connect the Supabase project to enable real accounts, chat and data sync.', style: TextStyle(fontSize: 12))),
    ]),
  );
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
