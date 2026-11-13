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
mkdir -p "$ROOT/android/app/src/main/res"

# flutter create ships stock Flutter launcher PNGs in density-specific mipmap
# folders. They outrank our density-independent KOMNIVO XML launcher resources.
for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  rm -f "$ROOT/android/app/src/main/res/mipmap-$density"/ic_launcher*
done

cp -R "$ROOT/native/android/app/src/main/res/." "$ROOT/android/app/src/main/res/"
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
cp "$ROOT/native/web/manifest.json" "$ROOT/web/manifest.json"

# Copy public product, policy and isolated Firebase Messaging worker files.
mkdir -p "$ROOT/web/brand" "$ROOT/web/icons" "$ROOT/web/about" "$ROOT/web/privacy" "$ROOT/web/terms" "$ROOT/web/firebase-cloud-messaging-push-scope"
cp "$ROOT/native/web/brand/komnivo-mark.svg" "$ROOT/web/brand/komnivo-mark.svg"
cp "$ROOT"/native/web/icons/*.png "$ROOT/web/icons/"
cp "$ROOT/native/web/firebase-cloud-messaging-push-scope/firebase-messaging-sw.js" "$ROOT/web/firebase-cloud-messaging-push-scope/firebase-messaging-sw.js"
for page in about privacy terms; do
  cp "$ROOT/native/web/$page/index.html" "$ROOT/web/$page/index.html"
done

# Firebase Web identifiers are public client configuration. Inject values from
# environment variables at build time; never place server credentials here.
python3 - <<'PY'
from pathlib import Path
import json
import os

worker = Path("web/firebase-cloud-messaging-push-scope/firebase-messaging-sw.js")
source = worker.read_text()
for name in (
    "FIREBASE_API_KEY",
    "FIREBASE_AUTH_DOMAIN",
    "FIREBASE_PROJECT_ID",
    "FIREBASE_STORAGE_BUCKET",
    "FIREBASE_MESSAGING_SENDER_ID",
    "FIREBASE_APP_ID",
):
    marker = f'"__{name}__"'
    source = source.replace(marker, json.dumps(os.environ.get(name, "")))
worker.write_text(source)
PY

echo "Android, Web app, public pages and isolated FCM worker are ready."
