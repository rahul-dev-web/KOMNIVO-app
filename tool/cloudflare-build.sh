#!/usr/bin/env bash
set -euo pipefail

# Cloudflare Pages build helper for the KOMNIVO Flutter Web app.
# Pin the SDK to the locally verified version so CI and local builds stay aligned.
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.8}"

case "$FLUTTER_VERSION" in
  3.44.8)
    FLUTTER_SHA256="672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d"
    ;;
  *)
    echo "Unsupported FLUTTER_VERSION: $FLUTTER_VERSION (update the pinned checksum before changing versions)." >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${SUPABASE_URL:?Set SUPABASE_URL in Cloudflare Pages environment variables}"
: "${SUPABASE_PUBLISHABLE_KEY:?Set SUPABASE_PUBLISHABLE_KEY in Cloudflare Pages environment variables}"

case "$SUPABASE_URL" in
  https://*) ;;
  *) echo "SUPABASE_URL must start with https://." >&2; exit 2 ;;
esac

case "$SUPABASE_PUBLISHABLE_KEY" in
  sb_publishable_*) ;;
  *) echo "SUPABASE_PUBLISHABLE_KEY must be the Supabase sb_publishable_ key, never service_role/secret." >&2; exit 2 ;;
esac

SDK_ROOT="${HOME}/.cache/komnivo-flutter"
FLUTTER_HOME="$SDK_ROOT/flutter-$FLUTTER_VERSION"
ARCHIVE="$SDK_ROOT/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

mkdir -p "$SDK_ROOT"

if [[ ! -x "$FLUTTER_HOME/bin/flutter" ]]; then
  echo "Installing pinned Flutter SDK $FLUTTER_VERSION..."
  rm -f "$ARCHIVE"
  curl --fail --location --retry 3 --retry-delay 2 \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    --output "$ARCHIVE"

  echo "$FLUTTER_SHA256  $ARCHIVE" | sha256sum --check -
  EXTRACT_DIR="$(mktemp -d "$SDK_ROOT/extract.XXXXXX")"
  trap 'rm -rf "$EXTRACT_DIR" "$ARCHIVE"' EXIT
  tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"
  mv "$EXTRACT_DIR/flutter" "$FLUTTER_HOME"
  rm -rf "$EXTRACT_DIR"
  rm -f "$ARCHIVE"
  trap - EXIT
fi

export PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_HOME" || true

flutter config --no-analytics
flutter --version

# Optional Firebase identifiers are public browser configuration, not secrets.
FIREBASE_API_KEY_VALUE="$(printenv FIREBASE_API_KEY || true)"
FIREBASE_APP_ID_VALUE="$(printenv FIREBASE_APP_ID || true)"
FIREBASE_AUTH_DOMAIN_VALUE="$(printenv FIREBASE_AUTH_DOMAIN || true)"
FIREBASE_MESSAGING_SENDER_ID_VALUE="$(printenv FIREBASE_MESSAGING_SENDER_ID || true)"
FIREBASE_PROJECT_ID_VALUE="$(printenv FIREBASE_PROJECT_ID || true)"
FIREBASE_STORAGE_BUCKET_VALUE="$(printenv FIREBASE_STORAGE_BUCKET || true)"
FIREBASE_VAPID_KEY_VALUE="$(printenv FIREBASE_VAPID_KEY || true)"

# Generate ignored Flutter scaffolding and overlay KOMNIVO's native Android
# module plus the isolated Firebase Messaging service worker.
bash tool/bootstrap-platforms.sh
flutter pub get

flutter build web --release \
  --dart-define="SUPABASE_URL=$SUPABASE_URL" \
  --dart-define="SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY" \
  --dart-define="FIREBASE_API_KEY=$FIREBASE_API_KEY_VALUE" \
  --dart-define="FIREBASE_APP_ID=$FIREBASE_APP_ID_VALUE" \
  --dart-define="FIREBASE_AUTH_DOMAIN=$FIREBASE_AUTH_DOMAIN_VALUE" \
  --dart-define="FIREBASE_MESSAGING_SENDER_ID=$FIREBASE_MESSAGING_SENDER_ID_VALUE" \
  --dart-define="FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID_VALUE" \
  --dart-define="FIREBASE_STORAGE_BUCKET=$FIREBASE_STORAGE_BUCKET_VALUE" \
  --dart-define="FIREBASE_VAPID_KEY=$FIREBASE_VAPID_KEY_VALUE"

test -f build/web/index.html || {
  echo "Flutter Web build completed without build/web/index.html." >&2
  exit 1
}

test -f build/web/firebase-cloud-messaging-push-scope/firebase-messaging-sw.js || {
  echo "Firebase Messaging service worker was not included in build/web." >&2
  exit 1
}

echo "KOMNIVO Web build ready in build/web."
