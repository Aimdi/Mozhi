#!/bin/sh
# Tests for tool/install_native_toolchain.sh against a fake Android SDK whose
# sdkmanager fails a given number of installs, and a fake sudo: the install
# is retried up to three times, a failed attempt's leftovers are removed, and
# ccache is installed only once the SDK packages are.
#
#   sh tool/install_native_toolchain_test.sh
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$here/install_native_toolchain.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/install_native_toolchain_test.XXXXXX")
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

# A fresh fake SDK in $work/$1 whose sdkmanager fails the first $2 installs.
# Calls are logged to $work/$1/calls.
fresh() {
  sdk="$work/$1"
  rm -rf "$sdk"
  mkdir -p "$sdk/cmdline-tools/latest/bin" "$sdk/bin"
  echo "$2" >"$sdk/failures"
  cat >"$sdk/cmdline-tools/latest/bin/sdkmanager" <<'EOF'
#!/bin/sh
sdk=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
echo "sdkmanager $*" >>"$sdk/calls"
[ "$1" = --licenses ] && exit 0
left=$(cat "$sdk/failures")
if [ "$left" -gt 0 ]; then
  echo $((left - 1)) >"$sdk/failures"
  # What a broken download can leave behind.
  mkdir -p "$sdk/.temp" "$sdk/ndk/28.2.13676358"
  echo "Warning: An error occurred while preparing SDK package NDK: Error on ZipFile unknown archive." >&2
  exit 1
fi
mkdir -p "$sdk/ndk/28.2.13676358" "$sdk/cmake/3.22.1"
echo installed >"$sdk/ndk/28.2.13676358/package.xml"
EOF
  cat >"$sdk/bin/sudo" <<'EOF'
#!/bin/sh
sdk=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
echo "sudo $*" >>"$sdk/calls"
EOF
  chmod +x "$sdk/cmdline-tools/latest/bin/sdkmanager" "$sdk/bin/sudo"
  : >"$sdk/calls"
  echo "$sdk"
}

# Runs the script against the fake SDK $1; its exit status goes to $sdk/status
# and its stderr to $sdk/stderr.
run() {
  status=0
  env ANDROID_HOME="$1" PATH="$1/bin:$PATH" INSTALL_RETRY_DELAY=0 \
    NDK_VERSION=28.2.13676358 CMAKE_VERSION=3.22.1 \
    bash "$script" >/dev/null 2>"$1/stderr" || status=$?
  echo "$status" >"$1/status"
}

installs() { grep -c -- '--install ndk;28.2.13676358 cmake;3.22.1' "$1/calls" || true; }
ccache_installs() { grep -c '^sudo apt-get install -y -q ccache$' "$1/calls" || true; }

sdk=$(fresh first_try 0)
run "$sdk"
if [ "$(cat "$sdk/status")" = 0 ] && [ "$(installs "$sdk")" = 1 ] &&
  [ "$(ccache_installs "$sdk")" = 1 ] && grep -q '^sdkmanager --licenses$' "$sdk/calls"; then
  pass "installs once and then ccache when the first try works"
else
  fail "installs once and then ccache when the first try works"
fi

sdk=$(fresh two_failures 2)
run "$sdk"
if [ "$(cat "$sdk/status")" = 0 ] && [ "$(installs "$sdk")" = 3 ] &&
  [ "$(ccache_installs "$sdk")" = 1 ] && [ ! -e "$sdk/.temp" ] &&
  [ -f "$sdk/ndk/28.2.13676358/package.xml" ] &&
  [ "$(grep -c '::warning::sdkmanager failed' "$sdk/stderr")" = 2 ]; then
  pass "retries twice, cleaning up, and succeeds on the third try"
else
  fail "retries twice, cleaning up, and succeeds on the third try"
fi

sdk=$(fresh always_fails 5)
run "$sdk"
if [ "$(cat "$sdk/status")" = 1 ] && [ "$(installs "$sdk")" = 3 ] &&
  [ "$(ccache_installs "$sdk")" = 0 ] &&
  grep -q "::error::sdkmanager couldn't install ndk;28.2.13676358 and cmake;3.22.1 (3 attempts)" "$sdk/stderr"; then
  pass "fails after three tries without installing ccache"
else
  fail "fails after three tries without installing ccache"
fi

sdk=$(fresh no_version 0)
status=0
env ANDROID_HOME="$sdk" PATH="$sdk/bin:$PATH" CMAKE_VERSION=3.22.1 \
  bash "$script" >/dev/null 2>"$sdk/stderr" || status=$?
if [ "$status" != 0 ] && grep -q 'NDK_VERSION' "$sdk/stderr" &&
  [ "$(installs "$sdk")" = 0 ]; then
  pass "fails before installing anything without NDK_VERSION"
else
  fail "fails before installing anything without NDK_VERSION"
fi

echo "install_native_toolchain_test: $passed passed, $failed failed"
[ "$failed" = 0 ]
