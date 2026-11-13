import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/startup_coordinator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Render the first Flutter frame immediately. Startup services are initialized
  // only after that frame, while the native/HTML and animated Flutter splashes
  // are already visible.
  runApp(const KomnivoApp());

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(StartupCoordinator.initialize());
  });
}
