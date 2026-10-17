#!/bin/sh
# Prepares a Mozhi checkout for F-Droid's build server. The default build
# already is the F-Droid variant: it has no Google code (no ML Kit, Play
# services or Firebase) and translates offline with Mozilla's Bergamot
# engine. So this script changes nothing about the app; it only removes the
# sources that exist for the Play variant, so that F-Droid's scanner finds
# no reference to ML Kit in the tree, and checks the build is Google-free.
# Run it from anywhere (the F-Droid recipe's prebuild); it edits the working
# tree in place and is not meant to be committed.
#
#   tool/fdroid_prepare.sh [repo-root]   # default: the directory above tool/
#
# What it does (see docs/contributing.md, "Build variants"):
#  1. Refuses a checkout that tool/play_prepare.sh turned into the Play
#     variant (ML Kit in pubspec.yaml or the bindings).
#  2. Deletes the Play-only and unused ML Kit sources: tool/play/ (the Play
#     overlay), tool/play_prepare.sh and packages/mlkit_translator (ML Kit
#     translation, which no variant uses).
#  3. Checks that nothing in pubspec.yaml, lib/, test/, packages/ or the
#     Gradle build refers to ML Kit and that the Gradle build still excludes
#     com.google.mlkit, com.google.android.gms, com.google.firebase and
#     com.google.android.datatransport.
#
# It does not fetch the on-device engines' native sources: run
# tool/fetch_native_deps.sh first (the recipe checks out with
# `submodules: false`; see docs/store/README.md).
#
# Idempotent: a second run only checks. It fails loudly (exit 1) when an
# expected pattern is missing, i.e. when the files changed and this script
# needs updating.
#
# Afterwards: flutter pub get && flutter build apk --release
#   --flavor production -t lib/main_production.dart
set -eu

die() {
  echo "fdroid_prepare: error: $*" >&2
  exit 1
}

log() {
  echo "fdroid_prepare: $*"
}

if [ "$#" -gt 1 ]; then
  die "usage: $0 [repo-root]"
fi
if [ "$#" -eq 1 ]; then
  root=$1
else
  root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fi
cd -- "$root" || die "cannot enter $root"
[ -f pubspec.yaml ] || die "no pubspec.yaml in $root"
grep -q '^name: mozhi$' pubspec.yaml || die "$root is not the Mozhi app"

pubspec=pubspec.yaml
bindings=lib/platform/mlkit_bindings.dart
gradle=android/app/build.gradle.kts

# Sources that only exist for the Play variant or reach ML Kit.
play_paths="
tool/play
tool/play_prepare.sh
packages/mlkit_translator
"

[ -f "$bindings" ] || die "$bindings is missing"
[ -f "$gradle" ] || die "$gradle is missing"

# 1. Not the Play variant.
if grep -qE '^[[:space:]]+google_mlkit_[a-z_]+:' "$pubspec" ||
  grep -q 'const bool mlKitIncluded = true;' "$bindings"; then
  die "this checkout is the Play variant (tool/play_prepare.sh ran): start from a clean checkout"
fi
grep -q 'const bool mlKitIncluded = false;' "$bindings" ||
  die "$bindings does not look like the default bindings"

# 2. Play-only sources.
for path in $play_paths; do
  if [ -e "$path" ]; then
    rm -rf -- "$path"
    log "deleted $path"
  fi
done

# 3. Checks.
failed=false
check_none() {
  # $1: description, rest: grep arguments. Fails when grep finds anything.
  description=$1
  shift
  if found=$(grep "$@" 2>/dev/null); then
    echo "fdroid_prepare: error: $description:" >&2
    echo "$found" >&2
    failed=true
  fi
}

check_none "ML Kit dependency left in a pubspec.yaml" \
  -nE '^[[:space:]]+(google_mlkit_[a-z_]+|mlkit_translator):' \
  "$pubspec" packages/*/pubspec.yaml
check_none "ML Kit import left in Dart code" \
  -rnE --include='*.dart' \
  "^import 'package:(google_mlkit_[a-z_]+|mlkit_translator)/" lib test packages
check_none "ML Kit artifact left in the Gradle build" \
  -nE '"com\.google\.mlkit:' "$gradle"
for group in com.google.mlkit com.google.android.gms com.google.firebase \
  com.google.android.datatransport; do
  grep -qF "exclude(group = \"$group\")" "$gradle" || {
    echo "fdroid_prepare: error: $gradle no longer excludes $group" >&2
    failed=true
  }
done
grep -q '^val noMlkit = .*?: true$' "$gradle" || {
  echo "fdroid_prepare: error: $gradle no longer excludes them by default" >&2
  failed=true
}
if grep -q '^noMlkit=false' android/gradle.properties 2>/dev/null; then
  echo "fdroid_prepare: error: android/gradle.properties sets noMlkit=false" >&2
  failed=true
fi
for path in $play_paths; do
  if [ -e "$path" ]; then
    echo "fdroid_prepare: error: $path still exists" >&2
    failed=true
  fi
done

[ "$failed" = false ] || die "the tree still contains ML Kit"
log "done: build with flutter pub get && flutter build apk ..."
