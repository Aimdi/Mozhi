#!/usr/bin/env bash
# Checks out the pinned native sources of the Bergamot engine.
#
# Usage: packages/bergamot_translator/tool/fetch_native_deps.sh
#
# The engine is vendored as two git submodules of this repository:
#   native/third_party/translations  github.com/mozilla/translations (MPL-2.0)
#   native/third_party/pcre2         github.com/PCRE2Project/pcre2 (BSD-3)
#
# mozilla/translations also contains Mozilla's training pipeline, whose
# submodules (marian-dev, kenlm, fast_align, emsdk, ...) are NOT needed. Do
# not run `git submodule update --init --recursive` on it; this script
# initialises only what the CPU inference engine compiles:
#   inference/3rd_party/ssplit-cpp                    Apache-2.0
#   inference/marian-fork/src/3rd_party/sentencepiece Apache-2.0
#   inference/marian-fork/src/3rd_party/intgemm      MIT (x86_64)
#   inference/marian-fork/src/3rd_party/ruy          Apache-2.0 (ARM)
#     third_party/cpuinfo                            BSD-2-Clause (ARM)
#   inference/marian-fork/src/3rd_party/simd_utils   BSD-2-Clause (ARM)
#
# Every checkout is shallow and pinned by the superproject (no branch
# tracking), so builds are reproducible (F-Droid: call this script in
# `prebuild` instead of using `submodules: true`). The patches in
# native/patches/ are then applied to the checkout (idempotent).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(git -C "$package_dir" rev-parse --show-toplevel)"
third_party="${package_dir}/native/third_party"
translations="${third_party}/translations"

update() {
  # $1: repository, $2...: submodule paths relative to it.
  local repo="$1"
  shift
  git -C "$repo" submodule sync --quiet -- "$@"
  git -C "$repo" -c protocol.file.allow=never submodule update --init \
    --depth 1 --jobs 4 -- "$@"
}

update "$repo_root" \
  "${third_party#"${repo_root}/"}/translations" \
  "${third_party#"${repo_root}/"}/pcre2"

update "$translations" \
  inference/3rd_party/ssplit-cpp \
  inference/marian-fork/src/3rd_party/sentencepiece \
  inference/marian-fork/src/3rd_party/intgemm \
  inference/marian-fork/src/3rd_party/ruy \
  inference/marian-fork/src/3rd_party/simd_utils

update "${translations}/inference/marian-fork/src/3rd_party/ruy" \
  third_party/cpuinfo

# Local fixes on top of the pinned sources (native/patches/README.md). Each
# is applied once; re-running this script is a no-op.
for patch in "${package_dir}/native/patches/"*.patch; do
  [ -f "$patch" ] || continue
  if git -C "$translations" apply --reverse --check "$patch" 2>/dev/null; then
    continue
  fi
  git -C "$translations" apply --whitespace=nowarn "$patch"
  echo "Applied $(basename "$patch")"
done

echo "Bergamot native sources are ready:"
git -C "$repo_root" submodule status -- "${third_party#"${repo_root}/"}"
git -C "$translations" submodule status -- \
  inference/3rd_party/ssplit-cpp inference/marian-fork/src/3rd_party
