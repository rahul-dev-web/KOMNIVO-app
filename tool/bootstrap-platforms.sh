#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
test -f pubspec.yaml || { echo "Run from the KOMNIVO repository."; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
flutter create --project-name app --org in.komnivo --platforms android,web "$TMP/platforms"
cp -R "$TMP/platforms/android" "$ROOT/android"
cp -R "$TMP/platforms/web" "$ROOT/web"
cp "$ROOT/native/android/app/src/main/AndroidManifest.xml" "$ROOT/android/app/src/main/AndroidManifest.xml"
mkdir -p "$ROOT/android/app/src/main/kotlin/in/komnivo/app"
cp "$ROOT"/native/android/app/src/main/kotlin/in/komnivo/app/*.kt "$ROOT/android/app/src/main/kotlin/in/komnivo/app/"
python3 - <<'PY'
from pathlib import Path
import re
p = Path("android/app/build.gradle.kts")
s = p.read_text()
android_plugin = '    id("com.android.application")'
kotlin_plugin = '    id("org.jetbrains.kotlin.android")'
if kotlin_plugin not in s:
    if android_plugin not in s:
        raise SystemExit("Could not find the Android application plugin in build.gradle.kts")
    s = s.replace(android_plugin, android_plugin + chr(10) + kotlin_plugin, 1)
s = re.sub(r'namespace\s*=\s*".*?"', 'namespace = "in.komnivo.app"', s)
s = re.sub(r'applicationId\s*=\s*".*?"', 'applicationId = "in.komnivo.app"', s)
if "com.google.mlkit:text-recognition" not in s:
    s += '\n\ndependencies {\n    implementation("com.google.mlkit:text-recognition:16.0.1")\n}\n'
p.write_text(s)
PY
cp "$ROOT/native/web/index.html" "$ROOT/web/index.html"

# Copy public product and legal pages into Flutter's generated Web output.
mkdir -p "$ROOT/web/brand" "$ROOT/web/about" "$ROOT/web/privacy" "$ROOT/web/terms"
cp "$ROOT/native/web/brand/komnivo-mark.svg" "$ROOT/web/brand/komnivo-mark.svg"
for page in about privacy terms; do
  cp "$ROOT/native/web/$page/index.html" "$ROOT/web/$page/index.html"
done

echo "Android, Web app, public homepage and policy pages are ready."
