import 'dart:html' as html;

/// Best-effort platform detection. Never allow browser feature detection to
/// break Flutter route rendering on Safari or an installed iOS web app.
bool get isIosDevice {
  try {
    final navigator = html.window.navigator;
    final userAgent = navigator.userAgent.toLowerCase();
    final platform = (navigator.platform ?? '').toLowerCase();
    final maxTouchPoints = navigator.maxTouchPoints ?? 0;
    final isTouchMac = platform.contains('mac') && maxTouchPoints > 1;

    return userAgent.contains('iphone') ||
        userAgent.contains('ipad') ||
        userAgent.contains('ipod') ||
        isTouchMac;
  } catch (_) {
    return false;
  }
}

/// iOS exposes navigator.standalone for Home Screen web apps. Some WebKit
/// versions omit one of these APIs, so each check is guarded independently.
bool get isStandalone {
  var displayModeStandalone = false;
  var iosStandalone = false;

  try {
    displayModeStandalone =
        html.window.matchMedia('(display-mode: standalone)').matches;
  } catch (_) {
    // Continue with the iOS-specific property check.
  }

  try {
    final dynamic navigator = html.window.navigator;
    iosStandalone = navigator.standalone == true;
  } catch (_) {
    // Safari may not expose the legacy standalone property.
  }

  return displayModeStandalone || iosStandalone;
}
