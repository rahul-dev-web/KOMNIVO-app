import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/komnivo_logo.dart';
import '../../core/komnivo_theme.dart';

class KomnivoSplashScreen extends StatefulWidget {
  const KomnivoSplashScreen({super.key, required this.destination});

  final Widget destination;

  @override
  State<KomnivoSplashScreen> createState() => _KomnivoSplashScreenState();
}

class _KomnivoSplashScreenState extends State<KomnivoSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2700),
    )..addStatusListener(_onAnimationStatus);
    _controller.forward();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => widget.destination),
      );
    });
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_onAnimationStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KomnivoTheme.background,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final progress = _controller.value;
          final blinkProgress = (progress / .45).clamp(0.0, 1.0).toDouble();
          final logoOpacity = progress < .45
              ? .20 + (.80 * ((math.sin(blinkProgress * math.pi * 6) + 1) / 2))
              : 1.0;
          final typingProgress = Curves.easeOutCubic
              .transform(((progress - .45) / .42).clamp(0.0, 1.0).toDouble());
          final visibleLetters = (typingProgress * 7).floor().clamp(0, 7).toInt();
          const brandName = 'KOMNIVO';

          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -.15),
                radius: 1.05,
                colors: [
                  Color(0xFF18243C),
                  Color(0xFF0D1321),
                  KomnivoTheme.background,
                ],
                stops: [0, .58, 1],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: logoOpacity,
                      child: Transform.scale(
                        scale: .96 + (.04 * logoOpacity),
                        child: const KomnivoLogo(size: 152, borderRadius: 30),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 34,
                      child: Text(
                        brandName.substring(0, visibleLetters),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 7.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Opacity(
                      opacity: ((progress - .82) / .16).clamp(0.0, 1.0).toDouble(),
                      child: const Text(
                        'ESPORTS COMMUNITY OS',
                        style: TextStyle(
                          color: KomnivoTheme.cyan,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 3.0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
