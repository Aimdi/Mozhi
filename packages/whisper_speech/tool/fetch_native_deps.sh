#!/usr/bin/env bash
# Checks out the pinned native sources of the Whisper speech recognizer.
#
# Usage: packages/whisper_speech/tool/fetch_native_deps.sh
#
# The engine is vendored as one git submodule of this repository:
#   native/third_party/whisper.cpp  github.com/ggml-org/whisper.cpp v1.9.5
#                                   (MIT; vendors ggml, MIT)
#
# whisper.cpp has no submodules of its own (ggml is a plain directory in
# it), so nothing nested is initialised. The checkout is shallow and pinned
# by the superproject (no branch tracking), so builds are reproducible
# (F-Droid: call this script in `prebuild` instead of using
# `submodules: true`). No patches are applied.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(git -C "$package_dir" rev-parse --show-toplevel)"
third_party="${package_dir}/native/third_party"
whisper="${third_party#"${repo_root}/"}/whisper.cpp"

git -C "$repo_root" submodule sync --quiet -- "$whisper"
git -C "$repo_root" -c protocol.file.allow=never submodule update --init \
  --depth 1 -- "$whisper"

echo "Whisper native sources are ready:"
git -C "$repo_root" submodule status -- "$whisper"
