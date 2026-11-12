import 'pwa_environment_stub.dart'
    if (dart.library.html) 'pwa_environment_web.dart' as implementation;

/// Browser environment information used only for install-aware web features.
class PwaEnvironment {
  static bool get isIosDevice => implementation.isIosDevice;
  static bool get isStandalone => implementation.isStandalone;
}
