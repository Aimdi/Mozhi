#!/usr/bin/env bash
# Installs the Android NDK and CMake (Android SDK packages) and ccache for the
# CI and release jobs that compile the on-device engines:
#
#   NDK_VERSION=28.2.13676358 CMAKE_VERSION=3.22.1 tool/install_native_toolchain.sh
#
# Needs ANDROID_HOME (or ANDROID_SDK_ROOT) with cmdline-tools/latest, like
# GitHub's Ubuntu runners have. Google's downloads sometimes arrive broken
# ("Error on ZipFile unknown archive"), so the SDK install is tried up to
# three times. INSTALL_RETRY_DELAY (seconds, default 15) sets the wait before
# the second try; it doubles before the third.
set -euo pipefail

: "${NDK_VERSION:?set NDK_VERSION, e.g. 28.2.13676358}"
: "${CMAKE_VERSION:?set CMAKE_VERSION, e.g. 3.22.1}"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?set ANDROID_HOME to the Android SDK}}"
sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
attempts=3
delay="${INSTALL_RETRY_DELAY:-15}"

yes | "$sdkmanager" --licenses > /dev/null || true

attempt=1
until "$sdkmanager" --install "ndk;$NDK_VERSION" "cmake;$CMAKE_VERSION" > /dev/null; do
  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error::sdkmanager couldn't install ndk;$NDK_VERSION and cmake;$CMAKE_VERSION ($attempts attempts)." >&2
    exit 1
  fi
  wait=$((attempt * delay))
  echo "::warning::sdkmanager failed (attempt $attempt of $attempts); retrying in $wait s." >&2
  # Whatever a failed attempt left behind, so the next one starts clean.
  rm -rf "$sdk/.temp" "$sdk/ndk/$NDK_VERSION" "$sdk/cmake/$CMAKE_VERSION"
  sleep "$wait"
  attempt=$((attempt + 1))
done

sudo apt-get install -y -q ccache > /dev/null
