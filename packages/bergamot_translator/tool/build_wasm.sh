#!/usr/bin/env bash
# Builds the Bergamot engine and CLD2 for WebAssembly: bergamot-translator.js
# and bergamot-translator.wasm, the on-device engine of the web app (loaded
# by web/bergamot/worker.js).
#
# Usage: packages/bergamot_translator/tool/build_wasm.sh [output-dir]
#
# Output (gitignored): <output-dir>/bergamot-translator.{js,wasm}, by default
# web/bergamot/ next to worker.js, so `flutter build web` copies them into
# build/web/bergamot/. Copy them there yourself for a web build made before.
#
# What it does, without running upstream's inference/scripts/build-wasm.py
# (which runs `git submodule update --init --recursive` and pulls Mozilla's
# whole training pipeline):
#  1. fetch_native_deps.sh: the pinned sources of the native build (shallow,
#     only what the engine compiles) and native/patches/, plus the two the
#     WebAssembly build needs on top: marian-fork's onnxjs (its float GEMM
#     for WASM, MIT) and onnxjs' Eigen (MPL-2.0; built with EIGEN_MPL2_ONLY);
#  2. native/wasm/patches/ (idempotent);
#  3. emsdk at the version mozilla/translations pins (EMSDK_VERSION in
#     inference/scripts/build-wasm.py: 3.1.8, "the latest version of emsdk had
#     errors building sentencepiece"), cloned at the commit of its
#     inference/3rd_party/emsdk submodule into a cache outside the repository
#     ($MOZHI_CACHE_DIR/emsdk, default ~/.cache/mozhi/emsdk; ~1.2 GB);
#  4. emcmake cmake + the mozhi_bergamot_wasm target of native/wasm/
#     (single-threaded, WASM SIMD, the C API of native/src/mozhi_bergamot.h
#     plus loading models from memory);
#  5. upstream's import-gemm patch (inference/wasm/patch-artifacts-import-
#     gemm-module.sh: Firefox's mozIntGemm when present, else the int8 GEMM
#     compiled into the module), then wraps the glue in
#     `function loadBergamot(Module) { ...; return Module; }` like upstream.
#
# Needs git, python3, cmake (>= 3.22) and, optionally, ninja. Environment:
#   BERGAMOT_JOBS            parallel jobs (default: all cores)
#   MOZHI_CACHE_DIR          where emsdk goes (default ~/.cache/mozhi)
#   EMSDK                    an emsdk checkout to use instead (activated at
#                            the pinned version by this script)
#   BERGAMOT_WASM_BUILD_DIR  build directory (default
#                            packages/bergamot_translator/build/wasm)
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(git -C "$package_dir" rev-parse --show-toplevel)"
output_dir="${1:-${repo_root}/web/bergamot}"
build_dir="${BERGAMOT_WASM_BUILD_DIR:-${package_dir}/build/wasm}"
jobs="${BERGAMOT_JOBS:-$(nproc 2>/dev/null || echo 4)}"
translations="${package_dir}/native/third_party/translations"
inference="${translations}/inference"
marian_3rd="${inference}/marian-fork/src/3rd_party"

log() { echo "==> $*"; }

# --- 1. Sources ----------------------------------------------------------------
log "Fetching the pinned sources"
"${package_dir}/tool/fetch_native_deps.sh" >/dev/null

update() {
  # $1: repository, $2...: submodule paths relative to it (as in
  # fetch_native_deps.sh: shallow, pinned by the superproject).
  local repo="$1"
  shift
  git -C "$repo" submodule sync --quiet -- "$@"
  git -C "$repo" -c protocol.file.allow=never submodule update --init \
    --depth 1 --jobs 4 -- "$@"
}
update "$translations" inference/marian-fork/src/3rd_party/onnxjs
update "${marian_3rd}/onnxjs" deps/eigen

# --- 2. Patches -------------------------------------------------------------------
for patch in "${package_dir}/native/wasm/patches/"*.patch; do
  [ -f "$patch" ] || continue
  if git -C "$translations" apply --reverse --check "$patch" 2>/dev/null; then
    continue
  fi
  git -C "$translations" apply --whitespace=nowarn "$patch"
  log "Applied $(basename "$patch")"
done

# --- 3. Emscripten -----------------------------------------------------------------
emsdk_version="$(sed -n 's/^EMSDK_VERSION = "\(.*\)"$/\1/p' \
  "${inference}/scripts/build-wasm.py")"
if [ -z "$emsdk_version" ]; then
  echo "error: no EMSDK_VERSION in inference/scripts/build-wasm.py" >&2
  exit 1
fi
emsdk_commit="$(git -C "$translations" ls-tree HEAD inference/3rd_party/emsdk \
  | awk '{print $3}')"
emsdk_dir="${EMSDK:-${MOZHI_CACHE_DIR:-${HOME}/.cache/mozhi}/emsdk}"
if [ ! -x "${emsdk_dir}/emsdk" ]; then
  log "Cloning emsdk ${emsdk_version} (${emsdk_commit:0:8}) into ${emsdk_dir}"
  mkdir -p "$(dirname "$emsdk_dir")"
  git clone --quiet --filter=blob:none \
    https://github.com/emscripten-core/emsdk.git "$emsdk_dir"
  if [ -n "$emsdk_commit" ]; then
    git -C "$emsdk_dir" -c advice.detachedHead=false checkout --quiet \
      "$emsdk_commit"
  fi
fi
if [ ! -f "${emsdk_dir}/.mozhi-${emsdk_version}" ]; then
  log "Installing Emscripten ${emsdk_version}"
  "${emsdk_dir}/emsdk" install "$emsdk_version"
  # The downloaded archives are not needed once unpacked (~340 MB).
  rm -rf "${emsdk_dir}/zips"
  touch "${emsdk_dir}/.mozhi-${emsdk_version}"
fi
"${emsdk_dir}/emsdk" activate "$emsdk_version" >/dev/null
# shellcheck disable=SC1091 # emsdk's environment script.
source "${emsdk_dir}/emsdk_env.sh" >/dev/null 2>&1
actual="$(emcc --version | sed -n '1s/.* \([0-9][0-9.]*\) (.*/\1/p')"
if [ "$actual" != "$emsdk_version" ]; then
  echo "error: emcc is ${actual:-unknown}, expected ${emsdk_version}" >&2
  exit 1
fi

# --- 4. Build ------------------------------------------------------------------------
generator=()
if command -v ninja >/dev/null 2>&1; then
  generator=(-G Ninja)
fi
log "Configuring (${build_dir})"
emcmake cmake -S "${package_dir}/native/wasm" -B "$build_dir" \
  "${generator[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null
log "Building with ${jobs} jobs"
cmake --build "$build_dir" --target mozhi_bergamot_wasm --parallel "$jobs"

# --- 5. Import-gemm patch and wrapper ----------------------------------------------------
staging="${build_dir}/artifacts"
rm -rf "$staging"
mkdir -p "$staging"
cp "${build_dir}/out/bergamot-translator.js" \
  "${build_dir}/out/bergamot-translator.wasm" "$staging/"
bash "${inference}/wasm/patch-artifacts-import-gemm-module.sh" "$staging" \
  >/dev/null
rm -f "${staging}/bergamot-translator.js.bak"
if ! grep -q '"wasm_gemm": createWasmGemm(),' \
  "${staging}/bergamot-translator.js"; then
  echo "error: the import-gemm patch did not apply (Emscripten's glue" \
    "changed?)" >&2
  exit 1
fi
wrapped="${staging}/bergamot-translator.wrapped.js"
{
  printf '%s\n' \
    "/* Generated by packages/bergamot_translator/tool/build_wasm.sh from" \
    " * mozilla/translations (inference/, $(cat "${inference}/BERGAMOT_VERSION"))," \
    " * Marian (MIT), CLD2 (Apache-2.0) and the Mozhi C API (MIT). Do not edit." \
    " *" \
    " * This Source Code Form is subject to the terms of the Mozilla Public" \
    " * License, v. 2.0. If a copy of the MPL was not distributed with this" \
    " * file, You can obtain one at http://mozilla.org/MPL/2.0/. */" \
    "" \
    "function loadBergamot(Module) {"
  # Logs go to Module.print (the worker silences them), as upstream does.
  sed -e 's/^/  /' -e 's/console\.log(/Module.print(/g' \
    "${staging}/bergamot-translator.js"
  printf '%s\n' "" "  return Module;" "}"
} > "$wrapped"
mv "$wrapped" "${staging}/bergamot-translator.js"

mkdir -p "$output_dir"
cp "${staging}/bergamot-translator.js" "${staging}/bergamot-translator.wasm" \
  "$output_dir/"
wasm="${output_dir}/bergamot-translator.wasm"
size() { du -h "$1" | cut -f1; }
log "Built ${output_dir}/bergamot-translator.{js,wasm}"
echo "    wasm $(size "$wasm") ($(gzip -9c "$wasm" | wc -c) bytes gzipped)," \
  "js $(size "${output_dir}/bergamot-translator.js")," \
  "Emscripten ${emsdk_version}"
