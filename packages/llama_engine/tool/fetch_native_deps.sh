#!/usr/bin/env bash
# Checks out the pinned native sources of the on-device AI engine.
#
# Usage: packages/llama_engine/tool/fetch_native_deps.sh
#
# The engine is vendored as one git submodule of this repository:
#   native/third_party/llama.cpp  github.com/ggml-org/llama.cpp v0.6.0
#                                 (commit d81235049384534c167caea52b85a694f6103d14;
#                                 MIT; vendors ggml, MIT)
#
# llama.cpp has no submodules of its own (ggml and its vendored headers are
# plain directories in it), so nothing nested is initialised. The checkout
# is shallow and pinned by the superproject (no branch tracking), so builds
# are reproducible (F-Droid: call this script in `prebuild` instead of using
# `submodules: true`). No patches are applied.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(git -C "$package_dir" rev-parse --show-toplevel)"
third_party="${package_dir}/native/third_party"
llama="${third_party#"${repo_root}/"}/llama.cpp"

git -C "$repo_root" submodule sync --quiet -- "$llama"
git -C "$repo_root" -c protocol.file.allow=never submodule update --init \
  --depth 1 -- "$llama"

echo "llama.cpp native sources are ready:"
git -C "$repo_root" submodule status -- "$llama"
