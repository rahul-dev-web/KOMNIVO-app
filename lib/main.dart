import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Paint the branded Flutter splash before starting any platform-backed
  // services. StartupCoordinator is started by the splash after its intro
  // animation completes, so native plugin initialization cannot skip the
  // logo/wordmark animation on slower Android devices.
  runApp(const KomnivoApp());
}
