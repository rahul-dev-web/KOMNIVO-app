import 'dart:js_interop';

@JS('komnivoHideBootSplash')
external void _hideKomnivoBootSplash();

void hideBootSplash() {
  _hideKomnivoBootSplash();
}
