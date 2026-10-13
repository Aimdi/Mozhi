#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: installs the Flutter SDK,
# Very Good CLI and all pub dependencies so analyze/tests work immediately.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

FLUTTER_VERSION="3.47.7"
FLUTTER_ROOT_DIR="/opt/flutter-sdk"
FLUTTER_BIN="$FLUTTER_ROOT_DIR/flutter/bin"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

installed_version() {
  "$FLUTTER_BIN/flutter" --version --machine 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])' 2>/dev/null || true
}

# 1. Flutter SDK (github.com is blocked by the egress proxy, so use the
#    release tarball from storage.googleapis.com).
if [ "$(installed_version)" != "$FLUTTER_VERSION" ]; then
  echo "Installing Flutter $FLUTTER_VERSION..." >&2
  rm -rf "$FLUTTER_ROOT_DIR/flutter"
  mkdir -p "$FLUTTER_ROOT_DIR"
  curl -sSL --retry 4 -o /tmp/flutter.tar.xz \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar xf /tmp/flutter.tar.xz -C "$FLUTTER_ROOT_DIR"
  rm -f /tmp/flutter.tar.xz
fi
git config --global --add safe.directory '*' || true
ln -sf "$FLUTTER_BIN/flutter" /usr/local/bin/flutter
ln -sf "$FLUTTER_BIN/dart" /usr/local/bin/dart
flutter config --no-analytics --enable-web >/dev/null 2>&1 || true
dart --disable-analytics >/dev/null 2>&1 || true
flutter precache --web >/dev/null 2>&1 || true

# 2. Very Good CLI (required by the VGV plugin hooks / MCP server).
if ! command -v very_good >/dev/null 2>&1; then
  dart pub global activate very_good_cli >/dev/null
  ln -sf "$HOME/.pub-cache/bin/very_good" /usr/local/bin/very_good
fi

# 3. Dependencies.
cd "$PROJECT_DIR"
for pkg in packages/*/; do
  (cd "$pkg" && dart pub get >/dev/null)
done
flutter pub get >/dev/null 2>&1
flutter gen-l10n >/dev/null 2>&1 || true

echo "Flutter $(installed_version), very_good $(very_good --version 2>/dev/null | head -1) ready." >&2
