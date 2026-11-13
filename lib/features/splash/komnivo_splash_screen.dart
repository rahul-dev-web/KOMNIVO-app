import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/boot_splash.dart' as boot_splash;
import '../../core/komnivo_logo.dart';
import '../../core/komnivo_theme.dart';
import '../../core/startup_coordinator.dart';

class KomnivoSplashScreen extends StatefulWidget {
  const KomnivoSplashScreen({super.key, required this.destination});

  final Widget destination;

  @override
  State<KomnivoSplashScreen> createState() => _KomnivoSplashScreenState();
}

class _KomnivoSplashScreenState extends State<KomnivoSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _animationFinished = false;
  bool _navigationScheduled = false;

  @override
  void initState() {
    super.initState();
    StartupCoordinator.ready.addListener(_onStartupChanged);
    StartupCoordinator.error.addListener(_onStartupChanged);

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2700),
    )..addStatusListener(_onAnimationStatus);
    _controller.forward();

    // The HTML splash stays visible until this first Flutter frame is painted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      boot_splash.hideBootSplash();
    });
  }

  void _onStartupChanged() {
    _tryNavigate();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _animationFinished = true;

    // Start Supabase/Firebase only after the full intro has been painted.
    // The splash remains on-screen as the services initialize.
    unawaited(StartupCoordinator.initialize());
    _tryNavigate();
  }

  void _tryNavigate() {
    if (!_animationFinished ||
        !StartupCoordinator.ready.value ||
        _navigationScheduled) {
      return;
    }

    _navigationScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => widget.destination),
      );
    });
  }

  @override
  void dispose() {
    StartupCoordinator.ready.removeListener(_onStartupChanged);
    StartupCoordinator.error.removeListener(_onStartupChanged);
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
                    const SizedBox(height: 24),
                    ValueListenableBuilder<String?>(
                      valueListenable: StartupCoordinator.error,
                      builder: (context, message, _) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: StartupCoordinator.ready,
                          builder: (context, isReady, _) {
                            if (progress < 1.0 || isReady || message != null) {
                              return const SizedBox.shrink();
                            }
                            return Column(
                              children: [
                                SizedBox(
                                  width: 52,
                                  height: 3,
                                  child: LinearProgressIndicator(
                                    minHeight: 3,
                                    backgroundColor: Color(0xFF273449),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      KomnivoTheme.cyan,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'CONNECTING SERVICES',
                                  style: TextStyle(
                                    color: KomnivoTheme.muted,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 2.2,
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                    ValueListenableBuilder<String?>(
                      valueListenable: StartupCoordinator.error,
                      builder: (context, message, _) {
                        if (message == null) return const SizedBox.shrink();
                        return Column(
                          children: [
                            Text(
                              message,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: KomnivoTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: StartupCoordinator.initialize,
                              child: const Text('Retry'),
                            ),
                          ],
                        );
                      },
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
