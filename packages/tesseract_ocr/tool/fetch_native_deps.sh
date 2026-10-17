#!/usr/bin/env bash
# Checks out the pinned native sources of the Tesseract OCR engine.
#
# Usage: packages/tesseract_ocr/tool/fetch_native_deps.sh
#
# The engine is vendored as two git submodules of this repository:
#   native/third_party/tesseract  github.com/tesseract-ocr/tesseract
#                                 (Apache-2.0), tag 5.5.3
#   native/third_party/leptonica  github.com/DanBloomberg/leptonica
#                                 (BSD-2-Clause), tag 1.87.0
#
# Tesseract's own submodules (googletest and the test images under
# unittest/ and test/) are NOT needed and not initialised; do not run
# `git submodule update --init --recursive` on it. Leptonica has none.
#
# Every checkout is shallow and pinned by the superproject (no branch
# tracking), so builds are reproducible (F-Droid: call this script in
# `prebuild` instead of using `submodules: true`). Re-running it is a no-op.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(git -C "$package_dir" rev-parse --show-toplevel)"
third_party="${package_dir}/native/third_party"
relative="${third_party#"${repo_root}/"}"

git -C "$repo_root" submodule sync --quiet -- \
  "${relative}/tesseract" "${relative}/leptonica"
git -C "$repo_root" -c protocol.file.allow=never submodule update --init \
  --depth 1 --jobs 2 -- "${relative}/tesseract" "${relative}/leptonica"

echo "Tesseract native sources are ready:"
git -C "$repo_root" submodule status -- "$relative"
