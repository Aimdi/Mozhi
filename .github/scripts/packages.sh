#!/usr/bin/env bash
# Fetches dependencies for, or tests, every package under packages/.
#
# Usage: bash .github/scripts/packages.sh get|test
#
#   get   `pub get` in every package (needed before `flutter analyze`, which
#         also analyzes packages/).
#   test  Runs each package's tests. Packages without a test/ directory (or
#         without any *_test.dart file) are skipped. A failing package does
#         not stop the loop, so every broken package is reported; the script
#         exits non-zero at the end if any package failed.
#
# Flutter packages (any `sdk: flutter` dependency, e.g. mlkit_translator) use
# `flutter pub get` / `flutter test`; pure Dart packages (including the CLI in
# packages/mozhi_cli) use `dart pub get` / `dart test`.
#
# Set DRY_RUN=1 to print the commands instead of running them.
set -euo pipefail

command="${1:-}"
case "$command" in
  get | test) ;;
  *)
    echo "usage: $0 get|test" >&2
    exit 64
    ;;
esac

# Run from the repository root (this file lives in .github/scripts/).
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

is_flutter_package() {
  grep -Eq '^[[:space:]]+sdk:[[:space:]]*["'\'']?flutter["'\'']?[[:space:]]*(#.*)?$' \
    "$1/pubspec.yaml"
}

has_tests() {
  [ -d "$1/test" ] && [ -n "$(find "$1/test" -name '*_test.dart' -print -quit)" ]
}

run_in() {
  local dir="$1"
  shift
  if [ -n "${DRY_RUN:-}" ]; then
    echo "+ (cd $dir && $*)"
  else
    (cd "$dir" && "$@")
  fi
}

failed=()

if [ "$command" = test ]; then
  {
    echo "### Package tests"
    echo
    echo "| Package | Runner | Result |"
    echo "| --- | --- | --- |"
  } >>"$summary"
fi

for pubspec in packages/*/pubspec.yaml; do
  [ -f "$pubspec" ] || continue
  dir="${pubspec%/pubspec.yaml}"
  name="${dir#packages/}"
  if is_flutter_package "$dir"; then
    tool=flutter
  else
    tool=dart
  fi

  case "$command" in
    get)
      echo "::group::$tool pub get ($name)"
      run_in "$dir" "$tool" pub get
      echo "::endgroup::"
      ;;
    test)
      if ! has_tests "$dir"; then
        echo "Skipping $name: no tests."
        echo "| $name | $tool | skipped (no tests) |" >>"$summary"
        continue
      fi
      echo "::group::$tool test ($name)"
      if run_in "$dir" "$tool" test; then
        result=passed
      else
        result=failed
        failed+=("$name")
      fi
      echo "::endgroup::"
      if [ "$result" = failed ]; then
        echo "::error title=Package tests failed::$name"
      fi
      echo "| $name | $tool | $result |" >>"$summary"
      ;;
  esac
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Failing packages: ${failed[*]}" >&2
  exit 1
fi
