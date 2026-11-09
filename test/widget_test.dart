import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';

void main() {
  test('KOMNIVO theme uses a dark visual system', () {
    expect(KomnivoTheme.dark.brightness, Brightness.dark);
    expect(KomnivoTheme.background, isNotNull);
  });
}
