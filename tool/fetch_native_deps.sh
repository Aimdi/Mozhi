#!/usr/bin/env bash
# Checks out the pinned native sources of every on-device engine before an
# Android build (nothing is downloaded during the Gradle build itself):
#
#   packages/bergamot_translator  offline translation (Mozilla Bergamot)
#   packages/tesseract_ocr        text recognition in photos (Tesseract)
#   packages/whisper_speech       offline voice input (whisper.cpp)
#
# Usage: tool/fetch_native_deps.sh
#
# Runs packages/*/tool/fetch_native_deps.sh in turn; each one initialises
# only the shallow, pinned submodules its engine compiles and applies its
# patches (see the package's README). CI, the release workflow and the
# F-Droid recipe call this script.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

found=0
for script in "${repo_root}"/packages/*/tool/fetch_native_deps.sh; do
  [ -f "$script" ] || continue
  found=1
  package="$(basename "$(dirname "$(dirname "$script")")")"
  echo "fetch_native_deps: ${package}"
  bash "$script"
done

if [ "$found" = 0 ]; then
  echo "fetch_native_deps: no package has native sources" >&2
  exit 1
fi
