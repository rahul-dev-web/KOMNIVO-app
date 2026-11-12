import 'package:flutter/material.dart';

class KomnivoLogo extends StatelessWidget {
  const KomnivoLogo({
    super.key,
    this.size = 48,
    this.borderRadius = 12,
    this.fit = BoxFit.contain,
  });

  final double size;
  final double borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.asset(
        'assets/brand/komnivo-mark.png',
        width: size,
        height: size,
        fit: fit,
        semanticLabel: 'KOMNIVO',
      ),
    );
  }
}
