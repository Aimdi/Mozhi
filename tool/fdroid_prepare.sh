#!/bin/sh
# Turns a Mozhi checkout into the F-Droid variant: the same app without
# Google ML Kit (closed source). Run it from anywhere, on a checkout you
# build from (CI job "Build F-Droid variant", the F-Droid recipe's prebuild);
# it edits the working tree in place and is not meant to be committed.
#
#   tool/fdroid_prepare.sh [repo-root]   # default: the directory above tool/
#
# What it does (see docs/contributing.md, "F-Droid variant"):
#  1. pubspec.yaml: removes google_mlkit_text_recognition and the
#     mlkit_translator path dependency (Flutter registers every plugin in
#     pubspec.yaml, so the ML Kit plugins must not be there at all).
#  2. lib/platform/mlkit_bindings.dart: replaced by mlkit_bindings_stub.dart
#     (no offline engine, no on-device text recognition; the UI hides them
#     and says why).
#  3. Deletes the files that import ML Kit: the text recognition service,
#     packages/mlkit_translator and their tests.
#  4. android/app/build.gradle.kts: deletes the "BEGIN mlkit" block (the
#     com.google.mlkit:text-recognition-* script models) and sets
#     noMlkit=true in android/gradle.properties, which also excludes any
#     com.google.mlkit artifact from every configuration.
#  5. Checks that nothing in pubspec.yaml, lib/, test/, packages/ or the
#     Gradle build still refers to ML Kit.
#
# Idempotent: on an already prepared tree it only re-runs the checks. It
# fails loudly (exit 1) when an expected pattern is missing, i.e. when the
# files changed and this script needs updating.
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

command -v python3 >/dev/null 2>&1 || die "python3 is required"

pubspec=pubspec.yaml
bindings=lib/platform/mlkit_bindings.dart
stub=lib/platform/mlkit_bindings_stub.dart
gradle=android/app/build.gradle.kts
gradle_properties=android/gradle.properties

# Files and directories that only exist to reach ML Kit.
mlkit_paths="
lib/image_translate/data/mlkit_text_recognition_service.dart
test/image_translate/data/mlkit_text_recognition_service_test.dart
test/platform/mlkit_bindings_test.dart
packages/mlkit_translator
"

[ -f "$stub" ] || die "$stub is missing"
[ -f "$gradle" ] || die "$gradle is missing"

prepared=false
if [ -f "$bindings" ] && cmp -s "$stub" "$bindings"; then
  prepared=true
  log "already prepared; checking only"
fi

if [ "$prepared" = false ]; then
  # 1. pubspec.yaml (python3 for a safe multi-line edit on any platform).
  python3 - "$pubspec" <<'PY' || die "could not edit pubspec.yaml"
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()

patterns = [
    # google_mlkit_text_recognition: ^0.17.1
    r"^  google_mlkit_text_recognition:[^\n]*\n",
    # mlkit_translator:\n    path: packages/mlkit_translator
    r"^  mlkit_translator:[ \t]*\n    path: packages/mlkit_translator[ \t]*\n",
]
for pattern in patterns:
    text, count = re.subn(pattern, "", text, flags=re.M)
    if count != 1:
        sys.exit(f"pubspec.yaml: expected one match for {pattern!r}, found {count}")

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
  log "removed the ML Kit dependencies from $pubspec"

  # 2. Bindings.
  [ -f "$bindings" ] || die "$bindings is missing"
  grep -q 'const bool mlKitIncluded = true;' "$bindings" ||
    die "$bindings does not look like the ML Kit bindings"
  cp -- "$stub" "$bindings"
  log "replaced $bindings with the stub"

  # 3. ML Kit-only files.
  for path in $mlkit_paths; do
    [ -e "$path" ] || die "$path is missing (update mlkit_paths in $0)"
    rm -rf -- "$path"
    log "deleted $path"
  done

  # 4. Gradle: drop the marked block, set the property.
  begin_count=$(grep -c '^// BEGIN mlkit' "$gradle" || true)
  end_count=$(grep -c '^// END mlkit' "$gradle" || true)
  [ "$begin_count" = 1 ] && [ "$end_count" = 1 ] ||
    die "$gradle: expected one '// BEGIN mlkit' and one '// END mlkit' line"
  sed '/^\/\/ BEGIN mlkit/,/^\/\/ END mlkit/d' "$gradle" >"$gradle.fdroid.tmp"
  mv -- "$gradle.fdroid.tmp" "$gradle"
  log "removed the ML Kit block from $gradle"
fi

if ! grep -q '^noMlkit=true$' "$gradle_properties" 2>/dev/null; then
  # A trailing newline first, in case the file does not end with one.
  if [ -s "$gradle_properties" ] && [ "$(tail -c 1 "$gradle_properties")" != "" ]; then
    echo >>"$gradle_properties"
  fi
  echo 'noMlkit=true' >>"$gradle_properties"
  log "set noMlkit=true in $gradle_properties"
fi

# 5. Checks.
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

check_none "ML Kit dependency left in $pubspec" \
  -nE '^[[:space:]]+(google_mlkit_[a-z_]+|mlkit_translator):' "$pubspec"
check_none "ML Kit import left in Dart code" \
  -rnE --include='*.dart' \
  "^import 'package:(google_mlkit_[a-z_]+|mlkit_translator)/" lib test packages
check_none "ML Kit artifact left in the Gradle build" \
  -nE '"com\.google\.mlkit:' "$gradle"
grep -q 'exclude(group = "com.google.mlkit")' "$gradle" || {
  echo "fdroid_prepare: error: $gradle no longer excludes com.google.mlkit" >&2
  failed=true
}
for path in $mlkit_paths; do
  if [ -e "$path" ]; then
    echo "fdroid_prepare: error: $path still exists" >&2
    failed=true
  fi
done
cmp -s "$stub" "$bindings" || {
  echo "fdroid_prepare: error: $bindings is not the stub" >&2
  failed=true
}

[ "$failed" = false ] || die "the tree still contains ML Kit"
log "done: build with flutter pub get && flutter build apk ..."
