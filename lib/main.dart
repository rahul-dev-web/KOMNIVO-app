import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/startup_coordinator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Paint the branded Flutter splash immediately. Web keeps its existing
  // parallel startup path; native platforms start services after the intro
  // animation so plugin initialization cannot block the first animation.
  runApp(const KomnivoApp());

  if (kIsWeb) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(StartupCoordinator.initialize());
    });
  }
}
