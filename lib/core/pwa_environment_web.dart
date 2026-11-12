import 'dart:html' as html;

bool get isIosDevice {
  final userAgent = html.window.navigator.userAgent.toLowerCase();
  final platform = (html.window.navigator.platform ?? '').toLowerCase();
  final maxTouchPoints = html.window.navigator.maxTouchPoints ?? 0;
  final isTouchMac = platform.contains('mac') && maxTouchPoints > 1;

  return userAgent.contains('iphone') ||
      userAgent.contains('ipad') ||
      userAgent.contains('ipod') ||
      isTouchMac;
}

bool get isStandalone {
  final displayModeStandalone =
      html.window.matchMedia('(display-mode: standalone)').matches;
  final iosStandalone =
      (html.window.navigator as dynamic).standalone == true;

  return displayModeStandalone || iosStandalone;
}
