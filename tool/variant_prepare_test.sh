#!/bin/sh
# Tests for tool/play_prepare.sh and tool/fdroid_prepare.sh on scratch
# copies of the files they read and edit (pubspec.yaml, lib/, test/, the
# Gradle files, tool/play/, the packages' pubspec.yaml and lib/): both are
# idempotent, produce the expected tree and fail loudly (exit 1) when a
# pattern they rely on is missing. Needs python3 (like the scripts).
#
#   sh tool/variant_prepare_test.sh
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname -- "$here")
command -v python3 >/dev/null 2>&1 || {
  echo "variant_prepare_test: python3 is required" >&2
  exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/variant_prepare_test.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 2' HUP INT TERM

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok - $1"
}
fail() {
  failed=$((failed + 1))
  echo "not ok - $1" >&2
}

# A fresh copy of the relevant parts of the repository in $work/$1.
fresh() {
  dir="$work/$1"
  rm -rf "$dir"
  mkdir -p "$dir/android/app" "$dir/tool" "$dir/packages"
  cp "$repo/pubspec.yaml" "$dir/"
  cp -R "$repo/lib" "$repo/test" "$dir/"
  cp "$repo/android/app/build.gradle.kts" "$dir/android/app/"
  cp "$repo/android/gradle.properties" "$dir/android/"
  cp -R "$repo/tool/play" "$dir/tool/"
  cp "$repo/tool/play_prepare.sh" "$repo/tool/fdroid_prepare.sh" "$dir/tool/"
  for pubspec in "$repo"/packages/*/pubspec.yaml; do
    package=$(basename "$(dirname "$pubspec")")
    mkdir -p "$dir/packages/$package"
    cp "$pubspec" "$dir/packages/$package/"
    if [ -d "$repo/packages/$package/lib" ]; then
      cp -R "$repo/packages/$package/lib" "$dir/packages/$package/"
    fi
  done
  echo "$dir"
}

# A checksum of every file under $1 (names and contents).
snapshot() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$(cksum <"$file")" "$file"
  done)
}

# $1: description, $2: expected exit status, $3: text the output must
# contain (empty: anything), rest: the command.
expect_status() {
  description=$1
  want=$2
  needle=$3
  shift 3
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [ "$status" != "$want" ]; then
    fail "$description (exit $status, expected $want): $output"
  elif [ -n "$needle" ] && ! printf '%s' "$output" | grep -qF -- "$needle"; then
    fail "$description (output lacks '$needle'): $output"
  else
    pass "$description"
  fi
}

# --- play_prepare.sh -------------------------------------------------------

dir=$(fresh play)
expect_status "play: prepares the default tree" 0 "added the ML Kit block" \
  sh "$dir/tool/play_prepare.sh" "$dir"
if grep -q '^  google_mlkit_text_recognition: 0\.17\.1$' "$dir/pubspec.yaml" &&
  grep -A1 '^  go_router:' "$dir/pubspec.yaml" | grep -q google_mlkit_text_recognition; then
  pass "play: adds the pinned plugin after go_router"
else
  fail "play: adds the pinned plugin after go_router"
fi
if cmp -s "$dir/tool/play/lib/platform/mlkit_bindings.dart" \
  "$dir/lib/platform/mlkit_bindings.dart" &&
  [ -f "$dir/lib/image_translate/data/mlkit_text_recognition_service.dart" ] &&
  [ -f "$dir/test/image_translate/data/mlkit_text_recognition_service_test.dart" ] &&
  grep -q 'mlKitIncluded = true' "$dir/lib/platform/mlkit_bindings.dart"; then
  pass "play: copies the overlay"
else
  fail "play: copies the overlay"
fi
if grep -q '^// BEGIN mlkit' "$dir/android/app/build.gradle.kts" &&
  grep -q 'text-recognition-korean:\$mlkitTextRecognitionVersion' \
    "$dir/android/app/build.gradle.kts" &&
  grep -q '^val mlkitTextRecognitionVersion = "16.0.1"$' \
    "$dir/android/app/build.gradle.kts" &&
  [ "$(grep -c '^noMlkit=' "$dir/android/gradle.properties")" = 1 ] &&
  grep -q '^noMlkit=false$' "$dir/android/gradle.properties"; then
  pass "play: adds the Gradle block and noMlkit=false"
else
  fail "play: adds the Gradle block and noMlkit=false"
fi
before=$(snapshot "$dir")
expect_status "play: a second run only checks" 0 "done" \
  sh "$dir/tool/play_prepare.sh" "$dir"
if [ "$before" = "$(snapshot "$dir")" ] &&
  ! sh "$dir/tool/play_prepare.sh" "$dir" | grep -qE 'added|replaced|set '; then
  pass "play: is idempotent"
else
  fail "play: is idempotent"
fi
expect_status "fdroid: refuses the Play variant" 1 "is the Play variant" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"

dir=$(fresh play_stale_property)
printf 'noMlkit=true' >>"$dir/android/gradle.properties" # no newline
expect_status "play: replaces a stale noMlkit value" 0 "" \
  sh "$dir/tool/play_prepare.sh" "$dir"
if [ "$(grep -c '^noMlkit=' "$dir/android/gradle.properties")" = 1 ] &&
  tail -n 1 "$dir/android/gradle.properties" | grep -qx 'noMlkit=false'; then
  pass "play: keeps one noMlkit line"
else
  fail "play: keeps one noMlkit line"
fi

dir=$(fresh play_no_anchor)
sed -i.bak '/^  go_router:/d' "$dir/pubspec.yaml"
expect_status "play: fails without the go_router anchor" 1 "go_router" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_other_version)
sed -i.bak 's/^  go_router:.*/&\n  google_mlkit_text_recognition: ^0.16.0/' "$dir/pubspec.yaml"
expect_status "play: fails on another plugin version" 1 "unexpected" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_bindings)
sed -i.bak 's/const bool mlKitIncluded = false;/const bool mlKitIncluded = !true;/' \
  "$dir/lib/platform/mlkit_bindings.dart"
expect_status "play: fails on unknown bindings" 1 "does not look like the default" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_overlay)
echo '// new' >"$dir/tool/play/lib/platform/extra.dart"
expect_status "play: fails on an unknown overlay file" 1 "does not match" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_edited)
mkdir -p "$dir/lib/image_translate/data"
echo '// edited' >"$dir/lib/image_translate/data/mlkit_text_recognition_service.dart"
expect_status "play: fails when an added file differs" 1 "differs" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_gradle)
sed -i.bak 's/^val noMlkit = /val skipMlkit = /' "$dir/android/app/build.gradle.kts"
expect_status "play: fails without the noMlkit property" 1 "no longer defines noMlkit" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_markers)
echo '// BEGIN mlkit' >>"$dir/android/app/build.gradle.kts"
expect_status "play: fails on a half block" 1 "BEGIN mlkit" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh play_import)
echo "import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';" \
  >"$dir/lib/stray.dart"
expect_status "play: fails on ML Kit imports outside the bindings" 1 "outside the bindings" \
  sh "$dir/tool/play_prepare.sh" "$dir"

expect_status "play: fails outside the app" 1 "no pubspec.yaml" \
  sh "$repo/tool/play_prepare.sh" "$work"

# --- fdroid_prepare.sh -----------------------------------------------------

dir=$(fresh fdroid)
expect_status "fdroid: prepares the default tree" 0 "deleted tool/play" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"
if [ ! -e "$dir/tool/play" ] && [ ! -e "$dir/tool/play_prepare.sh" ] &&
  [ ! -e "$dir/packages/mlkit_translator" ] &&
  [ -f "$dir/packages/bergamot_translator/pubspec.yaml" ]; then
  pass "fdroid: deletes only the Play-only sources"
else
  fail "fdroid: deletes only the Play-only sources"
fi
before=$(snapshot "$dir")
expect_status "fdroid: a second run only checks" 0 "done" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"
if [ "$before" = "$(snapshot "$dir")" ] &&
  ! sh "$dir/tool/fdroid_prepare.sh" "$dir" | grep -q deleted; then
  pass "fdroid: is idempotent"
else
  fail "fdroid: is idempotent"
fi
cp "$repo/tool/play_prepare.sh" "$dir/tool/"
expect_status "play: fails without the overlay" 1 "tool/play is missing" \
  sh "$dir/tool/play_prepare.sh" "$dir"

dir=$(fresh fdroid_exclude)
sed -i.bak '/exclude(group = "com.google.firebase")/d' "$dir/android/app/build.gradle.kts"
expect_status "fdroid: fails when an exclusion is gone" 1 "no longer excludes com.google.firebase" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"

dir=$(fresh fdroid_default)
sed -i.bak 's/?: true$/?: false/' "$dir/android/app/build.gradle.kts"
expect_status "fdroid: fails when the exclusion is not the default" 1 "by default" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"

dir=$(fresh fdroid_property)
echo 'noMlkit=false' >>"$dir/android/gradle.properties"
expect_status "fdroid: fails on noMlkit=false" 1 "noMlkit=false" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"

dir=$(fresh fdroid_import)
echo "import 'package:mlkit_translator/mlkit_translator.dart';" >"$dir/lib/stray.dart"
expect_status "fdroid: fails on ML Kit imports" 1 "ML Kit import left" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"

dir=$(fresh fdroid_bindings)
sed -i.bak 's/const bool mlKitIncluded = false;/const bool mlKitIncluded = !true;/' \
  "$dir/lib/platform/mlkit_bindings.dart"
expect_status "fdroid: fails on unknown bindings" 1 "default bindings" \
  sh "$dir/tool/fdroid_prepare.sh" "$dir"

echo "variant_prepare_test: $passed passed, $failed failed"
[ "$failed" = 0 ]
