#!/bin/sh
# Turns a Mozhi checkout into the Play variant: the default (Google-free)
# app plus Google ML Kit's on-device text recognition (closed source), so
# camera and image translation can read text on the device. Offline
# translation is Mozilla's Bergamot engine in both variants; the Play
# variant does not add ML Kit translation (see docs/contributing.md, "Build
# variants"). Run it on a checkout you build from (CI job "Build Play
# variant (ML Kit)"); it edits the working tree in place and is not meant to
# be committed.
#
#   tool/play_prepare.sh [repo-root]   # default: the directory above tool/
#
# What it does:
#  1. pubspec.yaml: adds google_mlkit_text_recognition (pinned; after
#     go_router).
#  2. Copies the overlay in tool/play/ into place: the ML Kit bindings over
#     lib/platform/mlkit_bindings.dart, the ML Kit text recognition service
#     to lib/image_translate/data/ and both tests to test/.
#  3. android/app/build.gradle.kts: appends the "BEGIN mlkit" block (ML
#     Kit's Chinese, Devanagari, Japanese and Korean script models) and
#     writes noMlkit=false to android/gradle.properties, which lifts the
#     default exclusion of com.google.mlkit, com.google.android.gms,
#     com.google.firebase and com.google.android.datatransport.
#  4. Checks the result.
#
# Idempotent: every step checks whether it is already done, so a second run
# only checks. It fails loudly (exit 1) when an expected pattern or file is
# missing, i.e. when the files changed and this script needs updating.
#
# Afterwards: flutter pub get && flutter build apk --release
#   --flavor production -t lib/main_production.dart
set -eu

die() {
  echo "play_prepare: error: $*" >&2
  exit 1
}

log() {
  echo "play_prepare: $*"
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
gradle=android/app/build.gradle.kts
gradle_properties=android/gradle.properties
overlay=tool/play
# Keep in sync with the plugin's com.google.mlkit:text-recognition
# dependency (16.0.1 in plugin 0.17.1) and mlkit_version below.
plugin_version=0.17.1
mlkit_version=16.0.1

# The overlay: tool/play/<path> is copied to <path>. replaced_paths
# overwrite a default file, which must still be the default one (see
# replace_default below); added_paths must not exist yet (or already be the
# overlay's copy).
replaced_paths="
lib/platform/mlkit_bindings.dart
test/platform/mlkit_bindings_test.dart
"
added_paths="
lib/image_translate/data/mlkit_text_recognition_service.dart
test/image_translate/data/mlkit_text_recognition_service_test.dart
"

[ -d "$overlay" ] || die "$overlay is missing (fdroid_prepare.sh removes it)"
[ -f "$gradle" ] || die "$gradle is missing"

# The overlay must hold exactly the files this script knows about.
expected=$(
  {
    for path in $replaced_paths; do echo "$path"; done
    for path in $added_paths; do echo "$path"; done
  } | sort
)
actual=$(cd "$overlay" && find . -type f | sed 's|^\./||' | sort)
[ "$expected" = "$actual" ] ||
  die "$overlay does not match the paths in $0:
expected:
$expected
found:
$actual"

# 1. pubspec.yaml (python3 for a safe multi-line edit on any platform).
python3 - "$pubspec" "$plugin_version" <<'PY' || die "could not edit pubspec.yaml"
import re
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    text = f.read()

line = f"  google_mlkit_text_recognition: {version}\n"
present = re.findall(r"^  google_mlkit_text_recognition:[^\n]*\n", text, flags=re.M)
if present == [line]:
    sys.exit(0)
if present:
    sys.exit(f"pubspec.yaml: unexpected google_mlkit_text_recognition entries {present!r}")
anchor = r"^  go_router:[^\n]*\n"
matches = re.findall(anchor, text, flags=re.M)
if len(matches) != 1:
    sys.exit(f"pubspec.yaml: expected one match for {anchor!r}, found {len(matches)}")
text = re.sub(anchor, lambda m: m.group(0) + line, text, count=1, flags=re.M)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"play_prepare: added google_mlkit_text_recognition {version} to {path}")
PY

# 2. The overlay.
replace_default() {
  # $1: path, $2: a line only the default version contains.
  if [ -f "$1" ] && cmp -s "$overlay/$1" "$1"; then
    return 0
  fi
  [ -f "$1" ] || die "$1 is missing"
  grep -qF -- "$2" "$1" ||
    die "$1 does not look like the default file (no '$2')"
  cp -- "$overlay/$1" "$1"
  log "replaced $1"
}
replace_default lib/platform/mlkit_bindings.dart \
  'const bool mlKitIncluded = false;'
replace_default test/platform/mlkit_bindings_test.dart \
  "group('default bindings (no ML Kit)'"
for path in $added_paths; do
  if [ -e "$path" ]; then
    cmp -s "$overlay/$path" "$path" ||
      die "$path exists and differs from $overlay/$path"
    continue
  fi
  mkdir -p -- "$(dirname -- "$path")"
  cp -- "$overlay/$path" "$path"
  log "added $path"
done

# 3. Gradle: the ML Kit block and the property.
grep -q '^val noMlkit = ' "$gradle" ||
  die "$gradle no longer defines noMlkit (update the block in $0)"
begin_count=$(grep -c '^// BEGIN mlkit' "$gradle" || true)
end_count=$(grep -c '^// END mlkit' "$gradle" || true)
if [ "$begin_count" = 0 ] && [ "$end_count" = 0 ]; then
  cat >>"$gradle" <<EOF

// BEGIN mlkit (tool/play_prepare.sh, Play variant only)
// On-device OCR for camera translate (lib/image_translate). The
// google_mlkit_text_recognition plugin bundles only the Latin model and
// declares the other scripts as compileOnly, so picking Chinese, Devanagari,
// Japanese or Korean would crash with NoClassDefFoundError unless the app
// ships them. These are ML Kit's bundled models (they work offline and need no
// Google Play services); each adds a few MB per ABI to the APK, about 4 MB
// per script according to ML Kit's documentation (check with
// \`flutter build apk --analyze-size\`). Split-per-ABI APKs and app bundles
// keep that to one ABI per device. Keep the version in sync with the plugin's
// com.google.mlkit:text-recognition dependency ($mlkit_version in plugin $plugin_version).
val mlkitTextRecognitionVersion = "$mlkit_version"

if (!noMlkit) {
    dependencies {
        implementation("com.google.mlkit:text-recognition-chinese:\$mlkitTextRecognitionVersion")
        implementation("com.google.mlkit:text-recognition-devanagari:\$mlkitTextRecognitionVersion")
        implementation("com.google.mlkit:text-recognition-japanese:\$mlkitTextRecognitionVersion")
        implementation("com.google.mlkit:text-recognition-korean:\$mlkitTextRecognitionVersion")
    }
}
// END mlkit
EOF
  log "added the ML Kit block to $gradle"
elif [ "$begin_count" != 1 ] || [ "$end_count" != 1 ]; then
  die "$gradle: expected no or one '// BEGIN mlkit' and '// END mlkit' line"
fi

if ! grep -q '^noMlkit=false$' "$gradle_properties" 2>/dev/null; then
  if [ -f "$gradle_properties" ]; then
    # Drop a stale value (e.g. noMlkit=true), keep everything else.
    grep -v '^noMlkit=' "$gradle_properties" >"$gradle_properties.play.tmp" || true
    mv -- "$gradle_properties.play.tmp" "$gradle_properties"
    # A trailing newline first, in case the file does not end with one.
    if [ -s "$gradle_properties" ] && [ "$(tail -c 1 "$gradle_properties")" != "" ]; then
      echo >>"$gradle_properties"
    fi
  fi
  echo 'noMlkit=false' >>"$gradle_properties"
  log "set noMlkit=false in $gradle_properties"
fi

# 4. Checks.
failed=false
fail() {
  echo "play_prepare: error: $*" >&2
  failed=true
}

[ "$(grep -c "^  google_mlkit_text_recognition: $plugin_version\$" "$pubspec")" = 1 ] ||
  fail "$pubspec does not depend on google_mlkit_text_recognition $plugin_version"
for path in $replaced_paths $added_paths; do
  cmp -s "$overlay/$path" "$path" || fail "$path is not the Play version"
done
grep -q "com.google.mlkit:text-recognition-chinese" "$gradle" ||
  fail "$gradle has no ML Kit script models"
grep -q '^noMlkit=false$' "$gradle_properties" ||
  fail "$gradle_properties does not set noMlkit=false"
# ML Kit stays behind the bindings: only the two overlay files import it.
if found=$(grep -rlE --include='*.dart' "^import 'package:google_mlkit_" lib |
  grep -vxF -e lib/platform/mlkit_bindings.dart \
    -e lib/image_translate/data/mlkit_text_recognition_service.dart); then
  fail "ML Kit imported outside the bindings: $found"
fi

[ "$failed" = false ] || die "the tree is not a complete Play variant"
log "done: build with flutter pub get && flutter build apk ..."
