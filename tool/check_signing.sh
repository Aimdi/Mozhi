#!/bin/sh
# Prints the signing certificate (SHA-256) of each APK or app bundle and,
# with --expect, fails unless it is the release certificate in
# tool/release-certificate.sha256 (the value published in the README).
#
#   sh tool/check_signing.sh [--expect] FILE...
#
# APKs are read with apksigner (Android SDK build-tools; set APKSIGNER to
# its path, otherwise the newest under $ANDROID_HOME/build-tools is used),
# .aab files with keytool.
set -eu

expect=0
if [ "${1:-}" = "--expect" ]; then
  expect=1
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "usage: sh tool/check_signing.sh [--expect] FILE..." >&2
  exit 2
fi

want=$(tr -d ' :\n' < "$(dirname "$0")/release-certificate.sha256" | tr 'A-F' 'a-f')
apksigner=${APKSIGNER:-}
if [ -z "$apksigner" ]; then
  apksigner=$(ls -d "${ANDROID_HOME:-/usr/local/lib/android/sdk}"/build-tools/*/apksigner 2>/dev/null |
    sort -V | tail -n 1)
fi

status=0
for file in "$@"; do
  case "$file" in
    *.aab)
      got=$(keytool -printcert -jarfile "$file" 2>/dev/null |
        sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1 | tr -d ':' | tr 'A-F' 'a-f')
      ;;
    *)
      if [ ! -x "$apksigner" ]; then
        echo "check_signing: apksigner not found (set APKSIGNER)" >&2
        exit 2
      fi
      got=$("$apksigner" verify --print-certs "$file" |
        sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
      ;;
  esac
  echo "$file: ${got:-not signed}"
  if [ "$expect" = 1 ] && [ "$got" != "$want" ]; then
    echo "::error title=Signing::$file is signed with ${got:-nothing}, not the release certificate $want"
    status=1
  fi
done
exit "$status"
